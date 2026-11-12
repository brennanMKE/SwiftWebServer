public import HPACK
public import HTTPCore
import HeaderCompression

// Request heads in, response heads out: the minimal mapping between HPACK header blocks and
// `HTTPRequest`/`HTTPResponse` that the connection core (#0044) needs. #0047 completes request
// validation (cookie joining, `content-length` against DATA) and #0049 the response path.

/// Copies decoded request fields into an ``HTTPRequestStorage`` and validates them in order
/// with ``PseudoHeaderValidator`` (RFC 9113 §8.3.1).
struct HTTP2RequestFieldSink: HPACKFieldSink {
    let storage: HTTPRequestStorage
    var validator = PseudoHeaderValidator(kind: .request)
    var violation: PseudoHeaderValidator.Violation?
    var scheme = ByteView.empty
    var authority = ByteView.empty
    var path = ByteView.empty

    init(storage: HTTPRequestStorage) {
        self.storage = storage
    }

    mutating func field(name: Span<UInt8>, value: Span<UInt8>, representation: HPACKRepresentation) {
        // Every field is still decoded (HPACK state must advance), but after the first
        // violation nothing more is kept.
        guard violation == nil else { return }
        if let result = validator.handle(name: name, value: value) {
            violation = result
            return
        }
        let id = HTTPFieldName.lookup(name)
        let nameView = storage.buffer.appendSpan(name)
        let valueView = storage.buffer.appendSpan(value)
        switch id {
        case .pseudoScheme: scheme = valueView
        case .pseudoAuthority: authority = valueView
        case .pseudoPath: path = valueView
        case .pseudoMethod, .pseudoProtocol: break
        default: storage.fields.append(id, nameView: nameView, valueView: valueView)
        }
    }

    /// The request, or the violation that makes it malformed (a stream `PROTOCOL_ERROR`).
    func request() -> Result<HTTPRequest, PseudoHeaderValidator.Violation> {
        if let violation = violation ?? validator.finish() { return .failure(violation) }
        guard let method = validator.method else { return .failure(.missingPseudoHeader(.pseudoMethod)) }
        var path = self.path
        var query = ByteView.empty
        let question = storage.buffer.withSpan(of: path) { span -> Int? in
            for i in span.indices where span[i] == UInt8(ascii: "?") { return i }
            return nil
        }
        if let question {
            query = path.subview((question + 1)..<path.length)
            path = path.subview(0..<question)
        }
        return .success(HTTPRequest(
            method: method, scheme: scheme, authority: authority, path: path, query: query,
            headers: storage.fieldsView))
    }
}

/// Decodes and drops every field: header blocks of streams that are not served (refused,
/// reset, above GOAWAY, trailers) must still go through HPACK (RFC 9113 §4.3).
struct HTTP2DiscardingFieldSink: HPACKFieldSink {
    mutating func field(name: Span<UInt8>, value: Span<UInt8>, representation: HPACKRepresentation) {}
}

/// Encodes response heads with HPACK and frames them as HEADERS plus CONTINUATION frames
/// (RFC 9113 §8.3.2, §4.3).
///
/// Used inside the connection's critical section, so the dynamic table is updated in exactly
/// the order the blocks go on the wire, and a block's frames are contiguous.
struct HTTP2ResponseHeadEncoder: Sendable {
    var hpack: HPACKEncoder
    /// The HPACK block being built; reused across responses.
    var block: [UInt8] = []
    /// A lowercased field name; reused.
    var name: [UInt8] = []

    init(tableCapacity: Int) {
        hpack = HPACKEncoder(tableCapacity: tableCapacity, peerMaxTableSize: Int(HTTP2Connection.defaultHeaderTableSize))
        block.reserveCapacity(256)
    }

    /// Applies the peer's SETTINGS_HEADER_TABLE_SIZE: the next block starts with a size update.
    mutating func setPeerMaxTableSize(_ size: UInt32) {
        hpack.setPeerMaxTableSize(Int(size))
    }

