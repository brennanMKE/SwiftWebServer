public import HTTPCore
public import QPACK
import HeaderCompression

/// Why a HEADERS frame could not become a request.
public enum H3HeadError: Error, Sendable, Equatable {
    /// The message is malformed (RFC 9114 §4.1.2): stream error `H3_MESSAGE_ERROR`.
    case malformed(PseudoHeaderValidator.Violation)
    /// The decoded field section exceeds `SETTINGS_MAX_FIELD_SECTION_SIZE`: answered `431`.
    case fieldSectionTooLarge
    /// QPACK could not decode the section: connection error with this `QPACK_*` code.
    case qpack(QPACKError)

    /// Whether this is a request-level (stream) error rather than a connection error.
    public var isStreamError: Bool {
        if case .qpack = self { return false }
        return true
    }
}

/// Decodes a request HEADERS frame into an ``HTTPRequest`` (RFC 9114 §4.1, §4.3.1).
///
/// Every field is copied into the stream's ``HTTPRequestStorage`` once and checked by
/// ``PseudoHeaderValidator`` (`:method`, `:scheme`, `:authority` or `host`, `:path`, lowercase
/// names, no connection-specific fields, `te: trailers` only). Pseudo-header values become the
/// request's method, scheme, authority, path and query; regular fields go into the field
/// index. Cookie crumbs are kept as separate fields for now (RFC 9114 §4.2.1 allows joining
/// them; that is left to a later change).
public enum H3RequestHeadDecoder {
    /// Decodes `section` into `storage` and returns the request.
    public static func decode(
        _ section: UnsafeRawBufferPointer, decoder: inout QPACKDecoder, storage: HTTPRequestStorage
    ) throws(H3HeadError) -> HTTPRequest {
        var sink = RequestFieldSink(storage: storage)
        do throws(QPACKError) {
            try decoder.decode(section, into: &sink)
        } catch {
            if let violation = sink.violation { throw .malformed(violation) }
            if error.reason == .fieldSectionTooLarge { throw .fieldSectionTooLarge }
            throw .qpack(error)
        }
        if let violation = sink.violation ?? sink.validator.finish() { throw .malformed(violation) }
        guard let method = sink.validator.method else { throw .malformed(.missingPseudoHeader(.pseudoMethod)) }
        // Split `:path` into path and query at the first `?`.
        var path = sink.path
        var query = ByteView.empty
        let question = storage.buffer.withSpan(of: path) { span -> Int? in
            for i in span.indices where span[i] == UInt8(ascii: "?") { return i }
            return nil
        }
        if let question {
            query = path.subview((question + 1)..<path.length)
            path = path.subview(0..<question)
        }
        return HTTPRequest(
            method: method, scheme: sink.scheme, authority: sink.authority, path: path, query: query,
            headers: storage.fieldsView)
    }

    /// Decodes a trailing HEADERS frame: only regular, well-formed fields are allowed
    /// (RFC 9114 §4.1.2). Returns them for ``HTTPRequestBody/trailers``.
    public static func decodeTrailers(
        _ section: UnsafeRawBufferPointer, decoder: inout QPACKDecoder
    ) throws(H3HeadError) -> HTTPFields {
        var sink = TrailerFieldSink()
        do throws(QPACKError) {
            try decoder.decode(section, into: &sink)
        } catch {
            if let violation = sink.violation { throw .malformed(violation) }
            if error.reason == .fieldSectionTooLarge { throw .fieldSectionTooLarge }
            throw .qpack(error)
        }
        if let violation = sink.violation { throw .malformed(violation) }
        return sink.fields
    }
}

/// Copies decoded fields into request storage and validates them in order.
struct RequestFieldSink: QPACKFieldSink {
    let storage: HTTPRequestStorage
    var validator = PseudoHeaderValidator(kind: .request)
    var violation: PseudoHeaderValidator.Violation?
    var scheme = ByteView.empty
    var authority = ByteView.empty
    var path = ByteView.empty

    init(storage: HTTPRequestStorage) {
        self.storage = storage
    }

    mutating func field(name: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer, neverIndexed: Bool) {
        guard violation == nil else { return }
        let nameView = storage.buffer.appendRaw(name)
        let valueView = storage.buffer.appendRaw(value)
        let buffer = storage.buffer
        var validator = self.validator
        let (result, id) = buffer.withSpan(of: nameView) { name in
            buffer.withSpan(of: valueView) { value in
                (validator.handle(name: name, value: value), HTTPFieldName.lookup(name))
            }
        }
        self.validator = validator
        if let result {
            violation = result
            return
        }
        switch id {
        case .pseudoScheme: scheme = valueView
        case .pseudoAuthority: authority = valueView
        case .pseudoPath: path = valueView
        case .pseudoMethod, .pseudoProtocol: break
        default: storage.fields.append(id, nameView: nameView, valueView: valueView)
        }
    }
}

