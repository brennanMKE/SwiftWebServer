/// Where a protocol connection reads request body bytes from: the HTTP/1.1 connection's
/// receive path (#0081), and later HTTP/2 and HTTP/3 DATA frames (#0048, #0101).
///
/// A source belongs to one connection and is reused across its requests; `request` names the
/// request a ``HTTPRequestBody`` was made for, so a body kept after its request ended reads
/// ``HTTPRequestBodyError/expired`` instead of the next request's bytes.
public protocol HTTPRequestBodySource: AnyObject, Sendable {
    /// Reads the next chunk of the body of `request`, or `nil` at its end. Performs the read:
    /// no bytes are received before this is called.
    func nextChunk(request: UInt64) async throws -> ByteBuffer?
    /// The trailer fields of `request`, once its body was read to the end (`nil` before that,
    /// or when the protocol sent none).
    func trailers(request: UInt64) -> HTTPFields?
}

/// Why reading a request body failed. Transport failures are thrown as they are.
public enum HTTPRequestBodyError: Error, Sendable, Hashable {
    /// The body is larger than the connection's limit (the connection answers `413`).
    case tooLarge
    /// The body's framing is invalid, such as a malformed chunk (the connection answers `400`).
    case malformed
    /// The peer ended the stream before the body was complete.
    case truncated
    /// The request this body belongs to has ended: bodies are readable only while the handler
    /// runs.
    case expired
    /// Another iterator of the same body is reading at the same time.
    case concurrentRead
}

/// A request body: an `AsyncSequence` of byte chunks whose `next()` performs the read, so
/// bytes are received only when the handler asks for them (docs/ROADMAP.md §5.2, §5.4).
///
/// There is no body task and no buffering beyond one receive: the chunks come straight off
/// the connection's receive path, and a handler that stops iterating stops the reads (the
/// transport then applies backpressure to the peer). ``empty`` costs nothing.
///
/// A body can be iterated once; it is readable only while the handler runs. A chunk handed
/// out is the handler's to keep (the connection reuses its buffer only when the chunk was
/// dropped, by copy-on-write).
public struct HTTPRequestBody: AsyncSequence, Sendable {
    public typealias Element = ByteBuffer
    public typealias Failure = any Error

    @usableFromInline
    enum Source: Sendable {
        case empty
        case stream(any HTTPRequestBodySource, request: UInt64, length: Int?)
    }

    @usableFromInline let source: Source

    @inlinable
    init(source: Source) {
        self.source = source
    }

    /// A body read from `source` for `request`. `length` is the declared length when known
    /// (`Content-Length`).
    @inlinable
    public init(source: some HTTPRequestBodySource, request: UInt64, length: Int?) {
        self.source = .stream(source, request: request, length: length)
    }

    /// A body with no bytes.
    public static let empty = HTTPRequestBody(source: .empty)

    /// True when the body is known to have no bytes without reading.
    @inlinable
    public var isEmpty: Bool {
        switch source {
        case .empty: true
        case .stream(_, _, let length): length == 0
        }
    }

    /// The declared length (`Content-Length`) when known; `nil` for a chunked body.
    @inlinable
    public var knownLength: Int? {
        switch source {
        case .empty: 0
        case .stream(_, _, let length): length
        }
    }

    /// The trailer fields, available once the body was read to the end (chunked bodies only).
    public var trailers: HTTPFields? {
        switch source {
        case .empty: nil
        case .stream(let source, let request, _): source.trailers(request: request)
        }
    }

    /// Reads the whole body into one buffer. Throws ``HTTPRequestBodyError/tooLarge`` once more
    /// than `limit` bytes arrived (bytes still unread are left to the connection to drain).
    public func collect(upTo limit: Int) async throws -> ByteBuffer {
        if let length = knownLength, length > limit { throw HTTPRequestBodyError.tooLarge }
        var result = ByteBuffer(capacity: Swift.min(knownLength ?? 0, limit))
        for try await chunk in self {
            if result.readableBytes + chunk.readableBytes > limit { throw HTTPRequestBodyError.tooLarge }
            result.append(chunk)
        }
        return result
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
            case .stream(let source, let request, _): try await source.nextChunk(request: request)
            }
        }
    }

    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(source: source)
    }
}

/// Why a ``HTTPBodyWriter`` write failed. Transport failures are thrown as they are.
public enum HTTPBodyWriterError: Error, Sendable, Hashable {
    /// The writes exceed the length the `.stream` body declared.
    case lengthExceeded
    /// The writer was used after the `.stream` closure returned.
    case closed
}
