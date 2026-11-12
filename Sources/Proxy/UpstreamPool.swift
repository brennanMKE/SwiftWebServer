// Connection pool limits and bookkeeping for the upstream client (#0120).
import HTTPCore
import Synchronization

/// How many connections the client keeps and opens per upstream address.
public struct UpstreamPoolPolicy: Sendable, Hashable {
    /// Connections open at once to one upstream, idle ones included. `nil`: no limit.
    public var maxConnections: Int?
    /// Idle keep-alive connections kept per upstream.
    public var maxIdle: Int
    /// Requests that may wait for a connection when `maxConnections` are busy. A request that
    /// finds the queue full gets `503 Service Unavailable` at once.
    public var maxQueue: Int
    /// How long a queued request waits for a connection before it gets `503`.
    public var queueTimeout: Duration
    /// An idle pooled connection older than this is closed instead of reused. `nil`: kept until
    /// the upstream closes it (which the liveness check before reuse notices).
    public var idleTimeout: Duration?

    public init(maxConnections: Int? = nil, maxIdle: Int = 16, maxQueue: Int = 256,
                queueTimeout: Duration = .seconds(10), idleTimeout: Duration? = .seconds(60)) {
        self.maxConnections = maxConnections.map { max(1, $0) }
        self.maxIdle = max(0, maxIdle)
        self.maxQueue = max(0, maxQueue)
        self.queueTimeout = queueTimeout
        self.idleTimeout = idleTimeout
    }
}

/// Per-address pool state. Every connection that is open or being opened holds one of
/// `maxConnections` slots: it is `idle`, checked out, or connecting (`active` counts the last
/// two). A waiter is handed a slot (or an idle connection) when one is released, FIFO.
struct UpstreamPoolState {
    struct Idle {
        let connection: UpstreamConnection
        let since: ContinuousClock.Instant
    }

    enum Grant: Sendable {
        /// A pooled connection, still to be checked for liveness.
        case connection(UpstreamConnection)
        /// Permission to open a new connection.
        case slot
    }

    struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Grant, any Error>
    }

    var idle: [Idle] = []
    /// The idle timeout of the last check-in, for the periodic sweep.
    var idleTimeout: Duration?
    var active = 0
    var waiters: [Waiter] = []

    var open: Int { idle.count + active }
}

/// The pools of one client, keyed by address. All critical sections are short and never
/// suspend; continuations are resumed and connections closed outside the lock.
final class UpstreamPools: Sendable {
    private let state = Mutex<(pools: [UpstreamAddress: UpstreamPoolState], nextWaiter: UInt64)>(([:], 0))

    enum Checkout {
        case grant(UpstreamPoolState.Grant)
        case wait
        case full
    }

    /// Takes the most recently used idle connection, or a slot to open a new one. Idle
    /// connections past `idleTimeout` are moved to `expired` for the caller to close.
    func checkout(_ address: UpstreamAddress, policy: UpstreamPoolPolicy, now: ContinuousClock.Instant,
                  expired: inout [UpstreamConnection]) -> Checkout {
        state.withLock { state in
            Self.checkout(&state.pools[address, default: UpstreamPoolState()], policy: policy, now: now,
                          expired: &expired)
        }
    }

    private static func checkout(_ pool: inout UpstreamPoolState, policy: UpstreamPoolPolicy,
                                 now: ContinuousClock.Instant, expired: inout [UpstreamConnection]) -> Checkout {
        if let last = pool.idle.last {
            // LIFO: when the newest idle connection is too old, so are all the others.
            if let limit = policy.idleTimeout, now - last.since > limit {
                expired.append(contentsOf: pool.idle.lazy.map(\.connection))
                pool.idle.removeAll(keepingCapacity: true)
            } else {
                pool.idle.removeLast()
                pool.active += 1
                return .grant(.connection(last.connection))
            }
        }
        if let max = policy.maxConnections, pool.open >= max {
            return pool.waiters.count < policy.maxQueue ? .wait : .full
        }
        pool.active += 1
        return .grant(.slot)
    }

    /// Waits for a slot or a connection, at most `policy.queueTimeout`. Throws
    /// `UpstreamError.poolExhausted` when the queue is full or the wait times out.
    func wait(_ address: UpstreamAddress, policy: UpstreamPoolPolicy) async throws -> UpstreamPoolState.Grant {
        try await withUpstreamTimeout(policy.queueTimeout, error: .poolExhausted,
                                      discard: { [self] grant in await self.release(grant, address, policy: policy) }) {
            try await self.enqueue(address, policy: policy)
        }
    }

