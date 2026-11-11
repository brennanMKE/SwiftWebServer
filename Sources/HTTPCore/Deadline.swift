/// A point in time after which an operation should give up (header-read, idle and body
/// timeouts; docs/ROADMAP.md §5.4). Based on `ContinuousClock`, so it keeps counting while the
/// machine sleeps.
public struct Deadline: Sendable, Hashable, Comparable {
    /// The instant, or `nil` for a deadline that never expires.
    public let instant: ContinuousClock.Instant?

    public init(_ instant: ContinuousClock.Instant) {
        self.instant = instant
    }

    private init(never: Void) {
        instant = nil
    }

    /// A deadline that never expires.
    public static let never = Deadline(never: ())

    /// The deadline `duration` after `now`.
    public static func after(_ duration: Duration, now: ContinuousClock.Instant = .now) -> Deadline {
        Deadline(now.advanced(by: duration))
    }

    /// True when the deadline is at or before `now`.
    public func hasExpired(now: ContinuousClock.Instant = .now) -> Bool {
        guard let instant else { return false }
        return instant <= now
    }

    /// Time left before the deadline (zero once expired), or `nil` for ``never``.
    public func remaining(now: ContinuousClock.Instant = .now) -> Duration? {
        guard let instant else { return nil }
        return instant > now ? now.duration(to: instant) : .zero
    }

    /// The earlier of two deadlines.
    public func earliest(_ other: Deadline) -> Deadline {
        Swift.min(self, other)
    }

    /// `never` sorts after every finite deadline.
    public static func < (lhs: Deadline, rhs: Deadline) -> Bool {
        switch (lhs.instant, rhs.instant) {
        case let (l?, r?): l < r
        case (_?, nil): true
        default: false
        }
    }
}
