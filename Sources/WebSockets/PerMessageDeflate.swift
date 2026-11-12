public import HTTPCore
// Our `Compression` target (zlib raw deflate, #0091), which shadows Apple's module of the same
// name; nothing here needs Apple's.
import Compression

/// The permessage-deflate extension (RFC 7692): each data message's payload is compressed
/// with raw deflate and sent with RSV1 set on its first frame.
///
/// ## Negotiation (RFC 7692 §7.1)
///
/// The client offers the extension in `Sec-WebSocket-Extensions`, possibly several times with
/// different parameters; ``negotiate(offers:configuration:)`` accepts the first offer it can
/// honour and returns the agreed ``Parameters`` and the response value:
///
/// | Parameter | Offered by the client | In our response |
/// |---|---|---|
/// | `server_no_context_takeover` | we must reset our compressor after each message | when offered or ``Configuration/serverNoContextTakeover`` |
/// | `client_no_context_takeover` | the client resets its compressor | when offered or ``Configuration/clientNoContextTakeover`` |
/// | `server_max_window_bits=N` | our LZ77 window may be at most 2^N | `min(N, ` ``Configuration/serverMaxWindowBits`` `)`, also sent unasked when the configuration is below 15 |
/// | `client_max_window_bits[=N]` | the client can limit its window | ``Configuration/clientMaxWindowBits`` when below 15 (only if offered) |
///
/// An offer with an unknown or repeated parameter or an invalid value is declined, as is one
/// that needs a server window of 2^8: zlib's raw deflate encoder cannot use a window below 2^9.
/// We always inflate with a 2^15 window, which decodes any window the client picks.
///
/// ## Defaults
///
/// The defaults favour ratio with bounded memory: context takeover on both sides (small JSON
/// messages that repeat keys shrink most from it), a 2^15 window at memory level 8 (about
/// 256 KiB of zlib state for the compressor and 44 KiB for the decompressor per connection,
/// held for its lifetime), compression level 6, and messages under 32 bytes sent uncompressed.
/// See `docs/benchmarks/M15-websockets.md`.
///
/// ## Limits
///
/// Decompression is bounded by ``WebSocketConfiguration/maxMessageSize``: a message that
/// inflates beyond it fails the connection with 1009 as soon as the excess is produced, so a
/// decompression bomb costs at most that much memory. Data that is not valid deflate fails it
/// with 1007.
public enum PerMessageDeflate {
    /// The extension token.
    public static let extensionName = "permessage-deflate"

    /// What this server is willing to agree to.
    public struct Configuration: Sendable, Hashable {
        /// Reset our compressor after every message (less memory held between messages' worth
        /// of history, worse ratio). Always on when the client asks for it.
        public var serverNoContextTakeover: Bool
        /// Ask the client to reset its compressor after every message.
        public var clientNoContextTakeover: Bool
        /// Our LZ77 window, 2^9...2^15 (the client can ask for less).
        public var serverMaxWindowBits: Int
        /// The window the client may use, 2^8...2^15; sent only when the client offered
        /// `client_max_window_bits` and this is below 15.
        public var clientMaxWindowBits: Int
        /// zlib compression level, 1 (fastest) to 9 (smallest).
        public var compressionLevel: Int
        /// zlib memory level, 1...9 (state size and speed).
        public var memoryLevel: Int
        /// Messages with fewer payload bytes are sent uncompressed (RSV1 clear).
        public var minimumMessageSize: Int

        public init(
            serverNoContextTakeover: Bool = false,
            clientNoContextTakeover: Bool = false,
            serverMaxWindowBits: Int = 15,
            clientMaxWindowBits: Int = 15,
            compressionLevel: Int = 6,
            memoryLevel: Int = 8,
            minimumMessageSize: Int = 32
        ) {
            precondition((9...15).contains(serverMaxWindowBits), "serverMaxWindowBits must be 9...15")
            precondition((8...15).contains(clientMaxWindowBits), "clientMaxWindowBits must be 8...15")
            precondition((1...9).contains(compressionLevel) && (1...9).contains(memoryLevel),
                         "compression and memory levels must be 1...9")
            precondition(minimumMessageSize >= 0)
            self.serverNoContextTakeover = serverNoContextTakeover
            self.clientNoContextTakeover = clientNoContextTakeover
            self.serverMaxWindowBits = serverMaxWindowBits
            self.clientMaxWindowBits = clientMaxWindowBits
            self.compressionLevel = compressionLevel
            self.memoryLevel = memoryLevel
            self.minimumMessageSize = minimumMessageSize
        }
    }

