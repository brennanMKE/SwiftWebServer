public import HTTPCore

/// A split-invariant WebSocket frame parser (RFC 6455 §5.2): a value-type state machine that
/// reads frame headers and streams unmasked payload bytes into a sink.
///
/// Each ``parse(_:payloadInto:)`` call consumes what it can from the input and returns one
/// result. Feeding the same bytes split at any offsets yields the same headers and payload
/// bytes. The parser checks only what one frame can show:
///
/// | Violation | Close code |
/// |---|---|
/// | RSV bit set that no negotiated extension allows | 1002 |
/// | reserved opcode (3–7, 11–15) | 1002 |
/// | control frame with FIN clear, or longer than 125 bytes | 1002 |
/// | unmasked frame from a client (masked frame from a server) | 1002 |
/// | 64-bit length with the most significant bit set | 1002 |
/// | payload longer than ``Configuration/maxFrameSize`` | 1009 |
///
/// Message-level rules (continuation without a start, a new message inside a fragmented one,
/// UTF-8, message size) belong to ``WSConnection``. Minimal length encoding is not required
/// on read (RFC 6455 §5.2 leaves it to the sender).
public struct WSFrameParser: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Largest payload accepted in one frame; longer frames fail with 1009.
        public var maxFrameSize: Int
        /// RSV bits (`0x40`, `0x20`, `0x10`) that a negotiated extension gives meaning to.
        /// With none negotiated, any RSV bit is a protocol error.
        public var allowedReservedBits: UInt8
        /// True for a server: every client frame must be masked (RFC 6455 §5.1). False for a
        /// client: server frames must not be.
        public var expectsMaskedFrames: Bool

        public init(maxFrameSize: Int = 16 * 1024 * 1024, allowedReservedBits: UInt8 = 0, expectsMaskedFrames: Bool = true) {
            precondition(maxFrameSize >= 125, "control frames need 125 bytes")
            self.maxFrameSize = maxFrameSize
            self.allowedReservedBits = allowedReservedBits & 0x70
            self.expectsMaskedFrames = expectsMaskedFrames
        }
    }

    /// The result of one ``parse(_:payloadInto:)`` call.
    public enum Result: Sendable, Hashable {
        /// The input holds no complete header (or no payload byte) yet.
        case needMoreBytes
        /// A frame header was read; its payload follows (even when empty).
        case header(WSFrameHeader)
        /// `count` unmasked payload bytes were appended to the sink. `frameEnd` is true when
        /// they were the frame's last (a frame with an empty payload reports `count` 0).
        case payload(count: Int, frameEnd: Bool)
        /// The frame violates the protocol; the connection must fail with `code`.
        case error(WebSocketCloseCode)
    }

    enum State: Sendable, Hashable {
        case header
        /// `remaining` payload bytes to deliver; `offset` bytes of this frame already unmasked.
        case payload(remaining: UInt64, maskKey: UInt32?, offset: Int)
        case failed(WebSocketCloseCode)
    }

    public let configuration: Configuration
    var state: State = .header

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// True between a header and the end of its payload.
    public var isInFrame: Bool {
        if case .payload = state { return true }
        return false
    }

    /// Consumes bytes from `input` and reports one header, one run of payload bytes, or an
    /// error. Payload bytes are unmasked into `sink`; with `maxPayloadBytes` the run is capped
    /// (for a caller that bounds what it buffers). After an error every call repeats it.
    public mutating func parse(_ input: inout ByteBuffer, payloadInto sink: inout ByteBuffer,
                               maxPayloadBytes: Int = .max) -> Result {
        switch state {
        case .failed(let code):
            return .error(code)
        case .header:
            return parseHeader(&input)
        case .payload(let remaining, let maskKey, let offset):
            if remaining == 0 {
                state = .header
                return .payload(count: 0, frameEnd: true)
            }
            let available = min(UInt64(input.readableBytes), remaining, UInt64(max(maxPayloadBytes, 0)))
            guard available > 0 else { return .needMoreBytes }
            let count = Int(available)
            if let maskKey {
                WSMasking.moveUnmasked(count, from: &input, into: &sink, key: maskKey, offset: offset)
            } else {
                sink.withUnsafeMutableWritableBytes(minimumWritableBytes: count) { to in
                    input.withUnsafeReadableBytes { from in
                        to.baseAddress!.copyMemory(from: from.baseAddress!, byteCount: count)
                    }
                }
                sink.commitWritten(count)
                input.moveReaderIndex(forwardBy: count)
            }
            let left = remaining &- available
            state = left == 0 ? .header : .payload(remaining: left, maskKey: maskKey, offset: (offset &+ count) & 3)
            return .payload(count: count, frameEnd: left == 0)
        }
    }

    mutating func parseHeader(_ input: inout ByteBuffer) -> Result {
        let start = input.readerIndex
        let readable = input.readableBytes
        guard readable >= 2 else { return .needMoreBytes }
        let first = input.byte(at: start)
        let second = input.byte(at: start &+ 1)

        // Checks that need only the first two bytes fail at once, without waiting for the
        // rest of the header.
        let reserved = first & 0x70
        if reserved & ~configuration.allowedReservedBits != 0 { return fail(.protocolError) }
        guard let opcode = WSOpcode(rawValue: first & 0x0F) else { return fail(.protocolError) }
        let fin = first & 0x80 != 0
        let masked = second & 0x80 != 0
        if masked != configuration.expectsMaskedFrames { return fail(.protocolError) }
        let length7 = second & 0x7F
        if opcode.isControl {
            if !fin { return fail(.protocolError) }
            if length7 > 125 { return fail(.protocolError) }
        }

        var headerSize = 2
        switch length7 {
        case 126: headerSize &+= 2
        case 127: headerSize &+= 8
        default: break
        }
        if masked { headerSize &+= 4 }
        guard readable >= headerSize else { return .needMoreBytes }

        var length: UInt64
        var cursor = start &+ 2
        switch length7 {
        case 126:
            length = UInt64(input.getInteger(at: cursor, as: UInt16.self)!)
            cursor &+= 2
        case 127:
            length = input.getInteger(at: cursor, as: UInt64.self)!
            cursor &+= 8
            if length & (1 << 63) != 0 { return fail(.protocolError) }
        default:
            length = UInt64(length7)
        }
        if length > UInt64(configuration.maxFrameSize) { return fail(.messageTooBig) }
        var maskKey: UInt32?
        if masked {
            maskKey = input.getInteger(at: cursor, as: UInt32.self)!
            cursor &+= 4
        }
        input.moveReaderIndex(forwardBy: headerSize)
        state = .payload(remaining: length, maskKey: maskKey, offset: 0)
        return .header(WSFrameHeader(fin: fin, reservedBits: reserved, opcode: opcode, maskKey: maskKey,
                                     payloadLength: length))
    }

    mutating func fail(_ code: WebSocketCloseCode) -> Result {
        state = .failed(code)
        return .error(code)
    }
}