    /// Appends the frames of a response head on `streamID` to `out`.
    ///
    /// `:status` comes first; field names are lowercased; the connection-specific fields
    /// HTTP/2 forbids (`connection`, `keep-alive`, `proxy-connection`, `transfer-encoding`,
    /// `upgrade`) are dropped; `content-length` is added when the length is known and the
    /// handler did not set it.
    mutating func encode(
        streamID: HTTP2StreamID, status: HTTPStatus, headers: HTTPFields, contentLength: Int?, endStream: Bool,
        maxFrameSize: Int, into out: inout ByteBuffer
    ) {
        Self.encodeBlock(hpack: &hpack, block: &block, name: &name, status: status, headers: headers,
                         contentLength: contentLength)
        Self.frame(block: block, streamID: streamID, endStream: endStream, maxFrameSize: maxFrameSize, into: &out)
    }

    /// Builds the HPACK block in `block`. Static over disjoint `inout`s so the closures below
    /// never overlap accesses to `self`.
    private static func encodeBlock(
        hpack: inout HPACKEncoder, block: inout [UInt8], name: inout [UInt8], status: HTTPStatus,
        headers: HTTPFields, contentLength: Int?
    ) {
        block.removeAll(keepingCapacity: true)
        hpack.beginHeaderBlock(into: &block)
        var code: (UInt8, UInt8, UInt8) = (
            UInt8(ascii: "0") &+ UInt8(status.code / 100 % 10),
            UInt8(ascii: "0") &+ UInt8(status.code / 10 % 10),
            UInt8(ascii: "0") &+ UInt8(status.code % 10))
        withUnsafeBytes(of: &code) { value in
            encodeField(":status", value: value, hpack: &hpack, block: &block)
        }
        var sawContentLength = false
        headers.withFieldStorage { index, arena in
            for i in 0..<index.count {
                let field = index[i]
                switch field.name {
                case .connection, .keepAlive, .proxyConnection, .transferEncoding, .upgrade:
                    continue
                case .contentLength:
                    sawContentLength = true
                default:
                    break
                }
                if field.name.isPseudoHeader { continue }
                name.removeAll(keepingCapacity: true)
                if field.name.isWellKnown {
                    field.name.canonicalName.withUTF8Buffer { name.append(contentsOf: $0) }
                } else {
                    arena.withSpan(of: field.nameView) { span in
                        for j in span.indices { name.append(ASCII.lowercased(span[j])) }
                    }
                }
                arena.withSpan(of: field.valueView) { value in
                    name.withUnsafeBufferPointer { name in
                        hpack.encode(name: name.span, value: value, into: &block)
                    }
                }
            }
        }
        if let contentLength, !sawContentLength {
            var digits = ByteBuffer(capacity: 20)
            digits.append(decimal: contentLength)
            digits.withUnsafeReadableBytes { value in
                encodeField("content-length", value: value, hpack: &hpack, block: &block)
            }
        }
    }

    private static func encodeField(
        _ fieldName: StaticString, value: UnsafeRawBufferPointer, hpack: inout HPACKEncoder, block: inout [UInt8]
    ) {
        fieldName.withUTF8Buffer { name in
            value.withMemoryRebound(to: UInt8.self) { value in
                hpack.encode(name: name.span, value: value.span, into: &block)
            }
        }
    }

    /// Splits `block` into a HEADERS frame and as many CONTINUATION frames as `maxFrameSize`
    /// requires, appended back to back.
    static func frame(block: [UInt8], streamID: HTTP2StreamID, endStream: Bool, maxFrameSize: Int, into out: inout ByteBuffer) {
        block.withUnsafeBytes { bytes in
            var offset = Swift.min(bytes.count, maxFrameSize)
            HTTP2FrameEncoder.encodeHeaders(
                streamID: streamID, fragment: UnsafeRawBufferPointer(rebasing: bytes[0..<offset]),
                endStream: endStream, endHeaders: offset == bytes.count, into: &out)
            while offset < bytes.count {
                let end = Swift.min(bytes.count, offset + maxFrameSize)
                HTTP2FrameEncoder.encodeContinuation(
                    streamID: streamID, fragment: UnsafeRawBufferPointer(rebasing: bytes[offset..<end]),
                    endHeaders: end == bytes.count, into: &out)
                offset = end
            }
        }
    }
}

extension ByteBuffer {
    /// Appends the bytes of `span` and returns their view.
    mutating func appendSpan(_ span: Span<UInt8>) -> ByteView {
        let start = writerIndex
        append(contentsOf: span)
        return ByteView(offset: start, length: span.count)
    }
}