/// Collects trailer fields, which must be regular fields (RFC 9114 §4.1.2).
struct TrailerFieldSink: QPACKFieldSink {
    var validator = PseudoHeaderValidator(kind: .request)
    var violation: PseudoHeaderValidator.Violation?
    var fields = HTTPFields()

    mutating func field(name: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer, neverIndexed: Bool) {
        guard violation == nil else { return }
        if name.first == UInt8(ascii: ":") {
            violation = .pseudoHeaderAfterRegularField
            return
        }
        var validator = self.validator
        var fields = self.fields
        violation = name.withMemoryRebound(to: UInt8.self) { name in
            value.withMemoryRebound(to: UInt8.self) { value in
                let violation = validator.handle(name: name.span, value: value.span)
                if violation == nil { fields.append(name: name.span, value: value.span) }
                return violation
            }
        }
        self.validator = validator
        self.fields = fields
    }
}

extension ByteBuffer {
    /// Appends raw bytes and returns their view.
    mutating func appendRaw(_ bytes: UnsafeRawBufferPointer) -> ByteView {
        let start = writerIndex
        guard !bytes.isEmpty else { return ByteView(offset: start, length: 0) }
        reserveCapacity(minimumWritableBytes: bytes.count)
        withUnsafeMutableWritableBytes { destination in
            destination.baseAddress!.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        commitWritten(bytes.count)
        return ByteView(offset: start, length: bytes.count)
    }
}

// MARK: - Response heads

/// A ``ByteSink`` that appends to a ``ByteBuffer``.
struct ByteBufferSink: ByteSink {
    var buffer: ByteBuffer

    mutating func append(_ byte: UInt8) { buffer.append(byte) }

    mutating func reserveAdditionalCapacity(_ count: Int) {
        buffer.reserveCapacity(minimumWritableBytes: count)
    }
}

/// Encodes response heads as HTTP/3 HEADERS frames with static-table QPACK (RFC 9114 §4.1,
/// §4.3.2).
///
/// `:status` comes first. Field names are lowercased (RFC 9114 §4.2), and the connection-specific
/// fields HTTP/3 forbids (`connection`, `keep-alive`, `proxy-connection`, `transfer-encoding`,
/// `upgrade`) are dropped. `content-length` is added when the body length is known and the
/// handler did not set it.
public struct H3ResponseHeadEncoder: Sendable {
    let qpack = QPACKEncoder()
    var section: [UInt8] = []
    var name: [UInt8] = []

    public init() {}

    /// Appends the HEADERS frame for `status` and `headers` to `buffer`.
    public mutating func encode(
        status: HTTPStatus, headers: HTTPFields, contentLength: Int?, into buffer: inout ByteBuffer
    ) {
        section.removeAll(keepingCapacity: true)
        qpack.encodePrefix(into: &section)
        var code: (UInt8, UInt8, UInt8) = (
            UInt8(ascii: "0") &+ UInt8(status.code / 100 % 10),
            UInt8(ascii: "0") &+ UInt8(status.code / 10 % 10),
            UInt8(ascii: "0") &+ UInt8(status.code % 10))
        withUnsafeBytes(of: &code) { value in
            encodeLiteral(":status", value: value)
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
                    value.withUnsafeBytes { value in
                        name.withUnsafeBytes { name in
                            qpack.encodeField(name: name, value: value, into: &section)
                        }
                    }
                }
            }
        }
        if let contentLength, !sawContentLength {
            var digits = ByteBuffer(capacity: 20)
            digits.append(decimal: contentLength)
            digits.withUnsafeReadableBytes { value in
                encodeLiteral("content-length", value: value)
            }
        }
        var sink = ByteBufferSink(buffer: buffer)
        buffer = ByteBuffer()
        section.withUnsafeBytes { payload in
            // A field section is far below the varint limit.
            try! H3FrameEncoder.encodeFrameHeader(type: .headers, length: UInt64(payload.count), into: &sink)
            _ = sink.buffer.appendRaw(payload)
        }
        buffer = sink.buffer
    }

    mutating func encodeLiteral(_ name: StaticString, value: UnsafeRawBufferPointer) {
        name.withUTF8Buffer { name in
            qpack.encodeField(name: UnsafeRawBufferPointer(name), value: value, into: &section)
        }
    }
}
