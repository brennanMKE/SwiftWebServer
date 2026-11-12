import HTTPCore
import Synchronization

/// Limits against hostile HTTP/3 clients (RFC 9114 §10, and the HTTP/2 DoS list in
/// `docs/HTTP2.md`, adapted to QUIC streams; #0104). `nil` turns a limit off.
///
/// | Limit | Counts | When it passes |
/// |---|---|---|
/// | ``maxAbortedRequestsPerWindow`` | request streams the peer resets (or STOP_SENDINGs) before the response is complete, or ends without a complete request (a rapid-reset analogue) | CONNECTION_CLOSE `H3_EXCESSIVE_LOAD` |
/// | ``maxIgnoredUniStreamsPerWindow`` | reserved and unknown unidirectional streams (each is refused with STOP_SENDING, but costs a stream) | CONNECTION_CLOSE `H3_EXCESSIVE_LOAD` |
/// | ``maxQPACKInstructionsPerWindow`` | instructions on the peer's QPACK encoder and decoder streams (with a table capacity of 0 the only legal encoder instruction is a no-op; with a dynamic table each insert counts) | CONNECTION_CLOSE `H3_EXCESSIVE_LOAD` |
/// | ``maxControlFramesPerWindow`` | frames on the peer's control stream after SETTINGS, unknown and reserved ones included | CONNECTION_CLOSE `H3_EXCESSIVE_LOAD` |
/// | ``maxUnknownRequestFramesPerWindow`` | reserved and unknown frames on request streams | CONNECTION_CLOSE `H3_EXCESSIVE_LOAD` |
/// | ``maxUnknownFrameLength`` | the declared length of one reserved or unknown frame, on any stream | CONNECTION_CLOSE `H3_EXCESSIVE_LOAD` |
/// | ``maxConnectionSendBuffer`` | response bytes inside sends that have not completed, across the connection | further sends wait (with ``H3Timeouts/send``, a slow reader's streams are reset with `H3_REQUEST_CANCELLED`) |
/// | ``maxIdleConnections`` | connections of one ``HTTP3`` value with no open request stream | the longest-idle one gets GOAWAY, then CONNECTION_CLOSE `H3_NO_ERROR` |
///
/// The per-window counts use one fixed ``window`` per connection: a count starts at the first
/// event and resets once ``window`` has passed since then. Each count is checked under the
/// connection's lock, only when its event happens (never per DATA byte).
public struct H3AbuseLimits: Sendable, Hashable {
    public var window: Duration
    public var maxAbortedRequestsPerWindow: Int?
    public var maxIgnoredUniStreamsPerWindow: Int?
    public var maxQPACKInstructionsPerWindow: Int?
    public var maxControlFramesPerWindow: Int?
    public var maxUnknownRequestFramesPerWindow: Int?
    public var maxUnknownFrameLength: Int?
    public var maxConnectionSendBuffer: Int?
    public var maxIdleConnections: Int?

    public static let defaultWindow = Duration.seconds(10)

    public init(
        window: Duration = H3AbuseLimits.defaultWindow,
        maxAbortedRequestsPerWindow: Int? = 100,
        maxIgnoredUniStreamsPerWindow: Int? = 16,
        maxQPACKInstructionsPerWindow: Int? = 1000,
        maxControlFramesPerWindow: Int? = 1000,
        maxUnknownRequestFramesPerWindow: Int? = 1000,
        maxUnknownFrameLength: Int? = 16 * 1024,
        maxConnectionSendBuffer: Int? = 4 * 1024 * 1024,
        maxIdleConnections: Int? = 1000
    ) {
        precondition(window > .zero, "H3AbuseLimits.window must be positive")
        for limit in [maxAbortedRequestsPerWindow, maxIgnoredUniStreamsPerWindow, maxQPACKInstructionsPerWindow,
                      maxControlFramesPerWindow, maxUnknownRequestFramesPerWindow, maxUnknownFrameLength] {
            if let limit { precondition(limit >= 0, "H3AbuseLimits limits must not be negative") }
        }
        if let maxConnectionSendBuffer { precondition(maxConnectionSendBuffer > 0, "H3AbuseLimits.maxConnectionSendBuffer must be positive") }
        if let maxIdleConnections { precondition(maxIdleConnections >= 0, "H3AbuseLimits.maxIdleConnections must not be negative") }
        self.window = window
        self.maxAbortedRequestsPerWindow = maxAbortedRequestsPerWindow
        self.maxIgnoredUniStreamsPerWindow = maxIgnoredUniStreamsPerWindow
        self.maxQPACKInstructionsPerWindow = maxQPACKInstructionsPerWindow
        self.maxControlFramesPerWindow = maxControlFramesPerWindow
        self.maxUnknownRequestFramesPerWindow = maxUnknownRequestFramesPerWindow
        self.maxUnknownFrameLength = maxUnknownFrameLength
        self.maxConnectionSendBuffer = maxConnectionSendBuffer
        self.maxIdleConnections = maxIdleConnections
    }

