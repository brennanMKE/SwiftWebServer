// Upstream timeouts, retry and health policy (#0122).
import HTTPCore

/// Limits on one upstream exchange. `nil` turns a limit off.
public struct UpstreamTimeouts: Sendable, Hashable {
    /// Establishing the TCP or Unix-socket connection.
    public var connect: Duration?
    /// From the end of the request to the complete response head.
    public var response: Duration?
    /// Between two reads of the response body.
    public var idle: Duration?
    /// The whole exchange, connect through the last body byte (checked at each upstream wait).
    public var total: Duration?

    public init(connect: Duration? = .seconds(10), response: Duration? = .seconds(60),
                idle: Duration? = .seconds(60), total: Duration? = nil) {
        self.connect = connect
        self.response = response
        self.idle = idle
        self.total = total
    }

    /// The tighter of `phase` and what is left until `deadline`. Throws `timeout` when the
    /// deadline has passed.
    static func limit(_ phase: Duration?, deadline: ContinuousClock.Instant?,
                      error: UpstreamError = .timeout) throws(UpstreamError) -> Duration? {
        guard let deadline else { return phase }
        let left = deadline - ContinuousClock.now
        guard left > .zero else { throw error }
        guard let phase else { return left }
        return min(phase, left)
    }
}

/// Passive and active health tracking for a mount's upstreams.
public struct UpstreamHealthPolicy: Sendable, Hashable {
    /// Consecutive failures that mark an upstream down. `0` turns passive tracking off.
    public var maxFailures: Int
    /// How long an upstream stays down before it is tried again.
    public var cooldown: Duration
    /// Active check: `GET` this path on every upstream each `checkInterval`; `nil` for none.
    /// A status below 500 marks the upstream up, anything else (or no answer) down.
    public var checkPath: String?
    public var checkInterval: Duration

    public init(maxFailures: Int = 3, cooldown: Duration = .seconds(10),
                checkPath: String? = nil, checkInterval: Duration = .seconds(10)) {
        self.maxFailures = maxFailures
        self.cooldown = cooldown
        self.checkPath = checkPath
        self.checkInterval = checkInterval
    }
}

/// How a mount talks to its upstreams.
public struct UpstreamPolicy: Sendable, Hashable {
    public var timeouts: UpstreamTimeouts
    /// Extra attempts after a connect failure (or a stale pooled connection), for idempotent
    /// methods only. Each attempt goes to the next upstream in round-robin order.
    public var retries: Int
    public var health: UpstreamHealthPolicy
    /// Overrides ``ProxyTunnelConfiguration/idleTimeout`` for this mount's upgraded
    /// connections; `nil` keeps the proxy-wide value and `.zero` turns the tunnel's idle limit
    /// off. Config sets it from an explicit `timeouts.idle` (`0` or `null` there gives `.zero`).
    public var tunnelIdleTimeout: Duration?
    /// Connection limits, the wait queue and idle eviction (#0120).
    public var pool: UpstreamPoolPolicy

    public init(timeouts: UpstreamTimeouts = UpstreamTimeouts(), retries: Int = 1,
                health: UpstreamHealthPolicy = UpstreamHealthPolicy(), tunnelIdleTimeout: Duration? = nil,
                pool: UpstreamPoolPolicy = UpstreamPoolPolicy()) {
        self.timeouts = timeouts
        self.retries = max(0, retries)
        self.health = health
        self.tunnelIdleTimeout = tunnelIdleTimeout
        self.pool = pool
    }
}

/// Per-request options for ``UpstreamClient/send(_:body:to:options:)``.
public struct UpstreamSendOptions: Sendable {
    public var timeouts: UpstreamTimeouts
    /// Absolute end of the exchange (from ``UpstreamTimeouts/total``), shared across retries.
    public var deadline: ContinuousClock.Instant?
    /// Whether the client may resend the request on a fresh connection when a pooled one turns
    /// out to be closed before any response byte. Only ever true for idempotent methods.
    public var retriesStaleConnection: Bool
    /// Connection limits and idle eviction for the target's pool (#0120).
    public var pool: UpstreamPoolPolicy

    public init(timeouts: UpstreamTimeouts = UpstreamTimeouts(), deadline: ContinuousClock.Instant? = nil,
                retriesStaleConnection: Bool = true, pool: UpstreamPoolPolicy = UpstreamPoolPolicy()) {
        self.timeouts = timeouts
        self.deadline = deadline
        self.retriesStaleConnection = retriesStaleConnection
        self.pool = pool
    }
}

extension HTTPMethod {
    /// RFC 9110 §9.2.2: methods whose repetition has the same effect as one request.
    var isIdempotent: Bool {
        switch self {
        case .get, .head, .options, .trace, .put, .delete: true
        default: false
        }
    }
}

extension UpstreamError {
    /// A timeout before the response head: `504`. Everything else is `502`.
    var isTimeout: Bool { self == .timeout || self == .connectTimeout }
    /// Nothing reached the upstream, so the request can be sent again elsewhere.
    var isConnectFailure: Bool {
        switch self {
        case .connectFailed, .connectTimeout, .poolExhausted: true
        default: false
        }
    }
}

private enum RaceOutcome<T: Sendable>: Sendable {
    case value(T)
    case timedOut
}

/// Runs `operation`, cancelling it and throwing `error` when `limit` passes first. The
/// operation must stop promptly when cancelled (transport waits do). With `discard`, a value
/// the operation produced after losing the race is handed to it (to close a connection).
func withUpstreamTimeout<T: Sendable>(
    _ limit: Duration?, error: UpstreamError = .timeout,
    discard: (@Sendable (T) async -> Void)? = nil,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard let limit else { return try await operation() }
    if limit <= .zero { throw error }
    return try await withThrowingTaskGroup(of: RaceOutcome<T>.self) { group in
        group.addTask { .value(try await operation()) }
        group.addTask {
            try await Task.sleep(for: limit)
            return .timedOut
        }
        let first: RaceOutcome<T>
        do {
            first = try await group.next()!
        } catch {
            group.cancelAll()
            throw error
        }
        group.cancelAll()
        switch first {
        case .value(let value):
            return value
        case .timedOut:
            // Wait for the operation to stop; close anything it produced regardless.
            while let late = try? await group.next() {
                if case .value(let value) = late { await discard?(value) }
            }
            throw error
        }
    }
}
