public import HTTPCore
import Synchronization

/// The ``HTTPRequestBodySource`` behind an HTTP/3 request's ``HTTPRequestBody``: DATA frame
/// payloads of one request stream (RFC 9114 §4.1).
///
/// The stream's reader (``H3ConnectionDriver``) parses frames and sends each DATA payload
/// piece into a ``BoundedAsyncQueue`` of ``H3Configuration/bodyQueueCapacity`` chunks; it
/// stops reading the QUIC stream while the queue is full, so a handler that does not read
/// applies QUIC flow control to the client. The handler's `next()` takes from the queue.
///
/// Errors, after any chunks already queued:
/// - a malformed body (DATA that disagrees with `content-length`, trailers with pseudo-header
///   fields, a frame out of order) is ``HTTPRequestBodyError/malformed``; a stream ending inside
///   a frame is ``HTTPRequestBodyError/truncated``;
/// - a peer reset is ``TransportError/connectionReset`` (the handler task is also cancelled);
/// - after the handler returned, ``HTTPRequestBodyError/expired``.
final class H3BodyChannel: HTTPRequestBodySource {
    struct State {
        var failure: (any Error)?
        var trailers: HTTPFields?
        var reading = false
        var expired = false
    }

    let queue: BoundedAsyncQueue<ByteBuffer>
    /// The request stream's ID; the `request` that ``HTTPRequestBody`` passes back.
    let streamID: UInt64
    private let state = Mutex(State())

    init(capacity: Int, streamID: UInt64) {
        queue = BoundedAsyncQueue(capacity: capacity)
        self.streamID = streamID
    }

    /// True when the body ended with an error.
    var failed: Bool { state.withLock { $0.failure != nil } }

    // MARK: Reader side

    /// Ends the body normally (FIN), with the request's trailers if it had any.
    func finish(trailers: HTTPFields?) {
        state.withLock { $0.trailers = trailers }
        queue.finish()
    }

    /// Ends the body with `error`; the handler sees it after the chunks already queued.
    func fail(_ error: any Error) {
        state.withLock { if $0.failure == nil { $0.failure = error } }
        queue.finish()
    }

    /// The handler returned: later reads throw ``HTTPRequestBodyError/expired``.
    func expire() {
        state.withLock { $0.expired = true }
    }

    // MARK: HTTPRequestBodySource

    func nextChunk(request: UInt64) async throws -> ByteBuffer? {
        try state.withLock { state throws(HTTPRequestBodyError) in
            guard request == streamID, !state.expired else { throw .expired }
            guard !state.reading else { throw .concurrentRead }
            state.reading = true
        }
        defer { state.withLock { $0.reading = false } }
        if let chunk = await queue.next() { return chunk }
        // The reader records why the body ended before the handler task is cancelled, so the
        // specific error wins over the cancellation.
        if let failure = state.withLock({ $0.failure }) { throw failure }
        try Task.checkCancellation()
        return nil
    }

    func trailers(request: UInt64) -> HTTPFields? {
        state.withLock { $0.trailers }
    }
}
