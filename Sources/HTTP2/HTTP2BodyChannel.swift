public import HTTPCore
import Synchronization

/// Where a request body returns flow-control credit: the connection, which turns it into
/// WINDOW_UPDATE frames (`HTTP2ConnectionDriver`).
protocol HTTP2ReceiveCredit: AnyObject, Sendable {
    /// `length` bytes of `streamID`'s DATA were consumed by the handler or discarded. Their
    /// connection credit goes back; `streamIncrement`, when set, is stream credit to send.
    func bodyConsumed(streamID: HTTP2StreamID, length: Int, streamIncrement: UInt32?)
}

/// The ``HTTPRequestBodySource`` behind an HTTP/2 request's ``HTTPRequestBody``: the DATA
/// payloads of one stream (RFC 9113 §8.1), buffered by the connection's reader until the
/// handler pulls them.
///
/// ## Bounds and backpressure
///
/// The reader cannot stop reading for one stream without stalling every other stream, so the
/// bound is flow control (§5.2): the peer may have at most the stream's receive window
/// (``window``) of DATA outstanding, and stream credit goes back only as the handler consumes
/// bytes. A handler that does not read stalls its own stream at the window; one that reads
/// gets a stream WINDOW_UPDATE each time half the window was consumed. Connection credit for
/// the same bytes goes back on consumption too (``HTTP2ReceiveCredit``). DATA past the window
/// is a stream `FLOW_CONTROL_ERROR`.
///
/// `next()` is the pull signal: it hands the handler everything buffered as one chunk and
/// returns the credit (#0053 builds its window policy on this hook).
///
/// ## Ends
///
/// - END_STREAM ends the body; a trailer section is available afterwards (``trailers``).
/// - A DATA total that differs from `content-length` makes the body
///   ``HTTPRequestBodyError/malformed`` (the connection resets the stream with
///   `PROTOCOL_ERROR`), as does an invalid trailer section.
/// - A reset stream (either side) is ``TransportError/connectionReset``; a closed connection
///   ``TransportError/closed``. Bytes still buffered are discarded and their credit returned.
/// - After the handler returned (``expire()``), reads throw ``HTTPRequestBodyError/expired``,
///   and DATA that still arrives is discarded and credited at once.
/// - A cancelled read throws `CancellationError`, unless the body already ended with an error,
///   which wins.
final class HTTP2BodyChannel: HTTPRequestBodySource {
    /// What the reader does after handing over DATA or the end of the body.
    enum Delivery: Equatable {
        case accepted
        /// The DATA total disagrees with `content-length`, or the trailers are invalid: reset
        /// the stream with `PROTOCOL_ERROR`.
        case malformed
        /// The peer sent past the stream window: reset the stream with `FLOW_CONTROL_ERROR`.
        case flowControlError
    }

    struct State {
        var buffered = ByteBuffer()
        /// DATA payload bytes received, for `content-length`.
        var received = 0
        /// Bytes received and not yet returned as stream credit: the window in use.
        var outstanding = 0
        /// Bytes consumed and not yet returned as stream credit (batched to half the window).
        var uncredited = 0
        var ended = false
        var failure: (any Error)?
        var trailers: HTTPFields?
        var expired = false
        var reading = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    let streamID: HTTP2StreamID
    let declaredLength: Int?
    /// The most DATA bytes the peer may have outstanding on the stream.
    let window: Int
    /// Consumed bytes returned as one stream WINDOW_UPDATE.
    let creditThreshold: Int
    let credit: any HTTP2ReceiveCredit
    private let state = Mutex(State())

    init(streamID: HTTP2StreamID, declaredLength: Int?, window: Int, credit: any HTTP2ReceiveCredit) {
        self.streamID = streamID
        self.declaredLength = declaredLength
        self.window = window
        creditThreshold = Swift.max(1, window / 2)
        self.credit = credit
    }

    /// The request ID ``HTTPRequestBody`` passes back.
    var requestID: UInt64 { UInt64(streamID.rawValue) }

    /// Bytes buffered and not yet taken by the handler (for tests).
    var bufferedBytes: Int { state.withLock { $0.buffered.readableBytes } }

    // MARK: Reader side

    /// Hands over a piece of a DATA payload.
    func receive(_ bytes: UnsafeRawBufferPointer) -> Delivery {
        let count = bytes.count
        var waiter: CheckedContinuation<Void, Never>?
        var discard = 0
        var increment: UInt32?
        let delivery = state.withLock { state -> Delivery in
            if state.failure != nil || state.ended {
                // The stream was reset: the rest of the frame is credited and dropped.
                discard = count
                return .accepted
            }
            state.received += count
            state.outstanding += count
            if let declaredLength, state.received > declaredLength {
                discard = Self.fail(&state, HTTPRequestBodyError.malformed, waiter: &waiter) + count
                return .malformed
            }
            if state.outstanding > window {
                discard = Self.fail(&state, HTTPRequestBodyError.malformed, waiter: &waiter) + count
                return .flowControlError
            }
            if state.expired {
                discard = count
                increment = consume(count, &state)
                return .accepted
            }
            bytes.withMemoryRebound(to: UInt8.self) { state.buffered.append(contentsOf: $0.span) }
            waiter = state.waiter
            state.waiter = nil
            return .accepted
        }
        waiter?.resume()
        if discard > 0 { credit.bodyConsumed(streamID: streamID, length: discard, streamIncrement: increment) }
        return delivery
    }

