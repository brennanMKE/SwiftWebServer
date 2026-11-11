import Darwin
import Synchronization
import Testing
import HTTPCore

/// A clock the test sets by hand.
final class ManualWallClock: WallClock {
    let seconds: Atomic<Int64>

    init(_ seconds: Int64) {
        self.seconds = Atomic(seconds)
    }

    func set(_ value: Int64) {
        seconds.store(value, ordering: .relaxed)
    }

    func secondsSinceEpoch() -> Int64 {
        seconds.load(ordering: .relaxed)
    }
}

private func rendered(_ seconds: Int64) -> String {
    var buffer = ByteBuffer()
    IMFFixdate.append(secondsSinceEpoch: seconds, to: &buffer)
    return buffer.withReadableSpan { ASCII.string(from: $0) }
}

private func cached<C: WallClock>(_ cache: DateCache<C>) -> String {
    cache.withBytes { ASCII.string(from: $0) }
}

/// An independent reference: `gmtime_r` plus fixed tables.
private func reference(_ seconds: Int64) -> String {
    var time = time_t(seconds)
    var parts = tm()
    gmtime_r(&time, &parts)
    let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    func two(_ n: Int32) -> String { n < 10 ? "0\(n)" : "\(n)" }
    let year = String(parts.tm_year + 1900)
    let paddedYear = String(repeating: "0", count: max(0, 4 - year.count)) + year
    return "\(days[Int(parts.tm_wday)]), \(two(parts.tm_mday)) \(months[Int(parts.tm_mon)]) \(paddedYear) "
        + "\(two(parts.tm_hour)):\(two(parts.tm_min)):\(two(parts.tm_sec)) GMT"
}

@Suite struct DateCacheTests {
    @Test(arguments: [
        (Int64(0), "Thu, 01 Jan 1970 00:00:00 GMT"),
        (784_111_777, "Sun, 06 Nov 1994 08:49:37 GMT"),            // RFC 9110 §5.6.7 example
        (951_782_400, "Tue, 29 Feb 2000 00:00:00 GMT"),            // leap year divisible by 400
        (951_868_800, "Wed, 01 Mar 2000 00:00:00 GMT"),
        (1_709_164_800, "Thu, 29 Feb 2024 00:00:00 GMT"),          // ordinary leap year
        (1_709_251_199, "Thu, 29 Feb 2024 23:59:59 GMT"),
        (2_147_483_647, "Tue, 19 Jan 2038 03:14:07 GMT"),          // Int32 time_t limit
        (2_147_483_648, "Tue, 19 Jan 2038 03:14:08 GMT"),          // one second past it
        (4_102_444_800, "Fri, 01 Jan 2100 00:00:00 GMT"),
        (4_107_542_399, "Sun, 28 Feb 2100 23:59:59 GMT"),          // 2100 is not a leap year
        (4_107_542_400, "Mon, 01 Mar 2100 00:00:00 GMT"),
        (32_503_680_000, "Wed, 01 Jan 3000 00:00:00 GMT"),
        (253_402_300_799, "Fri, 31 Dec 9999 23:59:59 GMT"),        // last four-digit year
    ])
    func knownTimestamps(seconds: Int64, expected: String) {
        #expect(rendered(seconds) == expected)
        #expect(cached(DateCache(clock: ManualWallClock(seconds))) == expected)
    }

    @Test func outOfRangeTimesAreClamped() {
        #expect(rendered(-1) == "Thu, 01 Jan 1970 00:00:00 GMT")
        #expect(rendered(.min) == "Thu, 01 Jan 1970 00:00:00 GMT")
        #expect(rendered(253_402_300_800) == "Fri, 31 Dec 9999 23:59:59 GMT")
        #expect(rendered(.max) == "Fri, 31 Dec 9999 23:59:59 GMT")
    }

    /// Every day from 1970 to 2400 at a varying time of day, against `gmtime_r`.
    @Test func matchesGmtimeAcrossFourCenturies() {
        var seconds: Int64 = 0
        var step: Int64 = 0
        var checked = 0
        while seconds < 13_569_465_600 {   // 2400-01-01
            let expected = reference(seconds)
            let actual = rendered(seconds)
            if actual != expected {
                Issue.record("\(seconds): \(actual) != \(expected)")
                return
            }
            checked += 1
            step = (step &* 6_364_136_223_846_793_005 &+ 1) & 0xFFFF
            seconds += 86_400 + step % 86_400 - 43_200 + 1
        }
        #expect(checked > 150_000)
    }

    @Test func renderedBytesAre29Long() {
        let cache = DateCache(clock: ManualWallClock(784_111_777))
        #expect(cache.withBytes { $0.count } == IMFFixdate.length)
        var buffer = ByteBuffer()
        IMFFixdate.append(secondsSinceEpoch: 0, to: &buffer)
        #expect(buffer.readableBytes == 29)
    }

    @Test func refreshesOnlyWhenTheSecondChanges() {
        let clock = ManualWallClock(1_709_251_199)
        var cache = DateCache(clock: clock)
        #expect(cache.renderedSecond == 1_709_251_199)
        #expect(cache.refresh() == false)
        #expect(cached(cache) == "Thu, 29 Feb 2024 23:59:59 GMT")

        clock.set(1_709_251_200)   // across a second, day and month boundary
        var buffer = ByteBuffer()
        cache.append(to: &buffer)
        #expect(buffer.withReadableSpan { ASCII.string(from: $0) } == "Fri, 01 Mar 2024 00:00:00 GMT")
        #expect(cache.renderedSecond == 1_709_251_200)
        #expect(cache.refresh() == false)

        clock.set(1_709_251_199)   // a clock stepped backwards re-renders too
        #expect(cache.refresh() == true)
        #expect(cached(cache) == "Thu, 29 Feb 2024 23:59:59 GMT")
    }

    @Test func systemClockIsCloseToTime() {
        let now = Int64(time(nil))
        let clock = SystemWallClock().secondsSinceEpoch()
        #expect(abs(clock - now) <= 1)
        let cache = DateCache()
        #expect(abs(cache.renderedSecond - now) <= 1)
        #expect(cached(cache).hasSuffix(" GMT"))
    }

    @Test func systemClockKnowsWhenTheSecondEnds() {
        let clock = SystemWallClock()
        let reading = clock.read()
        let ticks = clock.ticks()
        #expect(abs(reading.seconds - Int64(time(nil))) <= 1)
        // The deadline is at most one second of ticks ahead (24 MHz timebase on Apple silicon,
        // 1 GHz on Intel; allow either).
        #expect(reading.stableUntilTick <= ticks || reading.stableUntilTick - ticks <= 1_000_000_000)

        var cache = DateCache(clock: clock)
        // Within the same second, refreshing is a tick compare.
        for _ in 0..<1_000 { _ = cache.refresh() }
        #expect(abs(cache.renderedSecond - Int64(time(nil))) <= 1)
    }
}
