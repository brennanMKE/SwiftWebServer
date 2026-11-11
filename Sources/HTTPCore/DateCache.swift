#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A source of wall-clock time in whole seconds since the Unix epoch.
///
/// ``DateCache`` is generic over its clock so tests can inject time; the server uses
/// ``SystemWallClock``. Generic rather than a closure so the call is statically dispatched.
///
/// A clock may also offer a cheap monotonic ``ticks()`` reading and say, with each
/// ``read()``, the tick before which the second cannot change. ``DateCache`` then skips the
/// wall-clock read until that tick. The defaults (`ticks()` is 0, `read()` says nothing is
/// stable) make the cache read the wall clock every time.
public protocol WallClock: Sendable {
    /// Seconds since 1970-01-01T00:00:00Z.
    func secondsSinceEpoch() -> Int64

    /// The current second and the ``ticks()`` value before which it stays current.
    func read() -> (seconds: Int64, stableUntilTick: UInt64)

    /// A monotonic reading that is cheaper than ``secondsSinceEpoch()``.
    func ticks() -> UInt64
}

extension WallClock {
    @inlinable
    public func read() -> (seconds: Int64, stableUntilTick: UInt64) {
        (secondsSinceEpoch(), 0)
    }

    @inlinable
    public func ticks() -> UInt64 { 0 }
}

/// The system real-time clock (`clock_gettime(CLOCK_REALTIME)`), with no Foundation.
///
/// ``ticks()`` is `mach_continuous_time()`, which keeps counting through sleep, so the end of
/// the current second is known in ticks and the hot path reads the wall clock (about 13 ns)
/// only once per second, paying about 4 ns per response for the tick read instead. A wall
/// clock stepped by NTP or by hand is noticed at the next second boundary.
public struct SystemWallClock: WallClock {
    /// `mach_timebase_info`: nanoseconds = ticks * numerator / denominator.
    @usableFromInline let numerator: UInt64
    @usableFromInline let denominator: UInt64

    public init() {
        #if canImport(Darwin)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numerator = UInt64(Swift.max(info.numer, 1))
        denominator = UInt64(Swift.max(info.denom, 1))
        #else
        numerator = 1
        denominator = 1
        #endif
    }

    // Not inlinable: Darwin is an internal import of `HTTPCore`.

    public func secondsSinceEpoch() -> Int64 {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        return Int64(now.tv_sec)
    }

    public func read() -> (seconds: Int64, stableUntilTick: UInt64) {
        #if canImport(Darwin)
        // Ticks first: the deadline is computed from a later wall-clock reading, so it can only
        // be early (a spare re-read), never late (a stale second).
        let start = mach_continuous_time()
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        let remainingNanoseconds = UInt64(1_000_000_000 - Int(now.tv_nsec))
        return (Int64(now.tv_sec), start &+ remainingNanoseconds * denominator / numerator)
        #else
        return (secondsSinceEpoch(), 0)
        #endif
    }

    public func ticks() -> UInt64 {
        #if canImport(Darwin)
        mach_continuous_time()
        #else
        0
        #endif
    }
}

/// The `Date` field value (RFC 9110 §5.6.7 IMF-fixdate, `Sun, 06 Nov 1994 08:49:37 GMT`),
/// rendered at most once per second (docs/ROADMAP.md §7, "`Date` rendered once per second").
///
/// ## Concurrency: one cache per connection
///
/// `DateCache` is a value type that each connection owns (inside its serializer), not a shared
/// global. Reading it needs no lock and no atomic, and no cache line bounces between the cores
/// running different connections (docs/ROADMAP.md §7, "shard, don't share"). The cost of
/// sharding is that every active connection renders the date itself once per second, which is
/// about 20 ns of integer arithmetic. A shared `Mutex`- or atomic-generation cache would save
/// that render but add a contended load (or lock) to every response on every core, which costs
/// more than it saves.
///
/// Each ``refresh()`` compares a monotonic tick reading with the end of the cached second
/// (``WallClock``); only after that does it read the wall clock (`clock_gettime`), and only a
/// new second re-renders.
///
/// Rendering is ``IMFFixdate``.
public struct DateCache<Clock: WallClock>: Sendable {
    public let clock: Clock

    /// The second the cached bytes represent (after clamping).
    @inlinable public var renderedSecond: Int64 { _renderedSecond }
    @usableFromInline var _renderedSecond: Int64

    /// The 29 date bytes. Allocated once per cache and overwritten in place each second.
    @usableFromInline var line: ByteBuffer

    /// The clock's tick before which the cached second is still current.
    @usableFromInline var stableUntilTick: UInt64

    /// Creates a cache rendered for the clock's current second.
    @inlinable
    public init(clock: Clock) {
        self.clock = clock
        line = ByteBuffer(capacity: IMFFixdate.length)
        _renderedSecond = 0
        let reading = clock.read()
        stableUntilTick = reading.stableUntilTick
        rerender(IMFFixdate.clamp(reading.seconds))
    }

