#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Per-request information handed down the middleware chain with every request (#0083).
///
/// | Member | What it is | Cost per request |
/// |---|---|---|
/// | ``connection`` | Addresses, TLS and ALPN of the connection carrying the request | A copy of the connection's value (no allocation) |
/// | ``startTime`` | When the request reached the handler chain (its head was complete), if a registered component asked for it | Nothing unless asked for; then one monotonic clock read (about 10 ns in `sws-bench h1conn`) |
/// | `self[Key.self]` | Typed values that components attach for the components after them (an authenticated principal, a matched virtual host, a route's parameters) | Nothing until a component sets one; then one small allocation per value set |
///
/// The context is a value: a middleware that wants to tell the rest of the chain something
/// copies it, sets a value and passes the copy to `next`. The components before it never see
/// the change, and nothing is shared between requests.
///
/// ```swift
/// enum Principal: RequestContextKey { static var defaultValue: String? { nil } }
///
/// struct Authenticate: HTTPMiddleware {
///     func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
///                                    next: Next) async throws -> HTTPResponse {
///         var context = context
///         context[Principal.self] = "alice"
///         return try await next.handle(request, context: context)
///     }
/// }
/// ```
public struct RequestContext: Sendable {
    /// Addresses and security properties of the connection carrying the request.
    public var connection: ConnectionInfo
    /// When the request reached the handler chain; read ``MonotonicInstant/elapsed`` for the
    /// time spent so far (an access log's duration).
    ///
    /// `nil` unless the chain contains a ``RequestStartTimeConsumer`` (or the protocol runner
    /// was otherwise told to record it, ``ConnectionContext/recordsRequestStartTime``): the
    /// clock read is a measurable part of a small request, so it is paid only when used.
    public var startTime: MonotonicInstant?
    /// Values set by components, newest first; `nil` until the first one is set.
    @usableFromInline
    var values: RequestContextValue?

    @inlinable
    public init(connection: ConnectionInfo = ConnectionInfo(), startTime: MonotonicInstant? = nil) {
        self.connection = connection
        self.startTime = startTime
        self.values = nil
    }

    /// The value a component set for `key`, or `key.defaultValue`.
    ///
    /// Reading walks the values set on this request (usually none or one); setting adds one
    /// node in front, so copies made before the set keep their own view. Each set allocates
    /// one small node; a request on which no component sets a value allocates nothing.
    @inlinable
    public subscript<Key: RequestContextKey>(key: Key.Type) -> Key.Value {
        get {
            let id = ObjectIdentifier(key)
            var node = values
            while let current = node {
                if current.key == id {
                    // The key's identity fixes the node's value type.
                    return unsafeDowncast(current, to: RequestContextTypedValue<Key.Value>.self).value
                }
                node = current.next
            }
            return Key.defaultValue
        }
        set {
            values = RequestContextTypedValue(key: ObjectIdentifier(key), value: newValue, next: values)
        }
    }

    /// True when a component set a value for `key` on this request.
    @inlinable
    public func contains<Key: RequestContextKey>(_ key: Key.Type) -> Bool {
        let id = ObjectIdentifier(key)
        var node = values
        while let current = node {
            if current.key == id { return true }
            node = current.next
        }
        return false
    }
}

/// Marks a middleware or handler that reads ``RequestContext/startTime`` (an access log). When
/// the server finds one in the chain, the protocol runners stamp every request; otherwise
/// they skip the clock read and ``RequestContext/startTime`` is `nil`.
public protocol RequestStartTimeConsumer {}

/// A key for a typed value in ``RequestContext`` (like SwiftUI's `EnvironmentKey`). The key
/// type's identity is the key, so two components cannot collide unless they share the type.
public protocol RequestContextKey {
    associatedtype Value: Sendable
    /// The value read when no component set one.
    static var defaultValue: Value { get }
}

/// A node of the values list: immutable, so copies of a context share nodes safely.
@usableFromInline
class RequestContextValue: @unchecked Sendable {
    @usableFromInline let key: ObjectIdentifier
    @usableFromInline let next: RequestContextValue?

    @usableFromInline
    init(key: ObjectIdentifier, next: RequestContextValue?) {
        self.key = key
        self.next = next
    }
}

@usableFromInline
final class RequestContextTypedValue<Value: Sendable>: RequestContextValue, @unchecked Sendable {
    @usableFromInline let value: Value

    @usableFromInline
    init(key: ObjectIdentifier, value: Value, next: RequestContextValue?) {
        self.value = value
        super.init(key: key, next: next)
    }
}

// MARK: - MonotonicInstant

/// A point on a cheap monotonic clock: `mach_continuous_time` ticks on Darwin (one commpage
/// read, a few ns, and it keeps counting through sleep like `ContinuousClock`), nanoseconds
/// elsewhere. Converted to a `Duration` only when someone asks, so stamping every request
/// costs one clock read.
public struct MonotonicInstant: Sendable, Hashable, Comparable {
    /// Raw clock ticks. Compare instants or use ``duration(to:)``; the unit is per platform.
    public let ticks: UInt64

    @inlinable
    public init(ticks: UInt64) {
        self.ticks = ticks
    }

    /// The current instant.
    public static func now() -> MonotonicInstant {
        #if canImport(Darwin)
        MonotonicInstant(ticks: mach_continuous_time())
        #else
        var spec = timespec()
        clock_gettime(CLOCK_MONOTONIC, &spec)
        return MonotonicInstant(ticks: UInt64(spec.tv_sec) &* 1_000_000_000 &+ UInt64(spec.tv_nsec))
        #endif
    }

    /// The time from this instant to `other` (negative when `other` is earlier).
    public func duration(to other: MonotonicInstant) -> Duration {
        let forward = other.ticks >= ticks
        let delta = forward ? other.ticks - ticks : ticks - other.ticks
        let nanoseconds = Int64(Double(delta) * Self.nanosecondsPerTick)
        return .nanoseconds(forward ? nanoseconds : -nanoseconds)
    }

    /// The time since this instant.
    public var elapsed: Duration { duration(to: .now()) }

    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.ticks < rhs.ticks
    }

    static let nanosecondsPerTick: Double = {
        #if canImport(Darwin)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(max(info.numer, 1)) / Double(max(info.denom, 1))
        #else
        return 1
        #endif
    }()
}