    /// The agreed parameters of one connection, plus the local tuning they run with.
    public struct Parameters: Sendable, Hashable {
        /// We reset our compressor after each message.
        public var serverNoContextTakeover: Bool
        /// The client resets its compressor after each message (we reset our decompressor).
        public var clientNoContextTakeover: Bool
        /// Our compressor's window bits.
        public var serverMaxWindowBits: Int
        /// The client's window bits (15 when it did not limit them).
        public var clientMaxWindowBits: Int
        public var compressionLevel: Int
        public var memoryLevel: Int
        public var minimumMessageSize: Int

        public init(
            serverNoContextTakeover: Bool = false, clientNoContextTakeover: Bool = false,
            serverMaxWindowBits: Int = 15, clientMaxWindowBits: Int = 15,
            compressionLevel: Int = 6, memoryLevel: Int = 8, minimumMessageSize: Int = 32
        ) {
            self.serverNoContextTakeover = serverNoContextTakeover
            self.clientNoContextTakeover = clientNoContextTakeover
            self.serverMaxWindowBits = serverMaxWindowBits
            self.clientMaxWindowBits = clientMaxWindowBits
            self.compressionLevel = compressionLevel
            self.memoryLevel = memoryLevel
            self.minimumMessageSize = minimumMessageSize
        }
    }

    /// The outcome of a negotiation: the agreed parameters and the
    /// `Sec-WebSocket-Extensions` value for the response.
    public struct Agreement: Sendable, Hashable {
        public var parameters: Parameters
        public var responseValue: String
    }

    // MARK: Negotiation

    /// One extension of a `Sec-WebSocket-Extensions` list: its name and parameters, with
    /// quoted values unquoted (RFC 6455 §9.1).
    struct Element: Equatable {
        var name: String
        var parameters: [(name: String, value: String?)]

        static func == (lhs: Element, rhs: Element) -> Bool {
            lhs.name == rhs.name && lhs.parameters.elementsEqual(rhs.parameters) { $0.name == $1.name && $0.value == $1.value }
        }
    }

    /// Accepts the first acceptable permessage-deflate offer in `offers` (the
    /// `Sec-WebSocket-Extensions` values joined with commas), or returns `nil`.
    public static func negotiate(offers: String, configuration: Configuration) -> Agreement? {
        guard let elements = parseExtensions(Array(offers.utf8)) else { return nil }
        for element in elements where element.name.lowercased() == extensionName {
            if let agreement = accept(element.parameters, configuration: configuration) { return agreement }
        }
        return nil
    }

    /// The agreement for one offer, or `nil` when it must be declined.
    static func accept(_ parameters: [(name: String, value: String?)], configuration: Configuration) -> Agreement? {
        var serverNoContextTakeover = false
        var clientNoContextTakeover = false
        var serverMaxWindowBits: Int?
        var clientMaxWindowBitsOffered = false
        var clientMaxWindowBits: Int?
        var seen = Set<String>()
        for (rawName, value) in parameters {
            let name = rawName.lowercased()
            guard seen.insert(name).inserted else { return nil }
            switch name {
            case "server_no_context_takeover":
                guard value == nil else { return nil }
                serverNoContextTakeover = true
            case "client_no_context_takeover":
                guard value == nil else { return nil }
                clientNoContextTakeover = true
            case "server_max_window_bits":
                guard let value, let bits = windowBits(value) else { return nil }
                serverMaxWindowBits = bits
            case "client_max_window_bits":
                clientMaxWindowBitsOffered = true
                if let value {
                    guard let bits = windowBits(value) else { return nil }
                    clientMaxWindowBits = bits
                }
            default:
                return nil
            }
        }

        var agreed = Parameters(
            serverNoContextTakeover: serverNoContextTakeover || configuration.serverNoContextTakeover,
            clientNoContextTakeover: clientNoContextTakeover || configuration.clientNoContextTakeover,
            serverMaxWindowBits: min(serverMaxWindowBits ?? 15, configuration.serverMaxWindowBits),
            clientMaxWindowBits: clientMaxWindowBits ?? 15,
            compressionLevel: configuration.compressionLevel, memoryLevel: configuration.memoryLevel,
            minimumMessageSize: configuration.minimumMessageSize)
        // zlib cannot compress raw deflate with a 256-byte window.
        guard agreed.serverMaxWindowBits >= 9 else { return nil }

        var response = extensionName
        if agreed.serverNoContextTakeover { response += "; server_no_context_takeover" }
        if agreed.clientNoContextTakeover { response += "; client_no_context_takeover" }
        if serverMaxWindowBits != nil || agreed.serverMaxWindowBits < 15 {
            response += "; server_max_window_bits=\(agreed.serverMaxWindowBits)"
        }
        if clientMaxWindowBitsOffered && configuration.clientMaxWindowBits < agreed.clientMaxWindowBits {
            agreed.clientMaxWindowBits = configuration.clientMaxWindowBits
            response += "; client_max_window_bits=\(agreed.clientMaxWindowBits)"
        }
        return Agreement(parameters: agreed, responseValue: response)
    }

