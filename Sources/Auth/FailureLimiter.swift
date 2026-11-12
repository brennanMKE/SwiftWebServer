#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Synchronization

/// Wall-clock seconds for token expiry and failure windows; injectable for tests.
public struct AuthClock: Sendable {
    let read: @Sendable () -> Int64

    public init(_ read: @escaping @Sendable () -> Int64) {
        self.read = read
    }

    /// Seconds since 1970 from `time()`.
    public static let system = AuthClock { Int64(time(nil)) }

    /// The current time in seconds since 1970.
    @inline(__always)
    public func now() -> Int64 { read() }
}

/// Limits failed authentication attempts per peer (#0093).
///
/// A fixed table of ``capacity`` buckets (rounded up to a power of two), indexed by a hash of
/// the peer's address: each counts failures in a window of ``window`` seconds. A peer with
/// ``maximumFailures`` failures in its window is refused (`429` with `Retry-After`) until the
/// window ends, before any password is hashed. The table never grows: peers whose addresses
/// hash to the same bucket share its count (a collision can only make limiting stricter), and
/// a bucket whose window has ended starts over.
public final class FailureLimiter: Sendable {
    struct Bucket {
        var peer: UInt64 = 0
        var failures: UInt32 = 0
        var windowStart: Int64 = 0
    }

    /// Failures allowed per window.
    public let maximumFailures: Int
    /// Window length, seconds.
    public let window: Int64
    /// Number of buckets.
    public let capacity: Int
    let buckets: Mutex<[Bucket]>

    public init(maximumFailures: Int = 10, window: Int64 = 60, capacity: Int = 4096) {
        precondition(maximumFailures > 0 && window > 0 && capacity > 0)
        var size = 1
        while size < capacity { size <<= 1 }
        self.maximumFailures = maximumFailures
        self.window = window
        self.capacity = size
        buckets = Mutex(Array(repeating: Bucket(), count: size))
    }

    /// A 64-bit FNV-1a of the peer's address text (port excluded), never 0.
    static func key(_ peer: String?) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in (peer ?? "").utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return hash | 1
    }

    /// Seconds until `peer` may try again, or 0 when it is not blocked.
    public func retryAfter(peer: String?, now: Int64) -> Int64 {
        let key = Self.key(peer)
        let index = Int(truncatingIfNeeded: key) & (capacity - 1)
        let maximum = UInt32(maximumFailures)
        let window = window
        return buckets.withLock { buckets in
            let bucket = buckets[index]
            guard bucket.failures >= maximum else { return 0 }
            let end = bucket.windowStart + window
            return end > now ? end - now : 0
        }
    }

    /// Counts a failure for `peer`.
    public func recordFailure(peer: String?, now: Int64) {
        let key = Self.key(peer)
        let index = Int(truncatingIfNeeded: key) & (capacity - 1)
        let window = window
        buckets.withLock { buckets in
            var bucket = buckets[index]
            if bucket.failures == 0 || now - bucket.windowStart >= window {
                // A fresh window for whoever fails here next.
                bucket = Bucket(peer: key, failures: 1, windowStart: now)
            } else {
                // Same peer, or another peer hashing here: the count is shared, so a collision
                // only makes limiting stricter for both.
                bucket.failures &+= 1
                bucket.peer = key
            }
            buckets[index] = bucket
        }
    }
}