    /// END_STREAM: the body is complete, with `trailers` if the request had them.
    func finish(trailers: HTTPFields?) -> Delivery {
        var waiter: CheckedContinuation<Void, Never>?
        var discard = 0
        let delivery = state.withLock { state -> Delivery in
            guard state.failure == nil else { return .accepted }
            if let declaredLength, state.received != declaredLength {
                discard = Self.fail(&state, HTTPRequestBodyError.malformed, waiter: &waiter)
                return .malformed
            }
            state.ended = true
            state.trailers = trailers
            // No more stream credit is needed once the peer finished sending.
            state.uncredited = 0
            waiter = state.waiter
            state.waiter = nil
            return .accepted
        }
        waiter?.resume()
        if discard > 0 { credit.bodyConsumed(streamID: streamID, length: discard, streamIncrement: nil) }
        return delivery
    }

    /// Ends the body with `error` (the first error wins), discarding what is buffered and
    /// returning its connection credit.
    func fail(_ error: any Error) {
        var waiter: CheckedContinuation<Void, Never>?
        let discard = state.withLock { Self.fail(&$0, error, waiter: &waiter) }
        waiter?.resume()
        if discard > 0 { credit.bodyConsumed(streamID: streamID, length: discard, streamIncrement: nil) }
    }

    /// The handler returned: later reads throw ``HTTPRequestBodyError/expired``; buffered and
    /// later DATA is discarded and credited.
    func expire() {
        var increment: UInt32?
        let discard = state.withLock { state -> Int in
            state.expired = true
            let count = state.buffered.readableBytes
            state.buffered = ByteBuffer()
            increment = consume(count, &state)
            return count
        }
        if discard > 0 || increment != nil {
            credit.bodyConsumed(streamID: streamID, length: discard, streamIncrement: increment)
        }
    }

    /// Records `error` unless the body already failed; drops the buffer. Returns the dropped
    /// byte count.
    private static func fail(_ state: inout State, _ error: any Error, waiter: inout CheckedContinuation<Void, Never>?) -> Int {
        if state.failure == nil && !state.ended { state.failure = error }
        let dropped = state.buffered.readableBytes
        state.buffered = ByteBuffer()
        waiter = state.waiter
        state.waiter = nil
        return dropped
    }

    /// Counts `count` consumed bytes; returns stream credit to send once half the window was
    /// consumed (none after END_STREAM: the peer sends nothing more).
    private func consume(_ count: Int, _ state: inout State) -> UInt32? {
        guard !state.ended else { return nil }
        state.uncredited += count
        guard state.uncredited >= creditThreshold else { return nil }
        let increment = state.uncredited
        state.outstanding -= increment
        state.uncredited = 0
        return UInt32(increment)
    }

    // MARK: HTTPRequestBodySource

    func nextChunk(request: UInt64) async throws -> ByteBuffer? {
        try state.withLock { state throws(HTTPRequestBodyError) in
            guard request == requestID, !state.expired else { throw .expired }
            guard !state.reading else { throw .concurrentRead }
            state.reading = true
        }
        defer { state.withLock { $0.reading = false } }
        while true {
            enum Step {
                case chunk(ByteBuffer, UInt32?)
                case end
                case failed(any Error)
                case wait
            }
            let step = state.withLock { state -> Step in
                if state.buffered.readableBytes > 0 {
                    let chunk = state.buffered
                    state.buffered = ByteBuffer()
                    return .chunk(chunk, consume(chunk.readableBytes, &state))
                }
                if let failure = state.failure { return .failed(failure) }
                if state.ended { return .end }
                return .wait
            }
            switch step {
            case .chunk(let chunk, let increment):
                credit.bodyConsumed(streamID: streamID, length: chunk.readableBytes, streamIncrement: increment)
                return chunk
            case .end:
                return nil
            case .failed(let error):
                throw error
            case .wait:
                try Task.checkCancellation()
                await waitForData()
            }
        }
    }

    func trailers(request: UInt64) -> HTTPFields? {
        state.withLock { $0.ended ? $0.trailers : nil }
    }

    /// Suspends until DATA, the end, a failure, or cancellation.
    private func waitForData() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.buffered.readableBytes > 0 || state.ended || state.failure != nil || Task.isCancelled {
                        return true
                    }
                    state.waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }
    }
}
