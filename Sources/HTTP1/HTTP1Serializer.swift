public import HTTPCore

/// What the connection decided about persistence, plus the request facts that change how a
/// response is framed. Built by the connection state machine (#0080) for each response.
public struct HTTP1ResponseContext: Sendable, Hashable {
    /// The `Connection` field the serializer writes. The decision belongs to the connection
    /// state machine (#0080); the serializer only renders it.
    public enum Persistence: Sendable, Hashable {
        /// `connection: keep-alive`: the connection stays open for the next request.
        case keepAlive
        /// `connection: close`: the connection closes after this response.
        case close
    }

    /// The method of the request being answered. `HEAD` responses carry no content.
    public var requestMethod: HTTPMethod
    public var persistence: Persistence

    @inlinable
    public init(requestMethod: HTTPMethod = .get, persistence: Persistence = .keepAlive) {
        self.requestMethod = requestMethod
        self.persistence = persistence
    }

    @inlinable
    var isHead: Bool {
        if case .head = requestMethod { return true }
        return false
    }
}

/// What remains to be sent after ``HTTP1Serializer/write(_:into:context:)`` returns.
public enum HTTP1BodyFraming: Sendable, Hashable {
    /// The head and any content are in the buffer; send it and the response is done.
    case complete
    /// The head is in the buffer and the runner sends exactly this many content bytes from the
    /// `.file` region or the `.stream` writer, unframed.
    case contentLength(Int)
    /// The head is in the buffer with `transfer-encoding: chunked`; the runner frames each
    /// write of the `.stream` writer with ``HTTP1ChunkedEncoder`` and ends with the last chunk.
    case chunked
    /// The head is in the buffer; after sending it the runner hands the byte stream to the
    /// `.tunnel` closure.
    case tunnel
}

/// A response that ``HTTP1Serializer/writeValidated(_:into:context:)`` refused because
/// writing it would let a value inject header lines or end the head early (response
/// splitting).
public enum HTTP1SerializationError: Error, Sendable, Hashable {
    /// The field at `position` has a name that is not an RFC 9110 token.
    case invalidFieldName(position: Int)
    /// The field at `position` has a value with CR, LF, NUL or another control byte.
    case invalidFieldValue(position: Int)
    /// The custom reason phrase contains a control byte.
    case invalidReasonPhrase
}

/// Writes HTTP/1.1 response heads (and in-memory content) straight into the connection's
/// output ``ByteBuffer`` (docs/ROADMAP.md §5.3, §7).
///
/// One serializer belongs to one connection; it owns that connection's ``DateCache``, which
/// is why ``write(_:into:context:)`` is `mutating`. Writing allocates nothing once the output
/// buffer has grown to fit and creates no `String`.
///
/// ## Output
///
/// 1. The status line, a pre-rendered literal from ``HTTPStatus``.
/// 2. The response's fields in insertion order, names in lowercase (well-known names as
///    ``HTTPFieldName/canonicalName``, others as given). Field names are case-insensitive
///    (RFC 9110 §5.1), and lowercase matches HTTP/2 and HTTP/3.
/// 3. `date`, unless the response already has one (RFC 9110 §6.6.1).
/// 4. Framing: `content-length` or `transfer-encoding: chunked`.
/// 5. `connection: keep-alive` or `connection: close`, from the context.
/// 6. The blank line, then the content of a `.bytes` body.
///
/// ## Framing rules
///
/// | Response | Framing written | Content written | Returns |
/// |---|---|---|---|
/// | `.empty` | `content-length: 0` | – | `.complete` |
/// | `.bytes(b)` | `content-length: b.count` | `b` | `.complete` |
/// | `.file(r)` / `.stream(length: n)` | `content-length` | – (runner sends it) | `.contentLength(n)` |
/// | `.stream(length: nil)` | `transfer-encoding: chunked` | – (runner sends it) | `.chunked` |
/// | `.tunnel` | none (RFC 9110 §9.3.6), no `connection` | – | `.tunnel` |
/// | `HEAD` request or `304` | `content-length` of the content that a `GET` / `200` would carry, when known; a `.empty` or chunked body writes none and passes the handler's own `content-length` through (RFC 9110 §8.6, §15.4.5) | – | `.complete` |
/// | `204` | none (RFC 9110 §8.6, RFC 9112 §6.1) | – | `.complete` |
/// | `1xx` | the handler's fields only: no `date`, framing or `connection` (so `101` keeps the handler's `connection: upgrade`) | – | `.tunnel` for `101` with a `.tunnel` body, else `.complete` |
///
/// The serializer owns framing: the handler's `transfer-encoding` and `connection` fields are
/// not written (except for `1xx` and `.tunnel`), nor is its `content-length` when the
/// serializer writes its own. A handler `content-length` that disagrees with the body, or
/// that a `204`, chunked or tunnel response must not carry, is a programming error: debug
/// builds assert and release builds write the serializer's framing.
///
/// ## Field validation
///
/// Debug builds assert that every name is a token and every value is free of CR, LF, NUL and
/// other control bytes. Release builds skip that check on ``write(_:into:context:)``; use
/// ``writeValidated(_:into:context:)`` for responses whose fields carry untrusted bytes (a
/// `location` built from the request, say), which checks first and writes nothing on failure.
public struct HTTP1Serializer<Clock: WallClock>: Sendable {
    /// The connection's date cache.
    public var dateCache: DateCache<Clock>

