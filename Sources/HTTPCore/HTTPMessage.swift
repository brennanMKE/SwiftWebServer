/// A request as a handler sees it, shared by HTTP/1.1, HTTP/2 and HTTP/3 (docs/ROADMAP.md §5.2).
///
/// The request borrows the connection's ``HTTPRequestStorage``: ``scheme``, ``authority``,
/// ``path`` and ``query`` are byte ranges in that storage's buffer and ``headers`` is a view
/// of its field index. It is valid only while `handle(_:context:)` runs; using it afterwards
/// traps in debug builds. Call ``snapshot()`` to keep a copy.
///
/// For HTTP/1.1, ``scheme`` and ``authority`` are empty unless the request target was in
/// absolute form; the `host` field carries the authority.
public struct HTTPRequest: Sendable {
    public var method: HTTPMethod
    public var scheme: ByteView
    public var authority: ByteView
    /// The path, still percent-encoded (decoded once, on demand, in #0084).
    public var path: ByteView
    /// The query without the `?`; empty when absent.
    public var query: ByteView
    public var headers: HTTPFieldsView
    public var body: HTTPRequestBody

    @inlinable
    public init(
        method: HTTPMethod,
        scheme: ByteView = .empty,
        authority: ByteView = .empty,
        path: ByteView,
        query: ByteView = .empty,
        headers: HTTPFieldsView,
        body: HTTPRequestBody = .empty
    ) {
        self.method = method
        self.scheme = scheme
        self.authority = authority
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// True while the request is still being handled.
    @inlinable
    public var isValid: Bool { headers.isValid }

    /// Calls `body` with the bytes of ``path``, ``query``, ``scheme``, ``authority`` or a
    /// header value range.
    @inlinable
    public func withSpan<R, E: Error>(of view: ByteView, _ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        try headers.withSpan(of: view, body)
    }

    /// The bytes of `view` as a `String`. Allocates.
    @inlinable
    public func string(of view: ByteView) -> String {
        headers.string(of: view)
    }

    /// A copy that owns its bytes and stays valid after the handler returns.
    ///
    /// The head (method, target and fields) is copied compactly into fresh storage. The body
    /// is not copied: the snapshot's body is ``HTTPRequestBody/empty``; read the body before
    /// returning if it is needed.
    public func snapshot() -> HTTPRequest {
        headers.withFieldStorage { index, arena in
            var bytes = scheme.length + authority.length + path.length + query.length
            for i in 0..<index.count { bytes += index.nameViews[i].length + index.valueViews[i].length }
            let copy = HTTPRequestStorage(bufferCapacity: bytes, fieldCapacity: index.count)
            func move(_ view: ByteView) -> ByteView {
                let start = copy.buffer.writerIndex
                copy.buffer.append(view, from: arena)
                return ByteView(offset: start, length: view.length)
            }
            let scheme = move(scheme)
            let authority = move(authority)
            let path = move(path)
            let query = move(query)
            for i in 0..<index.count {
                let field = index[i]
                copy.fields.append(field.name, nameView: move(field.nameView), valueView: move(field.valueView))
            }
            return HTTPRequest(method: method, scheme: scheme, authority: authority, path: path,
                               query: query, headers: copy.fieldsView, body: .empty)
        }
    }
}

/// A response as a handler returns it (docs/ROADMAP.md §5.2).
public struct HTTPResponse: Sendable {
    public var status: HTTPStatus
    public var headers: HTTPFields
    public var body: HTTPResponseBody

    @inlinable
    public init(status: HTTPStatus = .ok, headers: HTTPFields = HTTPFields(), body: HTTPResponseBody = .empty) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// A request body: an `AsyncSequence` of byte chunks whose `next()` performs the read, so
/// bytes are received only when the handler asks for them.
///
/// Only ``empty`` exists yet; the demand-driven `Content-Length`, chunked, HTTP/2 DATA and
/// HTTP/3 DATA sources arrive with #0081, #0048 and #0101. ``empty`` costs nothing.
public struct HTTPRequestBody: AsyncSequence, Sendable {
    public typealias Element = ByteBuffer
    public typealias Failure = any Error

    @usableFromInline
    enum Source: Sendable {
        case empty
    }

    @usableFromInline let source: Source

    @inlinable
    init(source: Source) {
        self.source = source
    }

    /// A body with no bytes.
    public static let empty = HTTPRequestBody(source: .empty)

    /// True when the body is known to have no bytes without reading.
    @inlinable
    public var isEmpty: Bool {
        switch source {
        case .empty: true
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Element = ByteBuffer
        public typealias Failure = any Error

        @usableFromInline var source: Source

        @inlinable
        init(source: Source) {
            self.source = source
        }

        @inlinable
        public mutating func next() async throws -> ByteBuffer? {
            switch source {
            case .empty: nil
            }
        }
    }

    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(source: source)
    }
}

/// The sink a ``HTTPResponseBody/stream(length:writer:)`` body writes into. Each `write`
/// suspends until the transport accepts the bytes, which is the backpressure (#0081).
public protocol HTTPBodyWriter: Sendable {
    func write(_ bytes: ByteBuffer) async throws
}

/// A response body (docs/ROADMAP.md §5.2). Serialization of every case is #0076/#0081.
public enum HTTPResponseBody: Sendable {
    /// No content.
    case empty
    /// Content already in memory.
    case bytes(ByteBuffer)
    /// Content produced by `writer`. With a known `length` the response carries
    /// `Content-Length`; with `nil` HTTP/1.1 uses chunked encoding.
    case stream(length: Int?, writer: @Sendable (any HTTPBodyWriter) async throws -> Void)
    /// Content sent from a file region with ``ByteStreamTransport/sendFile(_:)``.
    case file(FileRegion)
    /// The single protocol-switch hook: after the head is sent (`101` for HTTP/1.1, `200` for
    /// extended CONNECT on HTTP/2 and HTTP/3), the connection hands its byte stream to the
    /// closure and does no more HTTP on it.
    case tunnel(@Sendable (any ByteStreamTransport) async -> Void)

    /// The content length when it is known without running a writer.
    @inlinable
    public var knownLength: Int? {
        switch self {
        case .empty: 0
        case .bytes(let buffer): buffer.readableBytes
        case .stream(let length, _): length
        case .file(let region): Int(region.length)
        case .tunnel: nil
        }
    }
}

// MARK: - Handlers (docs/ROADMAP.md §5.2)

/// Per-request information a handler may need besides the request itself.
///
/// Minimal for now; #0083 adds the connection and server details (logger, limits, TLS state,
/// cancellation of the connection).
public struct RequestContext: Sendable {
    /// Addresses and security properties of the connection carrying the request.
    public var connection: ConnectionInfo

    @inlinable
    public init(connection: ConnectionInfo = ConnectionInfo()) {
        self.connection = connection
    }
}

/// Turns a request into a response. The request is valid only while this runs (see
/// ``HTTPRequest``).
public protocol HTTPHandler: Sendable {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse
}

/// Wraps a handler. The chain is a nested generic built at compile time, so `next` is
/// statically dispatched.
public protocol HTTPMiddleware: Sendable {
    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse
}
