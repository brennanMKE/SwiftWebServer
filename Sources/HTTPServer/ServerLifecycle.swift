public import HTTPCore

/// The server's lifecycle as a pure state machine (docs/ROADMAP.md §5.4; replaces the legacy
/// `ExitHandler`, #0005).
///
/// ```
/// idle ──start──▶ starting ──listenerReady──▶ running ──shutdownRequested──▶ draining(deadline)
///  │                 │  │                                                     │        │
///  │                 │  └─listenerFailed─▶ failed          lastConnectionClosed   drainDeadlineReached
///  │                 │                                                        ▼        ▼
///  └─shutdownRequested──┴──────────────────────────────────────────────────▶ stopped ◀──┘
/// ```
///
/// `handle(_:)` never performs I/O; it returns the one ``Action`` the server must perform.
/// Events that do not apply in the current state (a second shutdown, a late deadline, a
/// listener reporting after startup was abandoned) leave the state unchanged and return
/// ``Action/none``, so racing callers are harmless. A shutdown requested before the server is
/// running is never lost: from `idle` it stops at once, from `starting` it abandons startup.
public struct ServerLifecycle: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        /// Constructed; `run()` not called yet.
        case idle
        /// Binding listeners.
        case starting
        /// Accepting and serving connections.
        case running
        /// Not accepting; waiting for open connections to finish until `deadline`.
        case draining(deadline: Deadline)
        /// Finished. Terminal.
        case stopped
        /// Startup failed. Terminal.
        case failed
    }

    public enum Event: Sendable, Hashable {
        /// `run()` was called.
        case start
        /// Every listener is bound.
        case listenerReady
        /// A listener failed to bind.
        case listenerFailed
        /// A graceful shutdown was requested (`shutdown()`, SIGINT, SIGTERM); connections
        /// that are still open at `deadline` are cancelled.
        case shutdownRequested(deadline: Deadline)
        /// The drain deadline passed with connections still open.
        case drainDeadlineReached
        /// While draining, the listeners stopped and the last connection closed.
        case lastConnectionClosed
    }

    public enum Action: Sendable, Hashable {
        /// Nothing to do.
        case none
        /// Bind the listeners.
        case startListeners
        /// `run()` was called a second time; reject the call.
        case rejectStart
        /// Startup succeeded: accept connections.
        case acceptConnections
        /// Startup failed: close any listeners already bound and throw out of `run()`.
        case failStartup
        /// A shutdown arrived while binding: close the listeners once binding completes and
        /// return from `run()` without serving.
        case abandonStartup
        /// Stop accepting, tell connections to drain, and wait until `deadline`.
        case drain(deadline: Deadline)
        /// The deadline passed: cancel the remaining connections.
        case cancelConnections
        /// The lifecycle finished cleanly; `run()` may return.
        case finish
    }

    public private(set) var state: State

    public init() {
        state = .idle
    }

    /// True while connections are being accepted.
    public var isRunning: Bool { state == .running }

    /// True in `stopped` or `failed`.
    public var isFinished: Bool { state == .stopped || state == .failed }

    /// The drain deadline while draining.
    public var drainDeadline: Deadline? {
        if case .draining(let deadline) = state { return deadline }
        return nil
    }

    public mutating func handle(_ event: Event) -> Action {
        switch (state, event) {
        case (.idle, .start):
            state = .starting
            return .startListeners
        case (_, .start):
            return .rejectStart

        case (.idle, .shutdownRequested):
            // Shutdown before run (#0005): run() returns as soon as it is called.
            state = .stopped
            return .finish
        case (.starting, .shutdownRequested):
            state = .stopped
            return .abandonStartup
        case (.running, .shutdownRequested(let deadline)):
            state = .draining(deadline: deadline)
            return .drain(deadline: deadline)
        case (.draining, .shutdownRequested), (.stopped, .shutdownRequested), (.failed, .shutdownRequested):
            // Double shutdown: the first request wins (#0005).
            return .none

        case (.starting, .listenerReady):
            state = .running
            return .acceptConnections
        case (.starting, .listenerFailed):
            state = .failed
            return .failStartup

        case (.draining, .lastConnectionClosed):
            state = .stopped
            return .finish
        case (.draining, .drainDeadlineReached):
            state = .stopped
            return .cancelConnections

        case (_, .listenerReady), (_, .listenerFailed), (_, .lastConnectionClosed), (_, .drainDeadlineReached):
            return .none
        }
    }
}