    @inlinable
    public init(dateCache: DateCache<Clock>) {
        self.dateCache = dateCache
    }

    @inlinable
    public init(clock: Clock) {
        self.init(dateCache: DateCache(clock: clock))
    }

    /// Longest ``HTTPFieldName/canonicalName`` (`access-control-allow-credentials`); checked
    /// by `HTTP1SerializerTests.longestWellKnownNameFitsTheBound`.
    public static var maximumWellKnownNameLength: Int { 32 }

    /// Appends the response head (and the content of a `.bytes` body) to `buffer`.
    @inlinable
    @discardableResult
    public mutating func write(
        _ response: HTTPResponse, into buffer: inout ByteBuffer, context: HTTP1ResponseContext
    ) -> HTTP1BodyFraming {
        assert(Self.validationError(response) == nil,
               "HTTP1Serializer: response has a field or reason phrase that would split the head (\(String(describing: Self.validationError(response))))")
        let status = response.status
        let code = status.code

        // Decide framing.
        let informational = code < 200
        let lengthOnly = context.isHead || code == 304
        var contentLength = -1          // -1: write no content-length
        var chunked = false
        var framing = HTTP1BodyFraming.complete
        var isTunnel = false
        var content: ByteBuffer?
        switch response.body {
        case .empty:
            contentLength = lengthOnly ? -1 : 0
        case .bytes(let bytes):
            contentLength = bytes.readableBytes
            content = bytes
        case .file(let region):
            contentLength = Int(region.length)
            framing = .contentLength(contentLength)
        case .stream(let length?, _):
            precondition(length >= 0, "HTTPResponseBody.stream length must not be negative")
            contentLength = length
            framing = .contentLength(length)
        case .stream(nil, _):
            chunked = true
            framing = .chunked
        case .tunnel:
            isTunnel = true
            framing = .tunnel
        }
        if lengthOnly && !isTunnel {
            chunked = false
            framing = .complete
            content = nil
        }
        if code == 204 {
            contentLength = -1
            chunked = false
            content = nil
            if !isTunnel { framing = .complete }
        }
        if informational {
            contentLength = -1
            chunked = false
            content = nil
            framing = isTunnel && code == 101 ? .tunnel : .complete
        } else {
            assert(Self.handlerContentLengthAgrees(response, writing: contentLength, chunked: chunked,
                                                   isTunnel: isTunnel, lengthOnly: lengthOnly),
                   "HTTP1Serializer: the response's content-length conflicts with its body or status")
        }
        // A HEAD or 304 response with no known length keeps the handler's content-length.
        let skipContentLength = !informational && !(lengthOnly && contentLength < 0 && !isTunnel)
        let skipHopByHop = !informational && !isTunnel

        response.headers.withFieldStorage { index, arena in
            // One reservation covers the whole head: field bytes are bounded by the arena, and
            // everything the serializer adds is bounded by 160 bytes plus the reason phrase.
            var bound = arena.writerIndex &+ index.count &* (Self.maximumWellKnownNameLength &+ 4) &+ 160
            if status.http1StatusLine == nil { bound &+= status.withReasonPhrase { $0.count } }
            if let content { bound &+= content.readableBytes }
            buffer.withWriter(reservingCapacity: bound) { writer in
                if let line = status.http1StatusLine {
                    writer.append(line)
                } else {
                    writer.append("HTTP/1.1 ")
                    writer.append(decimal: code)
                    writer.append(UInt8(ascii: " "))
                    status.withReasonPhrase { writer.append(contentsOf: $0) }
                    writer.append(0x0D, 0x0A)
                }
                Self.writeFields(index, arena, to: &writer,
                                 skipContentLength: skipContentLength, skipHopByHop: skipHopByHop)
                if informational {
                    writer.append(0x0D, 0x0A)
                    return
                }
                if !index.contains(.date) {
                    writer.append("date: ")
                    dateCache.append(to: &writer)
                    writer.append(0x0D, 0x0A)
                }
                if contentLength >= 0 {
                    writer.append("content-length: ")
                    writer.append(decimal: contentLength)
                    writer.append(0x0D, 0x0A)
                } else if chunked {
                    writer.append("transfer-encoding: chunked\r\n")
                }
                if isTunnel {
                    writer.append(0x0D, 0x0A)
                } else {
                    switch context.persistence {
                    case .keepAlive: writer.append("connection: keep-alive\r\n\r\n")
                    case .close: writer.append("connection: close\r\n\r\n")
                    }
                }
                if let content { writer.append(content) }
            }
        }
        return framing
    }