    /// `8`...`15` without leading zeros (RFC 7692 §7.1.2.1).
    static func windowBits(_ value: String) -> Int? {
        guard !value.isEmpty, value.count <= 2, value.first != "0", let bits = Int(value), (8...15).contains(bits)
        else { return nil }
        return bits
    }

    /// Parses `1#extension` (RFC 6455 §9.1): `name *( ";" param )`, `param = token [ "=" (token
    /// / quoted-string) ]`, with optional whitespace. Empty list elements are skipped (RFC 9110
    /// §5.6.1). Returns `nil` for anything malformed.
    static func parseExtensions(_ bytes: [UInt8]) -> [Element]? {
        var elements: [Element] = []
        var i = 0
        func skipWhitespace() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
        }
        func token() -> String? {
            let start = i
            while i < bytes.count, ASCII.isTokenCharacter(bytes[i]) { i += 1 }
            return i > start ? String(decoding: bytes[start..<i], as: UTF8.self) : nil
        }
        func quoted() -> String? {
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { return nil }
            i += 1
            var value: [UInt8] = []
            while i < bytes.count {
                let byte = bytes[i]
                if byte == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: value, as: UTF8.self)
                }
                if byte == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { return nil }
                }
                value.append(bytes[i])
                i += 1
            }
            return nil
        }
        while true {
            skipWhitespace()
            if i == bytes.count { return elements }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            guard let name = token() else { return nil }
            var element = Element(name: name, parameters: [])
            skipWhitespace()
            while i < bytes.count, bytes[i] == UInt8(ascii: ";") {
                i += 1
                skipWhitespace()
                guard let parameter = token() else { return nil }
                skipWhitespace()
                var value: String?
                if i < bytes.count, bytes[i] == UInt8(ascii: "=") {
                    i += 1
                    skipWhitespace()
                    guard let parsed = token() ?? quoted() else { return nil }
                    value = parsed
                    skipWhitespace()
                }
                element.parameters.append((parameter, value))
            }
            elements.append(element)
            guard i == bytes.count || bytes[i] == UInt8(ascii: ",") else { return nil }
        }
    }

    // MARK: Codecs

    /// The tail a sync flush ends with, removed before sending and appended before inflating
    /// (RFC 7692 §7.2.1, §7.2.2).
    public static let tail: [UInt8] = [0x00, 0x00, 0xFF, 0xFF]

    /// Compresses outgoing messages (the session's writer task owns it). Not safe for
    /// concurrent use.
    public final class Deflater: @unchecked Sendable {
        let encoder: DeflateEncoder
        let noContextTakeover: Bool
        let minimumMessageSize: Int

        public init?(_ parameters: Parameters) {
            guard let encoder = DeflateEncoder(
                format: .raw, level: parameters.compressionLevel, windowBits: parameters.serverMaxWindowBits,
                memoryLevel: parameters.memoryLevel) else { return nil }
            self.encoder = encoder
            noContextTakeover = parameters.serverNoContextTakeover
            minimumMessageSize = parameters.minimumMessageSize
        }

        /// Compresses `payload` into `output` (cleared first) and returns the length to send:
        /// the sync-flushed deflate data without its `00 00 ff ff` tail. Returns `nil` when the
        /// message should go uncompressed: it is below ``minimumMessageSize``, or (without
        /// context takeover, where skipping costs nothing) compression did not make it smaller.
        public func compress(_ payload: ByteBuffer, into output: inout ByteBuffer) -> Int? {
            let count = payload.readableBytes
            guard count >= minimumMessageSize else { return nil }
            output.clear()
            payload.withUnsafeReadableBytes { input in
                var offset = 0
                while true {
                    let room = max(64, min(count - offset + 64, 64 * 1024))
                    let progress = output.withUnsafeMutableWritableBytes(minimumWritableBytes: room) { out in
                        encoder.process(UnsafeRawBufferPointer(rebasing: input[offset...]),
                                        into: UnsafeMutableRawBufferPointer(rebasing: out[..<room]), flush: .sync)
                    }
                    output.commitWritten(progress.produced)
                    offset += progress.consumed
                    // Done once all input is in and the flush did not fill the space it had.
                    if offset == count && progress.produced < room { break }
                }
            }
            if noContextTakeover { encoder.reset() }
            let produced = output.readableBytes
            // A sync flush always ends with an empty stored block.
            let length = produced >= 4 && output.withUnsafeReadableBytes({ $0.suffix(4).elementsEqual(PerMessageDeflate.tail) })
                ? produced - 4 : produced
            if noContextTakeover && length >= count { return nil }
            return length
        }
    }

    /// Why ``Inflater`` stopped.
    public enum InflateError: Error, Equatable, Sendable {
        /// The message inflates past the limit (1009).
        case tooBig
        /// Not valid deflate data (1007).
        case invalidData
    }

    /// Decompresses incoming messages (owned by the connection state machine). Not safe for
    /// concurrent use.
    public final class Inflater: @unchecked Sendable {
        let decoder: DeflateDecoder
        let noContextTakeover: Bool
        /// The stream ended inside this message (a block with BFINAL set): the rest of the
        /// message is ignored and the next one starts a new stream.
        var streamEnded = false

        public init?(_ parameters: Parameters) {
            // A 2^15 window decodes whatever window the client uses.
            guard let decoder = DeflateDecoder(format: .raw, windowBits: 15) else { return nil }
            self.decoder = decoder
            noContextTakeover = parameters.clientNoContextTakeover
        }

        /// Inflates `input` and appends the result to `message`, failing as soon as `message`
        /// would hold more than `limit` bytes.
        public func inflate(_ input: UnsafeRawBufferPointer, into message: inout ByteBuffer, limit: Int) throws(InflateError) {
            guard !streamEnded else { return }
            var offset = 0
            while true {
                let left = limit - message.readableBytes
                // One byte more than allowed, to see whether the data goes past the limit.
                let room = max(1, min(left + 1, 64 * 1024))
                let progress: CodecProgress
                do {
                    progress = try message.withUnsafeMutableWritableBytes(minimumWritableBytes: room) { (out) throws(DeflateDecoder.DataError) in
                        try decoder.process(UnsafeRawBufferPointer(rebasing: input[offset...]),
                                            into: UnsafeMutableRawBufferPointer(rebasing: out[..<room]))
                    }
                } catch {
                    throw .invalidData
                }
                message.commitWritten(progress.produced)
                offset += progress.consumed
                if message.readableBytes > limit { throw .tooBig }
                if progress.finished {
                    streamEnded = true
                    return
                }
                if offset == input.count && progress.produced < room { return }
                if progress.consumed == 0 && progress.produced == 0 { return }
            }
        }

        /// Ends the message: inflates the removed tail, then resets for the next message
        /// when the client does not keep its context (or its stream ended).
        public func finishMessage(into message: inout ByteBuffer, limit: Int) throws(InflateError) {
            let result: Result<Void, InflateError> = PerMessageDeflate.tail.withUnsafeBytes { tail in
                do throws(InflateError) {
                    try inflate(tail, into: &message, limit: limit)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            try result.get()
            if noContextTakeover || streamEnded {
                decoder.reset()
                streamEnded = false
            }
        }
    }
}
