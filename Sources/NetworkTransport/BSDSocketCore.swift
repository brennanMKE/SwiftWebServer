import Darwin
import HTTPCore
import Synchronization

/// A non-blocking socket's descriptor, its kqueue waits and its close, shared by
/// ``BSDSocketTransport`` and ``BSDSocketListener`` (#0113).
///
/// ## Descriptor lifetime
///
/// A task making a system call first ``acquire()``s the descriptor and ``release()``s it
/// afterwards. ``requestClose(abortive:)`` stops new acquisitions at once, but the descriptor
/// is closed only when no call is using it, so a concurrent `read` can never hit a descriptor
/// number that was closed and reused by another connection.
///
/// ## Waits
///
/// ``wait(_:)`` parks the calling task until the descriptor is readable or writable (one-shot
/// kqueue event), the wait is cancelled, or the socket is closed. At most one wait per
/// direction. The caller always retries its system call after `.ready`, so a spurious wake-up
/// is harmless.
final class SocketCore: KQueueTarget, @unchecked Sendable {
    enum WaitOutcome: Sendable {
        case ready
        case cancelled
        case closed
    }

    enum Direction {
        case read
        case write

        var filter: Int16 { self == .read ? Int16(EVFILT_READ) : Int16(EVFILT_WRITE) }
    }

    struct State {
        var fd: Int32
        /// System calls (or kqueue arms) using `fd` right now.
        var users = 0
        /// No new system calls; `fd` is closed when `users` reaches 0.
        var closing = false
        var closed = false
        var abortive = false
        var readWaiter: UnsafeContinuation<WaitOutcome, Never>?
        var writeWaiter: UnsafeContinuation<WaitOutcome, Never>?
        /// A wait was armed in this direction at some point; close then removes any left over.
        var everArmedRead = false
        var everArmedWrite = false

        // Transport state (unused by the listener).
        /// `close(_:)` was called, or a cancelled receive/send closed the connection.
        var closedLocally = false
        var closeCalled = false
        var receiving = false
        var sending = false
        /// The peer finished sending; sticky.
        var inputEnded = false
        /// A receive error; sticky.
        var inputError: TransportError?
        var outputShutdown = false
    }

    let state: Mutex<State>
    let loop: BSDEventLoop
    /// Whether cancelling a wait closes the socket (connections: the read or write position is
    /// undefined afterwards) or only ends the wait (the listener).
    let closesOnCancel: Bool

    init(fd: Int32, loop: BSDEventLoop, closesOnCancel: Bool) {
        state = Mutex(State(fd: fd))
        self.loop = loop
        self.closesOnCancel = closesOnCancel
    }

    // MARK: Descriptor

    /// The descriptor for one system call, or `nil` once closing.
    func acquire() -> Int32? {
        state.withLock { state in
            guard !state.closing else { return nil }
            state.users += 1
            return state.fd
        }
    }

    func release() {
        let finish = state.withLock { state -> (Int32, Bool, Bool, Bool)? in
            state.users -= 1
            return Self.takeFinish(&state)
        }
        if let finish { finishClose(finish) }
    }

    /// Stops new system calls, fails pending waits with `.closed`, and closes the descriptor
    /// once no call is using it. Idempotent.
    func requestClose(abortive: Bool) {
        let taken = state.withLock { state -> (UnsafeContinuation<WaitOutcome, Never>?, UnsafeContinuation<WaitOutcome, Never>?, (Int32, Bool, Bool, Bool)?)? in
            guard !state.closing else { return nil }
            state.closing = true
            state.abortive = abortive
            defer { state.readWaiter = nil; state.writeWaiter = nil }
            return (state.readWaiter, state.writeWaiter, Self.takeFinish(&state))
        }
        guard let taken else { return }
        taken.0?.resume(returning: .closed)
        taken.1?.resume(returning: .closed)
        if let finish = taken.2 { finishClose(finish) }
    }

    private static func takeFinish(_ state: inout State) -> (Int32, Bool, Bool, Bool)? {
        guard state.closing, !state.closed, state.users == 0 else { return nil }
        state.closed = true
        return (state.fd, state.abortive, state.everArmedRead, state.everArmedWrite)
    }

    private func finishClose(_ finish: (fd: Int32, abortive: Bool, read: Bool, write: Bool)) {
        // Remove waits that have not fired, so their retains are released before the
        // descriptor number can be reused.
        if finish.read { loop.disarm(fd: finish.fd, filter: Int16(EVFILT_READ), target: self) }
        if finish.write { loop.disarm(fd: finish.fd, filter: Int16(EVFILT_WRITE), target: self) }
        if finish.abortive {
            // SO_LINGER 0: discard unsent bytes and send RST.
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            setsockopt(finish.fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        }
        Darwin.close(finish.fd)
    }

    // MARK: Waits

    func wait(_ direction: Direction) async -> WaitOutcome {
        await withTaskCancellationHandler {
            await withUnsafeContinuation { (continuation: UnsafeContinuation<WaitOutcome, Never>) in
                let armFD: Int32? = state.withLock { state in
                    if Task.isCancelled || state.closing { return nil }
                    state.users += 1
                    switch direction {
                    case .read:
                        precondition(state.readWaiter == nil, "SocketCore: concurrent read waits")
                        state.readWaiter = continuation
                        state.everArmedRead = true
                    case .write:
                        precondition(state.writeWaiter == nil, "SocketCore: concurrent write waits")
                        state.writeWaiter = continuation
                        state.everArmedWrite = true
                    }
                    return state.fd
                }
                guard let armFD else {
                    continuation.resume(returning: Task.isCancelled ? .cancelled : .closed)
                    return
                }
                if loop.arm(fd: armFD, filter: direction.filter, target: self) != 0 {
                    // Could not wait: wake at once; the retried system call reports the error.
                    take(direction)?.resume(returning: .ready)
                }
                release()
            }
        } onCancel: {
            cancelWait(direction)
        }
    }

    private func take(_ direction: Direction) -> UnsafeContinuation<WaitOutcome, Never>? {
        state.withLock { state in
            switch direction {
            case .read:
                defer { state.readWaiter = nil }
                return state.readWaiter
            case .write:
                defer { state.writeWaiter = nil }
                return state.writeWaiter
            }
        }
    }

    private func cancelWait(_ direction: Direction) {
        guard let waiter = take(direction) else { return }
        waiter.resume(returning: .cancelled)
        if closesOnCancel {
            state.withLock { $0.closedLocally = true }
            requestClose(abortive: false)
        } else if let fd = acquire() {
            // Remove the wait so the next one arms afresh. If it already fired, the loop
            // delivers it to whoever waits next, which just retries. (If that next wait arms
            // before the delivery, `EV_ADD` updates the new wait in place and one retain of
            // this long-lived listener core is never released: a bounded, rare leak.)
            loop.disarm(fd: fd, filter: direction.filter, target: self)
            release()
        }
    }

    override func eventFired(filter: Int16) {
        let waiter = take(filter == Int16(EVFILT_READ) ? .read : .write)
        waiter?.resume(returning: .ready)
    }
}