    /// Checks every field name, field value and the reason phrase, then writes the response
    /// like ``write(_:into:context:)``. On failure nothing is written.
    @inlinable
    @discardableResult
    public mutating func writeValidated(
        _ response: HTTPResponse, into buffer: inout ByteBuffer, context: HTTP1ResponseContext
    ) throws(HTTP1SerializationError) -> HTTP1BodyFraming {
        if let error = Self.validationError(response) { throw error }
        return write(response, into: &buffer, context: context)
    }

    // MARK: Fields

    /// Writes `name: value\r\n` for each field. Skipped fields (framing and hop-by-hop
    /// fields the serializer owns) are found with the index's presence mask first, so a
    /// response without them pays nothing per field.
    @inlinable
    static func writeFields(
        _ index: HTTPFieldIndex, _ arena: ByteBuffer, to writer: inout ByteBuffer.Writer,
        skipContentLength: Bool, skipHopByHop: Bool
    ) {
        let names = index.names
        let nameViews = index.nameViews
        let valueViews = index.valueViews
        let mustFilter = (skipContentLength && index.contains(.contentLength))
            || (skipHopByHop && (index.contains(.transferEncoding) || index.contains(.connection)))
        for i in 0..<names.count {
            let name = names[i]
            if mustFilter {
                if name == .contentLength && skipContentLength { continue }
                if (name == .transferEncoding || name == .connection) && skipHopByHop { continue }
            }
            if name.isWellKnown {
                writer.append(name.canonicalName)
            } else {
                writer.append(nameViews[i], from: arena)
            }
            writer.append(UInt8(ascii: ":"), UInt8(ascii: " "))
            writer.append(valueViews[i], from: arena)
            writer.append(0x0D, 0x0A)
        }
    }

    // MARK: Checks

    /// The first field or reason phrase that would split the head, or `nil`.
    @inlinable
    public static func validationError(_ response: HTTPResponse) -> HTTP1SerializationError? {
        let reasonValid = response.status.withReasonPhrase { phrase in
            for i in phrase.indices where !ASCII.isFieldValueCharacter(phrase[i]) { return false }
            return true
        }
        if !reasonValid { return .invalidReasonPhrase }
        return response.headers.withFieldStorage { index, arena in
            validationError(index, arena)
        }
    }

