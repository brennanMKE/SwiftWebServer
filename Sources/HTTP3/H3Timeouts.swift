import Synchronization

/// Time limits for an HTTP/3 connection and its request streams (#0102), the counterpart of
/// HTTP/1.1's `HTTP1Timeouts` (#0082). `nil` turns a limit off. Handler time is never limited.
///
/// | Limit | Runs while | When it passes |
/// |---|---|---|
/// | ``header`` | a request stream has not delivered its HEADERS, from the stream's arrival | RESET_STREAM `H3_REQUEST_REJECTED` |
/// | ``idle`` | the connection has no open request stream | GOAWAY, then CONNECTION_CLOSE `H3_NO_ERROR` |
/// | ``body`` | the handler waits for request body bytes; restarts on each chunk | `408` (or RESET_STREAM `H3_REQUEST_CANCELLED` once the response started) |
/// | ``unreadBody`` | the response is complete and the rest of the request body is read and discarded | STOP_SENDING `H3_NO_ERROR` |
/// | ``drain`` | after the final GOAWAY, requests below its ID finish | CONNECTION_CLOSE `H3_NO_ERROR` |
/// | ``goawayGrace`` | between a first GOAWAY with the largest stream ID and the final one (RFC 9114 §5.2) | the final GOAWAY |
/// | ``closeLinger`` | after the drain (or the drain timeout), until the peer closes | CONNECTION_CLOSE `H3_NO_ERROR` |
///
/// ``header`` is not renewed by progress, so a client trickling its HEADERS is cut off.
/// ``closeLinger`` gives the peer time to read the GOAWAY and the last responses before
/// CONNECTION_CLOSE discards what it has not acknowledged; a peer that closes first ends it
/// early.
public struct H3Timeouts: Sendable, Hashable {
    public var header: Duration?
    public var idle: Duration?
    public var body: Duration?
    public var unreadBody: Duration?
    /// `nil`: in-flight requests run until the server's drain deadline cancels the connection.
    public var drain: Duration?
    /// `nil`: one GOAWAY with the next unprocessed stream ID.
    public var goawayGrace: Duration?
    public var closeLinger: Duration?

    public static let defaultHeader = Duration.seconds(10)
    public static let defaultIdle = Duration.seconds(30)
    public static let defaultBody = Duration.seconds(30)
    public static let defaultUnreadBody = Duration.seconds(2)
    public static let defaultCloseLinger = Duration.seconds(1)

    public init(
        header: Duration? = H3Timeouts.defaultHeader,
        idle: Duration? = H3Timeouts.defaultIdle,
        body: Duration? = H3Timeouts.defaultBody,
        unreadBody: Duration? = H3Timeouts.defaultUnreadBody,
        drain: Duration? = nil,
        goawayGrace: Duration? = nil,
        closeLinger: Duration? = H3Timeouts.defaultCloseLinger
    ) {
        for value in [header, idle, body, unreadBody, drain, goawayGrace, closeLinger] {
            if let value { precondition(value > .zero, "H3Timeouts values must be positive") }
        }
        self.header = header
        self.idle = idle
        self.body = body
        self.unreadBody = unreadBody
        self.drain = drain
        self.goawayGrace = goawayGrace
        self.closeLinger = closeLinger
    }

    /// No limits at all.
    public static let disabled = H3Timeouts(
        header: nil, idle: nil, body: nil, unreadBody: nil, drain: nil, goawayGrace: nil, closeLinger: nil)

    /// The shortest per-stream limit, or `nil` when none is set (no watch is needed).
    var streamTick: Duration? {
        [header, body, unreadBody].compactMap { $0 }.min()
    }
}

/// The per-stream deadline that ``H3Timeouts`` imposes, shared by the stream's tasks and one
/// watchdog task (#0102).
///
/// The stream publishes its phase: ``Phase/head`` (a fixed deadline from the stream's
/// arrival), ``Phase/body`` (a deadline only while the handler waits for body bytes, renewed
/// per wait), ``Phase/drain`` (a fixed deadline once the response is complete). The watchdog
/// (``run()``) sleeps until the current deadline, re-reading it at least every
/// ``H3Timeouts/streamTick``; when one passes it marks the watch fired and returns the phase,
/// unless the stream ``finish()``ed first. All of it is one lock with no suspension inside.
final class H3StreamWatch: Sendable {
    enum Phase: Sendable, Hashable {
        case head
        case body
        case drain
    }

    struct State {
        var phase = Phase.head
        /// The head or drain deadline.
        var fixed: ContinuousClock.Instant?
        /// The body deadline while the handler waits for body bytes.
        var body: ContinuousClock.Instant?
        var finished = false
        var responseStarted = false
    }

    let timeouts: H3Timeouts
    let tick: Duration
    private let state: Mutex<State>

    /// A watch for a stream that arrived `now`, or `nil` when no per-stream limit is set.
    static func make(_ timeouts: H3Timeouts, now: ContinuousClock.Instant = .now) -> H3StreamWatch? {
        guard let tick = timeouts.streamTick else { return nil }
        return H3StreamWatch(timeouts: timeouts, tick: tick, now: now)
    }

    private init(timeouts: H3Timeouts, tick: Duration, now: ContinuousClock.Instant) {
        self.timeouts = timeouts
        self.tick = tick
        var initial = State()
        initial.fixed = timeouts.header.map { now.advanced(by: $0) }
        state = Mutex(initial)
    }

    // MARK: Stream side

    /// The head arrived: from now on only the handler's waits for body bytes are limited.
    func enterBody() {
        state.withLock { state in
            state.phase = .body
            state.fixed = nil
            state.body = nil
        }
    }

    /// The handler starts waiting for body bytes.
    func armBody() {
        guard let limit = timeouts.body else { return }
        let deadline = ContinuousClock.now.advanced(by: limit)
        state.withLock { state in
            if state.phase == .body { state.body = deadline }
        }
    }

    /// The handler's wait for body bytes ended.
    func disarmBody() {
        guard timeouts.body != nil else { return }
        state.withLock { $0.body = nil }
    }

    /// The response is complete; the rest of the body is read and discarded until the
    /// ``H3Timeouts/unreadBody`` deadline.
    func enterDrain() {
        let deadline = timeouts.unreadBody.map { ContinuousClock.now.advanced(by: $0) }
        state.withLock { state in
            state.phase = .drain
            state.fixed = deadline
            state.body = nil
        }
    }

    /// The response's first bytes are about to be sent.
    func markResponseStarted() {
        state.withLock { $0.responseStarted = true }
    }

    var responseStarted: Bool { state.withLock { $0.responseStarted } }

    /// The stream is done: the watchdog will not fire.
    func finish() {
        state.withLock { $0.finished = true }
    }

    // MARK: Watchdog

    /// Sleeps until a deadline passes and returns its phase, or returns `nil` once the stream
    /// finished or the task is cancelled.
    func run() async -> Phase? {
        while true {
            let now = ContinuousClock.now
            enum Look { case finished, fired(Phase), wait(ContinuousClock.Instant?) }
            let look = state.withLock { state -> Look in
                if state.finished { return .finished }
                let deadline = state.phase == .body ? state.body : state.fixed
                if let deadline, deadline <= now {
                    state.finished = true
                    return .fired(state.phase)
                }
                return .wait(deadline)
            }
            let sleep: Duration
            switch look {
            case .finished: return nil
            case .fired(let phase): return phase
            case .wait(let deadline?): sleep = Swift.min(now.duration(to: deadline), tick)
            case .wait(nil): sleep = tick
            }
            do {
                try await Task.sleep(for: sleep)
            } catch {
                return nil
            }
        }
    }
}