    /// No limits at all.
    public static let disabled = H3AbuseLimits(
        maxAbortedRequestsPerWindow: nil, maxIgnoredUniStreamsPerWindow: nil, maxQPACKInstructionsPerWindow: nil,
        maxControlFramesPerWindow: nil, maxUnknownRequestFramesPerWindow: nil, maxUnknownFrameLength: nil,
        maxConnectionSendBuffer: nil, maxIdleConnections: nil)
}

/// What a hostile peer did too often (``H3Failure/excessiveLoad(_:)``).
public enum H3AbuseKind: Sendable, Hashable, CaseIterable {
    /// ``H3AbuseLimits/maxAbortedRequestsPerWindow``.
    case abortedRequests
    /// ``H3AbuseLimits/maxIgnoredUniStreamsPerWindow``.
    case ignoredUniStreams
    /// ``H3AbuseLimits/maxQPACKInstructionsPerWindow``.
    case qpackInstructions
    /// ``H3AbuseLimits/maxControlFramesPerWindow``.
    case controlFrames
    /// ``H3AbuseLimits/maxUnknownRequestFramesPerWindow``.
    case unknownRequestFrames
}

/// The per-connection counts behind ``H3AbuseLimits``. A value type with no I/O; the runner
/// keeps it under the connection's lock and passes the time in.
public struct H3AbuseMonitor: Sendable {
    struct Count: Sendable {
        var windowStart: ContinuousClock.Instant?
        var count = 0
    }

    public let limits: H3AbuseLimits
    var counts = [Count](repeating: Count(), count: H3AbuseKind.allCases.count)

    public init(limits: H3AbuseLimits) {
        self.limits = limits
    }

    func limit(_ kind: H3AbuseKind) -> Int? {
        switch kind {
        case .abortedRequests: limits.maxAbortedRequestsPerWindow
        case .ignoredUniStreams: limits.maxIgnoredUniStreamsPerWindow
        case .qpackInstructions: limits.maxQPACKInstructionsPerWindow
        case .controlFrames: limits.maxControlFramesPerWindow
        case .unknownRequestFrames: limits.maxUnknownRequestFramesPerWindow
        }
    }

    static func index(_ kind: H3AbuseKind) -> Int {
        switch kind {
        case .abortedRequests: 0
        case .ignoredUniStreams: 1
        case .qpackInstructions: 2
        case .controlFrames: 3
        case .unknownRequestFrames: 4
        }
    }

    /// Records `amount` events of `kind` at `now`. Returns `false` when the window's count is
    /// now over the limit.
    public mutating func record(_ kind: H3AbuseKind, amount: Int = 1, now: ContinuousClock.Instant) -> Bool {
        guard let limit = limit(kind), amount > 0 else { return true }
        let i = Self.index(kind)
        if let start = counts[i].windowStart, start.advanced(by: limits.window) > now {
            counts[i].count += amount
        } else {
            counts[i] = Count(windowStart: now, count: amount)
        }
        return counts[i].count <= limit
    }

    /// The count of `kind` in the current window (for tests).
    public func count(_ kind: H3AbuseKind) -> Int { counts[Self.index(kind)].count }
}

