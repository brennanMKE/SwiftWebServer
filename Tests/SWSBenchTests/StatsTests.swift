@testable import SWSBench
import Testing

@Suite struct StatsTests {
    @Test func percentileOfSingleSampleIsThatSample() {
        #expect(Stats.percentile(sorted: [42], 0) == 42)
        #expect(Stats.percentile(sorted: [42], 50) == 42)
        #expect(Stats.percentile(sorted: [42], 99) == 42)
    }

    @Test func percentileInterpolatesBetweenRanks() {
        let sorted: [Double] = [10, 20, 30, 40]
        #expect(Stats.percentile(sorted: sorted, 0) == 10)
        #expect(Stats.percentile(sorted: sorted, 100) == 40)
        #expect(Stats.percentile(sorted: sorted, 50) == 25) // even count: mean of middle two
        #expect(abs(Stats.percentile(sorted: sorted, 90) - 37) < 1e-9) // rank 2.7
    }

    @Test func percentileClampsOutOfRange() {
        #expect(Stats.percentile(sorted: [1, 2, 3], -5) == 1)
        #expect(Stats.percentile(sorted: [1, 2, 3], 250) == 3)
    }

    @Test func percentilesOfOneToHundredMatchNumPy() {
        let sorted = (1...100).map(Double.init)
        // numpy.percentile(range(1, 101), [50, 90, 99]) == [50.5, 90.1, 99.01]
        #expect(abs(Stats.percentile(sorted: sorted, 50) - 50.5) < 1e-9)
        #expect(abs(Stats.percentile(sorted: sorted, 90) - 90.1) < 1e-9)
        #expect(abs(Stats.percentile(sorted: sorted, 99) - 99.01) < 1e-9)
    }

    @Test func summarySortsAndComputesAllFields() throws {
        let summary = try #require(Summary([5, 1, 4, 2, 3]))
        #expect(summary.count == 5)
        #expect(summary.min == 1)
        #expect(summary.max == 5)
        #expect(summary.mean == 3)
        #expect(summary.median == 3)
        #expect(abs(summary.p90 - 4.6) < 1e-9)
        #expect(abs(summary.p99 - 4.96) < 1e-9)
    }

    @Test func summaryOfNothingIsNil() {
        #expect(Summary([]) == nil)
    }

    @Test func durationConvertsToNanoseconds() {
        #expect(Stats.nanoseconds(.seconds(2)) == 2e9)
        #expect(Stats.nanoseconds(.nanoseconds(1500)) == 1500)
        #expect(Stats.nanoseconds(.milliseconds(3) + .nanoseconds(7)) == 3_000_007)
    }

    @Test func percentChangeAgainstBaseline() {
        #expect(Stats.percentChange(baseline: 100, current: 111) == 11)
        #expect(Stats.percentChange(baseline: 200, current: 150) == -25)
        #expect(Stats.percentChange(baseline: 0, current: 5) == 0)
    }
}

@Suite struct ArgumentsTests {
    @Test func parsesValuesFlagsAndNegations() throws {
        var args = try Arguments(["--url", "http://x", "--duration=5s", "--no-keepalive", "--json"],
                                 valueOptions: ["url", "duration"])
        #expect(args.string("url") == "http://x")
        #expect(try args.seconds("duration") == 5)
        #expect(args.flag("keepalive") == false)
        #expect(args.flag("json") == true)
        try args.checkAllConsumed()
    }

    @Test func millisecondsSuffix() throws {
        var args = try Arguments(["--duration", "250ms"], valueOptions: ["duration"])
        #expect(try args.seconds("duration") == 0.25)
    }

    @Test func missingValueAndUnknownOptionsThrow() throws {
        #expect(throws: Arguments.Failure.missingValue("url")) {
            _ = try Arguments(["--url"], valueOptions: ["url"])
        }
        let args = try Arguments(["--bogus"], valueOptions: [])
        #expect(throws: Arguments.Failure.unknown("--bogus")) { try args.checkAllConsumed() }
    }

    @Test func invalidIntegerThrows() throws {
        var args = try Arguments(["--connections", "many"], valueOptions: ["connections"])
        #expect(throws: Arguments.Failure.invalidValue("connections", "many")) { _ = try args.int("connections") }
    }
}

@Suite struct MicroRunnerTests {
    @Test func reportsSamplesBatchAndAllocations() {
        final class Box {}
        let benchmark = Benchmark(name: "test.allocate", body: { blackHole(Box()) })
        var options = MicroOptions()
        options.warmup = 10
        options.iterations = 5
        options.batch = 7
        let result = MicroRunner.run(benchmark, options: options)
        #expect(result.samples == 5)
        #expect(result.batch == 7)
        #expect(result.minNanoseconds <= result.medianNanoseconds)
        #expect(result.medianNanoseconds <= result.p99Nanoseconds)
        if AllocationCounter.isAvailable, let allocations = result.allocationsPerOp {
            #expect(allocations >= 1)
        }
    }
}
