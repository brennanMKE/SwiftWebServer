// Round-robin upstream selection with passive and active health (#0122).
import Synchronization

/// Picks a mount's upstream for each attempt and tracks upstream health. One per mount,
/// shared by every connection; the critical sections are short and never suspend.
final class UpstreamBalancer: Sendable {
    struct Health: Sendable {
        var consecutiveFailures = 0
        /// Passively down until this instant.
        var downUntil: ContinuousClock.Instant?
        /// The last active check failed.
        var activeDown = false
    }

    struct State: Sendable {
        var next = 0
        var health: [Health]
    }

    let count: Int
    let policy: UpstreamHealthPolicy
    private let state: Mutex<State>

    init(count: Int, policy: UpstreamHealthPolicy) {
        self.count = count
        self.policy = policy
        self.state = Mutex(State(health: Array(repeating: Health(), count: count)))
    }

    /// Indices to try for one request, in order: the healthy upstreams in round-robin order
    /// from the next start position. When none is healthy, every upstream in that order (a
    /// down upstream is better than certain failure).
    func order(now: ContinuousClock.Instant = .now) -> [Int] {
        guard count > 1 else { return count == 1 ? [0] : [] }
        return state.withLock { state in
            let start = state.next % count
            state.next = (start + 1) % count
            var healthy: [Int] = []
            healthy.reserveCapacity(count)
            for offset in 0..<count {
                let index = (start + offset) % count
                if Self.isUp(state.health[index], now: now) { healthy.append(index) }
            }
            if !healthy.isEmpty { return healthy }
            return (0..<count).map { (start + $0) % count }
        }
    }

    /// The upstream the next request would start with, without advancing the rotation (for
    /// upgrade checks that usually do not send anything).
    func peek(now: ContinuousClock.Instant = .now) -> Int? {
        guard count > 1 else { return count == 1 ? 0 : nil }
        return state.withLock { state in
            let start = state.next % count
            for offset in 0..<count where Self.isUp(state.health[(start + offset) % count], now: now) {
                return (start + offset) % count
            }
            return start
        }
    }

    func isUp(_ index: Int, now: ContinuousClock.Instant = .now) -> Bool {
        state.withLock { Self.isUp($0.health[index], now: now) }
    }

    private static func isUp(_ health: Health, now: ContinuousClock.Instant) -> Bool {
        if health.activeDown { return false }
        if let until = health.downUntil, now < until { return false }
        return true
    }

    func recordSuccess(_ index: Int) {
        state.withLock { state in
            state.health[index].consecutiveFailures = 0
            state.health[index].downUntil = nil
        }
    }

    /// Counts a failure; the `maxFailures`th in a row marks the upstream down for `cooldown`.
    /// After the cool-down one request probes it again, and one more failure re-arms the
    /// cool-down.
    func recordFailure(_ index: Int, now: ContinuousClock.Instant = .now) {
        guard policy.maxFailures > 0 else { return }
        let cooldown = policy.cooldown
        let maxFailures = policy.maxFailures
        state.withLock { state in
            state.health[index].consecutiveFailures += 1
            if state.health[index].consecutiveFailures >= maxFailures {
                state.health[index].downUntil = now + cooldown
            }
        }
    }

    /// The result of an active health check.
    func recordCheck(_ index: Int, healthy: Bool) {
        state.withLock { state in
            state.health[index].activeDown = !healthy
            if healthy {
                state.health[index].consecutiveFailures = 0
                state.health[index].downUntil = nil
            }
        }
    }
}