    /// The first field in `index` whose name is not a token or whose value has a control
    /// byte, or `nil`. Also used for chunked trailers.
    @inlinable
    public static func validationError(_ index: HTTPFieldIndex, _ arena: ByteBuffer) -> HTTP1SerializationError? {
        for i in 0..<index.count {
            let field = index[i]
            if !field.name.isWellKnown {
                let nameValid = arena.withSpan(of: field.nameView) { name in
                    guard !name.isEmpty else { return false }
                    for j in name.indices where !ASCII.isTokenCharacter(name[j]) { return false }
                    return true
                }
                if !nameValid { return .invalidFieldName(position: i) }
            }
            let valueValid = arena.withSpan(of: field.valueView) { value in
                for j in value.indices where !ASCII.isFieldValueCharacter(value[j]) { return false }
                return true
            }
            if !valueValid { return .invalidFieldValue(position: i) }
        }
        return nil
    }

    /// Debug check: a handler-supplied `content-length` must agree with what the serializer
    /// writes, and must be absent where RFC 9110 forbids it (204, chunked, tunnel).
    @inlinable
    static func handlerContentLengthAgrees(
        _ response: HTTPResponse, writing contentLength: Int, chunked: Bool, isTunnel: Bool, lengthOnly: Bool
    ) -> Bool {
        let supplied = response.headers.contentLength()
        if case .absent = supplied { return true }
        if isTunnel || chunked || response.status.code == 204 {
            // A HEAD or 304 response to a chunked GET may still state a length.
            return lengthOnly && !isTunnel && response.status.code != 204
        }
        if contentLength < 0 {
            // HEAD or 304 with no body: the handler's value stands for the GET / 200 content.
            if case .value = supplied { return true }
            return false
        }
        return supplied == .value(UInt64(contentLength))
    }
}

extension HTTP1Serializer where Clock == SystemWallClock {
    /// A serializer whose date cache reads the system clock.
    @inlinable
    public init() {
        self.init(dateCache: DateCache())
    }
}

/// Chunked transfer coding (RFC 9112 §7.1) for `.stream` bodies of unknown length.
///
/// A stream is sent as ``appendChunk(_:into:)`` per write (or ``appendChunkHeader(size:into:)``
/// before and ``appendChunkEnd(into:)`` after bytes sent separately), then
/// ``appendLastChunk(into:)`` or ``appendLastChunk(trailers:into:)``.
public enum HTTP1ChunkedEncoder {
    /// Appends `<hex size>\r\n`. `size` must be positive: a zero-size chunk ends the body.
    @inlinable
    public static func appendChunkHeader(size: Int, into buffer: inout ByteBuffer) {
        precondition(size > 0, "a chunk must not be empty; use appendLastChunk to end the body")
        buffer.append(hex: UInt64(size))
        buffer.append("\r\n")
    }

    /// Appends the `\r\n` that ends a chunk's data.
    @inlinable
    public static func appendChunkEnd(into buffer: inout ByteBuffer) {
        buffer.append("\r\n")
    }

    /// Appends one chunk holding the readable bytes of `data`. Empty data appends nothing, so
    /// an empty write cannot end the body early.
    @inlinable
    public static func appendChunk(_ data: ByteBuffer, into buffer: inout ByteBuffer) {
        guard !data.isEmpty else { return }
        appendChunkHeader(size: data.readableBytes, into: &buffer)
        buffer.append(data)
        buffer.append("\r\n")
    }

    /// Appends the last chunk with no trailer section: `0\r\n\r\n`.
    @inlinable
    public static func appendLastChunk(into buffer: inout ByteBuffer) {
        buffer.append("0\r\n\r\n")
    }

    /// Appends the last chunk followed by `trailers` (RFC 9112 §7.1.2) and the blank line.
    /// Debug builds assert that the trailer names and values are valid.
    @inlinable
    public static func appendLastChunk(trailers: HTTPFields, into buffer: inout ByteBuffer) {
        trailers.withFieldStorage { index, arena in
            assert(HTTP1Serializer<SystemWallClock>.validationError(index, arena) == nil,
                   "HTTP1ChunkedEncoder: a trailer field would split the message")
            let bound = arena.writerIndex &+ index.count &* (HTTP1Serializer<SystemWallClock>.maximumWellKnownNameLength &+ 4) &+ 5
            buffer.withWriter(reservingCapacity: bound) { writer in
                writer.append("0\r\n")
                HTTP1Serializer<SystemWallClock>.writeFields(index, arena, to: &writer,
                                                             skipContentLength: false, skipHopByHop: false)
                writer.append(0x0D, 0x0A)
            }
        }
    }
}
