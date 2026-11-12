public import HPACK
public import HTTPCore
import HeaderCompression

// Request heads in, response heads out: the mapping between HPACK header blocks and
// `HTTPRequest`/`HTTPResponse` (RFC 9113 §8.1–§8.3, #0047 and #0049).

/// Why a request head is malformed (RFC 9113 §8.1.1). Every case is a stream
/// `PROTOCOL_ERROR`, never a connection error.
enum HTTP2MalformedRequest: Error, Hashable, Sendable {
    /// A field or pseudo-header rule of ``PseudoHeaderValidator``.
    case field(PseudoHeaderValidator.Violation)
    /// `content-length` is not a decimal number, or two values differ.
    case invalidContentLength
    /// `content-length` is above zero but the HEADERS frame ended the stream (§8.1.1: the
    /// value must equal the DATA total, which is zero).
    case contentLengthWithoutBody
    /// `host` names a different authority than `:authority` (§8.3.1).
    case hostMismatch
}

/// A validated request head and what the body checks need.
struct HTTP2RequestHead {
    var request: HTTPRequest
    /// The declared `content-length`, which the DATA total must equal (#0048).
    var contentLength: Int?
}

/// Copies decoded request fields into an ``HTTPRequestStorage`` and validates them in order
/// (RFC 9113 §8.1.1, §8.2, §8.3.1):
///
/// - ``PseudoHeaderValidator`` (shared with HTTP/3): exactly one `:method`, `:scheme` and
///   `:path` (non-empty, `*` only for OPTIONS), `:authority` or `host`, pseudo-headers first,
///   no unknown or response pseudo-headers, lowercase token names, values without CR, LF, NUL
///   or surrounding whitespace, no connection-specific fields, `te` only as `trailers`;
/// - `content-length` must be a decimal number, repeated only with the same value, and zero
///   when HEADERS ends the stream; the DATA total is checked against it as the body arrives;
/// - `host`, when sent with `:authority`, must name the same authority;
/// - `cookie` crumbs (§8.2.3) are joined with `"; "` into one field for the handler.
///
/// The first violation is kept; later fields are still decoded (HPACK must stay in step) but
/// not stored.
struct HTTP2RequestFieldSink: HPACKFieldSink {
    let storage: HTTPRequestStorage
    var validator = PseudoHeaderValidator(kind: .request)
    var failure: HTTP2MalformedRequest?
    var scheme = ByteView.empty
    var authority = ByteView.empty
    var path = ByteView.empty
    var host: ByteView?
    var contentLength: Int?
    /// The first `cookie` field's name and value; later crumbs in ``moreCookies``.
    var cookieName: ByteView?
    var firstCookie = ByteView.empty
    var moreCookies: [ByteView] = []

    init(storage: HTTPRequestStorage) {
        self.storage = storage
    }

    mutating func field(name: Span<UInt8>, value: Span<UInt8>, representation: HPACKRepresentation) {
        guard failure == nil else { return }
        if let violation = validator.handle(name: name, value: value) {
            failure = .field(violation)
            return
        }
        let id = HTTPFieldName.lookup(name)
        if id == .contentLength {
            guard let parsed = ASCII.parseDecimal(value), parsed <= UInt64(Int.max),
                  contentLength == nil || contentLength == Int(parsed)
            else {
                failure = .invalidContentLength
                return
            }
            contentLength = Int(parsed)
        }
        let nameView = storage.buffer.appendSpan(name)
        let valueView = storage.buffer.appendSpan(value)
        switch id {
        case .pseudoScheme: scheme = valueView
        case .pseudoAuthority: authority = valueView
        case .pseudoPath: path = valueView
        case .pseudoMethod, .pseudoProtocol: break
        case .cookie:
            // Joined in `head(endStream:)` once every crumb is known.
            if cookieName == nil {
                cookieName = nameView
                firstCookie = valueView
            } else {
                moreCookies.append(valueView)
            }
        case .host:
            host = valueView
            storage.fields.append(id, nameView: nameView, valueView: valueView)
        default:
            storage.fields.append(id, nameView: nameView, valueView: valueView)
        }
    }

    /// The request, or why it is malformed. `endStream` is the HEADERS frame's END_STREAM.
    mutating func head(endStream: Bool) -> Result<HTTP2RequestHead, HTTP2MalformedRequest> {
        if let failure { return .failure(failure) }
        if let violation = validator.finish() { return .failure(.field(violation)) }
        guard let method = validator.method else { return .failure(.field(.missingPseudoHeader(.pseudoMethod))) }
        if endStream, let contentLength, contentLength > 0 { return .failure(.contentLengthWithoutBody) }
        if let host, validator.hasSeen(.pseudoAuthority), !sameAuthority(host, authority) {
            return .failure(.hostMismatch)
        }
        if let cookieName { joinCookies(name: cookieName) }
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
        let request = HTTPRequest(
            method: method, scheme: scheme, authority: authority, path: path, query: query,
            headers: storage.fieldsView)
        return .success(HTTP2RequestHead(request: request, contentLength: contentLength))
    }

    /// Adds one `cookie` field whose value is every crumb joined with `"; "` (§8.2.3).
    private mutating func joinCookies(name: ByteView) {
        guard !moreCookies.isEmpty else {
            storage.fields.append(.cookie, nameView: name, valueView: firstCookie)
            return
        }
        let buffer = storage.buffer
        let start = buffer.writerIndex
        storage.buffer.append(firstCookie, from: buffer)
        for crumb in moreCookies {
            storage.buffer.append("; ")
            storage.buffer.append(crumb, from: buffer)
        }
        let joined = ByteView(offset: start, length: storage.buffer.writerIndex - start)
        storage.fields.append(.cookie, nameView: name, valueView: joined)
    }

    /// Case-insensitive comparison of two authorities in the storage buffer.
    private func sameAuthority(_ a: ByteView, _ b: ByteView) -> Bool {
        guard a.length == b.length else { return false }
        let buffer = storage.buffer
        return buffer.withSpan(of: a) { a in
            buffer.withSpan(of: b) { b in
                for i in a.indices where ASCII.lowercased(a[i]) != ASCII.lowercased(b[i]) { return false }
                return true
            }
        }
    }
}

/// Collects a request's trailer section (RFC 9113 §8.1): regular, well-formed fields only.
/// A pseudo-header or an invalid field makes the request malformed.
struct HTTP2TrailerFieldSink: HPACKFieldSink {
    var validator = PseudoHeaderValidator(kind: .request)
    var failure: HTTP2MalformedRequest?
    var fields = HTTPFields()

    mutating func field(name: Span<UInt8>, value: Span<UInt8>, representation: HPACKRepresentation) {
        guard failure == nil else { return }
        if !name.isEmpty && name[0] == UInt8(ascii: ":") {
            failure = .field(.pseudoHeaderAfterRegularField)
            return
        }
        if let violation = validator.handle(name: name, value: value) {
            failure = .field(violation)
            return
        }
        fields.append(name: name, value: value)
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