    /// Re-renders if the clock has moved to another second. Returns whether it re-rendered.
    @inlinable
    @discardableResult
    public mutating func refresh() -> Bool {
        if clock.ticks() < stableUntilTick { return false }
        let reading = clock.read()
        stableUntilTick = reading.stableUntilTick
        let now = IMFFixdate.clamp(reading.seconds)
        guard now != _renderedSecond else { return false }
        rerender(now)
        return true
    }

    @usableFromInline
    mutating func rerender(_ clamped: Int64) {
        line.clear()
        line.withWriter(reservingCapacity: IMFFixdate.length) { IMFFixdate.write(clamped, to: &$0) }
        _renderedSecond = clamped
    }

    /// Refreshes, then appends the 29 date bytes to `buffer`.
    @inlinable
    public mutating func append(to buffer: inout ByteBuffer) {
        refresh()
        buffer.append(line)
    }

    /// Refreshes, then appends the 29 date bytes through `writer`.
    @inlinable
    public mutating func append(to writer: inout ByteBuffer.Writer) {
        refresh()
        writer.append(line)
    }

    /// Calls `body` with the cached date bytes (without refreshing).
    @inlinable
    public func withBytes<R>(_ body: (Span<UInt8>) -> R) -> R {
        line.withReadableSpan(body)
    }
}

extension DateCache where Clock == SystemWallClock {
    /// A cache reading the system clock.
    @inlinable
    public init() {
        self.init(clock: SystemWallClock())
    }
}

/// The RFC 9110 §5.6.7 IMF-fixdate, `Sun, 06 Nov 1994 08:49:37 GMT`, for `Date`,
/// `Last-Modified` and `Expires`.
///
/// No `DateFormatter`, no `String`: the civil date comes from integer arithmetic on days since
/// the epoch (Howard Hinnant's `civil_from_days`) and each byte goes to a fixed offset. Times
/// outside the four-digit years IMF-fixdate can express are clamped to
/// `1970-01-01T00:00:00Z ... 9999-12-31T23:59:59Z`.
public enum IMFFixdate {
    /// Length of an IMF-fixdate.
    public static var length: Int { 29 }

    /// Latest representable time: 9999-12-31T23:59:59Z.
    public static var maximumSeconds: Int64 { 253_402_300_799 }

    /// `seconds` clamped to `0...maximumSeconds`.
    @inlinable
    public static func clamp(_ seconds: Int64) -> Int64 {
        Swift.min(Swift.max(seconds, 0), maximumSeconds)
    }

    /// Appends the date for `secondsSinceEpoch` to `buffer`. Uncached.
    @inlinable
    public static func append(secondsSinceEpoch: Int64, to buffer: inout ByteBuffer) {
        buffer.withWriter(reservingCapacity: length) { write(clamp(secondsSinceEpoch), to: &$0) }
    }

    /// Writes the 29 bytes for `seconds`, which must already be clamped:
    ///
    /// ```
    /// Sun, 06 Nov 1994 08:49:37 GMT
    /// 0  3  5  8   12   17 20 23 26
    /// ```
    @inlinable
    public static func write(_ seconds: Int64, to writer: inout ByteBuffer.Writer) {
        precondition(seconds >= 0 && seconds <= maximumSeconds, "IMFFixdate.write needs a clamped time")
        let days = Int(seconds / 86_400)
        let secondOfDay = Int(seconds % 86_400)

        // civil_from_days (http://howardhinnant.github.io/date_algorithms.html). With
        // days >= 0 every division is a truncating one on non-negative values.
        let z = days + 719_468
        let era = z / 146_097
        let dayOfEra = z - era * 146_097                                                // [0, 146096]
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)  // from March 1
        let monthPrime = (5 * dayOfYear + 2) / 153                                       // March = 0
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1                              // [1, 31]
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9                     // [1, 12]
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        // 1970-01-01 was a Thursday; index 0 is Sunday.
        let weekday = (days + 4) % 7

        let dayNames: StaticString = "SunMonTueWedThuFriSat"
        let monthNames: StaticString = "JanFebMarAprMayJunJulAugSepOctNovDec"
        dayNames.withUTF8Buffer { names in
            writer.append(names[weekday * 3])
            writer.append(names[weekday * 3 + 1], names[weekday * 3 + 2])
        }
        writer.append(UInt8(ascii: ","), UInt8(ascii: " "))
        writer.append(twoDigits: day)
        writer.append(UInt8(ascii: " "))
        monthNames.withUTF8Buffer { names in
            let base = (month - 1) * 3
            writer.append(names[base])
            writer.append(names[base + 1], names[base + 2])
        }
        writer.append(UInt8(ascii: " "))
        writer.append(twoDigits: year / 100)
        writer.append(twoDigits: year % 100)
        writer.append(UInt8(ascii: " "))
        writer.append(twoDigits: secondOfDay / 3_600)
        writer.append(UInt8(ascii: ":"))
        writer.append(twoDigits: (secondOfDay / 60) % 60)
        writer.append(UInt8(ascii: ":"))
        writer.append(twoDigits: secondOfDay % 60)
        writer.append(" GMT")
    }
}
