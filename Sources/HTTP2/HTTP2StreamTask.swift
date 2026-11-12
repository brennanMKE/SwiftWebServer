import Synchronization

/// Lets the connection cancel one stream's handler task (RFC 9113 §6.4, #0051).
///
/// A child of a task group cannot be cancelled on its own, so each stream task runs its handler
/// as the only child of a small group and waits on this object: ``finish()`` (the handler and
/// its response are done) lets the group end, and ``cancel()`` (the stream was reset, by the
/// peer or by the connection) cancels the group, so the handler sees `CancellationError`.
/// The connection keeps the object in ``HTTP2SharedState/tasks`` while the stream runs and
/// calls ``cancel()`` outside its lock.
final class HTTP2StreamTask: Sendable {
    private struct State {
        var cancelled = false
        var finished = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    init() {}

    /// Whether ``cancel()`` was called.
    var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// The stream was reset: cancel its handler.
    func cancel() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.cancelled = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// The handler and its response are done.
    func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.finished = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Suspends until ``cancel()`` or ``finish()``. Not cancellable itself: the connection's
    /// cancellation reaches the handler through the group, which then finishes.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.cancelled || state.finished { return true }
                state.waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}