/// A connection-wide byte budget for response sends (``H3AbuseLimits/maxConnectionSendBuffer``):
/// a send takes `min(bytes, capacity)` before it starts and gives it back when it completes,
/// so sends stalled by a client that does not read hold at most `capacity` bytes in total, and
/// later sends on the connection wait. Cancelling a waiting task ends its wait with
/// `CancellationError`.
///
/// Waiting sends are served by RFC 9218 priority (#0107): lower urgency first; at equal
/// urgency non-incremental streams in stream order, then incremental ones first come, first
/// served (a stream's next send queues behind the others, so they take turns). Every
/// ``fairShareInterval``th grant goes to the oldest waiter, so lower priorities still move.
/// Sends without a priority count as the default (`u=3`). This only orders sends while the
/// budget is exhausted: QUIC's own packet scheduling belongs to Network.framework.
final class H3SendBudget: Sendable {
    struct Waiter {
        let id: UInt64
        let amount: Int
        let priority: H3StreamPriority?
        let continuation: UnsafeContinuation<Void, any Error>

        var schedulingKey: (UInt8, UInt8, UInt64) {
            priority?.schedulingKey ?? HTTPPriority.default.schedulingKey(streamID: UInt64.max)
        }
    }

    struct State {
        var available: Int
        var waiters: [Waiter] = []
        var nextID: UInt64 = 0
        var highWater = 0
        var priorityGrants = 0

        /// The waiter to serve next (index into ``waiters``).
        func next() -> Int? {
            guard !waiters.isEmpty else { return nil }
            // The oldest waiter's turn by fairness.
            if priorityGrants + 1 >= H3SendBudget.fairShareInterval { return 0 }
            var best = 0
            var bestKey = waiters[0].schedulingKey
            for index in 1..<waiters.count {
                let key = waiters[index].schedulingKey
                if key < bestKey {
                    best = index
                    bestKey = key
                }
            }
            return best
        }

        /// Serves waiter `index`: takes it out and counts the turn.
        mutating func grant(_ index: Int) -> Waiter {
            priorityGrants = index == 0 ? 0 : priorityGrants + 1
            available -= waiters[index].amount
            return waiters.remove(at: index)
        }
    }

    /// One grant in this many goes to the oldest waiter, whatever its priority.
    static let fairShareInterval = 16

    let capacity: Int
    private let state: Mutex<State>

    init(capacity: Int) {
        self.capacity = capacity
        state = Mutex(State(available: capacity))
    }

    /// The most bytes held at once so far.
    var highWater: Int { state.withLock { $0.highWater } }
    /// Bytes held now.
    var inUse: Int { state.withLock { capacity - $0.available } }
    /// Sends waiting for budget now.
    var waiting: Int { state.withLock { $0.waiters.count } }

    /// Takes `min(bytes, capacity)` (returned) once it is available.
    func acquire(_ bytes: Int, priority: H3StreamPriority? = nil) async throws -> Int {
        let amount = Swift.min(bytes, capacity)
        guard amount > 0 else { return 0 }
        let id: UInt64? = state.withLock { state in
            if state.waiters.isEmpty && state.available >= amount {
                state.available -= amount
                state.highWater = Swift.max(state.highWater, capacity - state.available)
                return nil
            }
            defer { state.nextID &+= 1 }
            return state.nextID
        }
        guard let id else { return amount }
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
                let immediate: (any Error)?? = state.withLock { state in
                    if Task.isCancelled { return .some(CancellationError()) }
                    if state.waiters.isEmpty && state.available >= amount {
                        state.available -= amount
                        state.highWater = Swift.max(state.highWater, capacity - state.available)
                        return .some(nil)
                    }
                    state.waiters.append(Waiter(id: id, amount: amount, priority: priority, continuation: continuation))
                    return nil
                }
                switch immediate {
                case .some(.some(let error)): continuation.resume(throwing: error)
                case .some(.none): continuation.resume()
                case .none: break
                }
            }
        } onCancel: {
            let removed = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            removed?.continuation.resume(throwing: CancellationError())
            // A waiter at the head that left may unblock the ones behind it.
            if removed != nil { release(0) }
        }
        return amount
    }

    /// Gives back what ``acquire(_:)`` returned.
    func release(_ amount: Int) {
        let ready = state.withLock { state -> [Waiter] in
            state.available += amount
            var ready: [Waiter] = []
            while let index = state.next(), state.waiters[index].amount <= state.available {
                ready.append(state.grant(index))
            }
            if !ready.isEmpty { state.highWater = Swift.max(state.highWater, capacity - state.available) }
            return ready
        }
        for waiter in ready { waiter.continuation.resume() }
    }
}