    private func enqueue(_ address: UpstreamAddress, policy: UpstreamPoolPolicy) async throws -> UpstreamPoolState.Grant {
        let id = state.withLock { state -> UInt64 in
            state.nextWaiter &+= 1
            return state.nextWaiter
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UpstreamPoolState.Grant, any Error>) in
                enum Now { case grant(UpstreamPoolState.Grant), full, cancelled, queued }
                // Expired idle connections close when the last reference goes (the transport's
                // deinit closes the socket), after the lock.
                var expired: [UpstreamConnection] = []
                let now = state.withLock { state -> Now in
                    if Task.isCancelled { return .cancelled }
                    let result = Self.checkout(&state.pools[address, default: UpstreamPoolState()], policy: policy,
                                               now: .now, expired: &expired)
                    switch result {
                    case .grant(let grant): return .grant(grant)
                    case .full: return .full
                    case .wait:
                        state.pools[address]!.waiters.append(.init(id: id, continuation: continuation))
                        return .queued
                    }
                }
                switch now {
                case .grant(let grant): continuation.resume(returning: grant)
                case .full: continuation.resume(throwing: UpstreamError.poolExhausted)
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .queued: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> UpstreamPoolState.Waiter? in
                guard let index = state.pools[address]?.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.pools[address]!.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Returns a healthy connection after a complete exchange: to the first waiter, else to the
    /// idle list (when there is room). Returns the connection when the caller must close it.
    func checkin(_ connection: UpstreamConnection, _ address: UpstreamAddress, policy: UpstreamPoolPolicy,
                 now: ContinuousClock.Instant) -> UpstreamConnection? {
        let (waiter, close) = state.withLock { state -> (UpstreamPoolState.Waiter?, Bool) in
            guard var pool = state.pools[address] else { return (nil, true) }
            defer { state.pools[address] = pool }
            if !pool.waiters.isEmpty {
                return (pool.waiters.removeFirst(), false)
            }
            pool.active -= 1
            pool.idleTimeout = policy.idleTimeout
            guard pool.idle.count < policy.maxIdle else { return (nil, true) }
            pool.idle.append(.init(connection: connection, since: now))
            return (nil, false)
        }
        waiter?.continuation.resume(returning: .connection(connection))
        return close ? connection : nil
    }

    /// Gives up the slot of a connection that was closed (or never opened): the first waiter
    /// may open a new one.
    func releaseSlot(_ address: UpstreamAddress) {
        let waiter = state.withLock { state -> UpstreamPoolState.Waiter? in
            guard var pool = state.pools[address] else { return nil }
            defer { state.pools[address] = pool }
            if !pool.waiters.isEmpty { return pool.waiters.removeFirst() }
            pool.active -= 1
            return nil
        }
        waiter?.continuation.resume(returning: .slot)
    }

    /// Hands back a grant nobody used (a wait that lost its race with the timeout).
    func release(_ grant: UpstreamPoolState.Grant, _ address: UpstreamAddress, policy: UpstreamPoolPolicy) async {
        switch grant {
        case .slot:
            releaseSlot(address)
        case .connection(let connection):
            if let close = checkin(connection, address, policy: policy, now: .now) { await close.close() }
        }
    }

    /// Removes the idle connections past their pool's idle timeout or found closed by the
    /// upstream (a non-blocking peek each), or every idle connection with `all`.
    func takeIdle(all: Bool, now: ContinuousClock.Instant) -> [UpstreamConnection] {
        state.withLock { state in
            var out: [UpstreamConnection] = []
            for address in state.pools.keys {
                let limit = state.pools[address]!.idleTimeout
                state.pools[address]!.idle.removeAll { entry in
                    let evict = all || limit.map { now - entry.since > $0 } == true
                        || !entry.connection.transport.isIdleAndOpen
                    if evict { out.append(entry.connection) }
                    return evict
                }
            }
            return out
        }
    }

    /// The most recently pooled idle connection (for tests).
    func idleConnection(_ address: UpstreamAddress) -> UpstreamConnection? {
        state.withLock { $0.pools[address]?.idle.last?.connection }
    }

    func idleCount(_ address: UpstreamAddress) -> Int {
        state.withLock { $0.pools[address]?.idle.count ?? 0 }
    }

    func openCount(_ address: UpstreamAddress) -> Int {
        state.withLock { $0.pools[address]?.open ?? 0 }
    }

    func waiterCount(_ address: UpstreamAddress) -> Int {
        state.withLock { $0.pools[address]?.waiters.count ?? 0 }
    }
}