/// Per-``HTTP3`` connection accounting: the idle-connection limit
/// (``H3AbuseLimits/maxIdleConnections``) and debug counters of what is alive, which tests use
/// to check that cancelled requests leave no task or stream behind (#0104).
public final class H3ConnectionTracker: Sendable {
    struct Idle {
        let since: ContinuousClock.Instant
        let evict: ShutdownSignal
    }

    struct State {
        var nextID: UInt64 = 0
        var idle: [UInt64: Idle] = [:]
        var evicted = 0
        var sendBufferHighWater = 0
    }

    private let state = Mutex(State())
    private let connections = Atomic<Int>(0)
    private let requestStreams = Atomic<Int>(0)
    private let handlers = Atomic<Int>(0)
    private let bodyChannels = Atomic<Int>(0)
    private let dynamicInserts = Atomic<Int>(0)
    private let dynamicSections = Atomic<Int>(0)

    public init() {}

    /// Connections being served.
    public var liveConnections: Int { connections.load(ordering: .relaxed) }
    /// Request stream tasks running (admitted or rejected, until the stream is closed).
    public var liveRequestStreams: Int { requestStreams.load(ordering: .relaxed) }
    /// Handler calls in progress (a `.stream` body writer counts until it returns).
    public var liveHandlers: Int { handlers.load(ordering: .relaxed) }
    /// Request body channels alive (each holds the body queue and its waiters).
    public var liveBodyChannels: Int { bodyChannels.load(ordering: .relaxed) }
    /// QPACK dynamic table entries the peers' encoder streams inserted, over all connections
    /// (#0106).
    public var qpackDynamicInserts: Int { dynamicInserts.load(ordering: .relaxed) }
    /// Request field sections with a non-zero Required Insert Count (that is, referencing the
    /// QPACK dynamic table), over all connections (#0106).
    public var qpackDynamicSections: Int { dynamicSections.load(ordering: .relaxed) }
    /// Connections with no open request stream.
    public var idleConnections: Int { state.withLock { $0.idle.count } }
    /// Connections shut down because there were more than ``H3AbuseLimits/maxIdleConnections``.
    public var evictedConnections: Int { state.withLock { $0.evicted } }
    /// The most response bytes any ended connection held in stalled sends at once
    /// (``H3AbuseLimits/maxConnectionSendBuffer``).
    public var sendBufferHighWater: Int { state.withLock { $0.sendBufferHighWater } }

    // MARK: Runner side

    func connectionStarted() -> UInt64 {
        connections.add(1, ordering: .relaxed)
        return state.withLock { state in
            defer { state.nextID &+= 1 }
            return state.nextID
        }
    }

    func connectionEnded(_ id: UInt64, sendBufferHighWater: Int) {
        state.withLock { state in
            state.idle.removeValue(forKey: id)
            state.sendBufferHighWater = Swift.max(state.sendBufferHighWater, sendBufferHighWater)
        }
        connections.subtract(1, ordering: .relaxed)
    }

    /// The connection has no open request stream. When that makes more than `limit` idle
    /// connections, the longest-idle one (possibly this one) is told to shut down.
    func becameIdle(_ id: UInt64, evict: ShutdownSignal, limit: Int?) {
        let victim = state.withLock { state -> ShutdownSignal? in
            state.idle[id] = Idle(since: .now, evict: evict)
            guard let limit, state.idle.count > limit else { return nil }
            guard let (oldest, entry) = state.idle.min(by: { $0.value.since < $1.value.since }) else { return nil }
            state.idle.removeValue(forKey: oldest)
            state.evicted += 1
            return entry.evict
        }
        victim?.trigger()
    }

    func becameBusy(_ id: UInt64) {
        state.withLock { _ = $0.idle.removeValue(forKey: id) }
    }

    func requestStreamStarted() { requestStreams.add(1, ordering: .relaxed) }
    func qpackInserted(_ count: Int) { dynamicInserts.add(count, ordering: .relaxed) }
    func qpackDynamicSectionDecoded() { dynamicSections.add(1, ordering: .relaxed) }
    func requestStreamEnded() { requestStreams.subtract(1, ordering: .relaxed) }
    func handlerStarted() { handlers.add(1, ordering: .relaxed) }
    func handlerEnded() { handlers.subtract(1, ordering: .relaxed) }
    func bodyChannelCreated() { bodyChannels.add(1, ordering: .relaxed) }
    func bodyChannelReleased() { bodyChannels.subtract(1, ordering: .relaxed) }
}
