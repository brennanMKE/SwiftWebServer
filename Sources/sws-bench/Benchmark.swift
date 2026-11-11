/// A registered microbenchmark: a closure that performs one operation.
///
/// Register from a `register...Benchmarks()` function listed in
/// `BenchmarkRegistry.swift`:
///
/// ```swift
/// func registerByteBufferBenchmarks() {
///     var buffer = ByteBuffer(capacity: 4096)          // setup, not measured
///     Benchmark.register(name: "ByteBuffer.writeBytes") {
///         buffer.clear()
///         buffer.write(bytes)
///         blackHole(buffer.readableBytes)                // keep the result alive
///     }
/// }
/// ```
///
/// One call of `body` is one "op". The closure may capture and mutate setup
/// state; it is only ever called from the thread that runs `sws-bench micro`.
struct Benchmark {
    let name: String
    let body: () -> Void

    /// Registration is single-threaded (it happens at startup, before any
    /// benchmark runs), so the registry needs no lock.
    nonisolated(unsafe) private static var registry: [Benchmark] = []

    static func register(name: String, body: @escaping () -> Void) {
        precondition(!registry.contains { $0.name == name }, "duplicate benchmark name \(name)")
        registry.append(Benchmark(name: name, body: body))
    }

    static var all: [Benchmark] { registry }

    nonisolated(unsafe) private static var suiteRegistry: [BenchmarkSuite] = []

    /// Registers a benchmark that does its own timing and returns one ns/op figure per
    /// operation. Prefer `register(name:body:)`, which adds percentiles and allocation counts.
    static func registerSuite(name: String, run: @escaping () -> [(name: String, nanosecondsPerOp: Double)]) {
        suiteRegistry.append(BenchmarkSuite(name: name, run: run))
    }

    static var suites: [BenchmarkSuite] { suiteRegistry }
}

/// A self-timed group of benchmarks (see `Benchmark.registerSuite`).
struct BenchmarkSuite {
    let name: String
    let run: () -> [(name: String, nanosecondsPerOp: Double)]
}

/// Prevents the optimizer from deleting a computation whose result is unused, or
/// from stack-promoting an object passed to it (the body is never optimized, so
/// escape analysis must assume the value escapes).
@inline(never)
@_optimize(none)
func blackHole<T>(_ value: T) {}

struct MicroOptions {
    /// Calls of the body before measuring (also used to calibrate the batch size).
    var warmup = 1_000
    /// Number of timed samples. Each sample times `batch` consecutive calls.
    var iterations = 200
    /// Calls per sample; 0 means calibrate so a sample takes about `targetSampleNanoseconds`.
    var batch = 0
    var targetSampleNanoseconds = 50_000.0
    var filter: String?
}

struct MicroResult: Codable, Sendable {
    var name: String
    var samples: Int
    var batch: Int
    var minNanoseconds: Double
    var medianNanoseconds: Double
    var p99Nanoseconds: Double
    var meanNanoseconds: Double
    /// Heap allocations per op counted with the `malloc_logger` hook, or nil if unavailable.
    var allocationsPerOp: Double?
    /// Net change in live heap blocks per op (`malloc_zone_statistics` blocks_in_use delta).
    var retainedBlocksPerOp: Double?
}

enum MicroRunner {
    static func run(_ benchmark: Benchmark, options: MicroOptions) -> MicroResult {
        let clock = ContinuousClock()
        let body = benchmark.body

        // Warmup and calibration.
        let warmupCalls = max(1, options.warmup)
        let warmupStart = clock.now
        for _ in 0..<warmupCalls { body() }
        let perCall = Stats.nanoseconds(clock.now - warmupStart) / Double(warmupCalls)
        let batch: Int
        if options.batch > 0 {
            batch = options.batch
        } else {
            batch = max(1, Int(options.targetSampleNanoseconds / max(perCall, 0.1)))
        }

        // Timed samples.
        let iterations = max(1, options.iterations)
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        let blocksBefore = HeapStatistics.blocksInUse()
        for _ in 0..<iterations {
            let start = clock.now
            for _ in 0..<batch { body() }
            let elapsed = clock.now - start
            samples.append(Stats.nanoseconds(elapsed) / Double(batch))
        }
        let blocksAfter = HeapStatistics.blocksInUse()
        let totalOps = Double(iterations * batch)
        let summary = Summary(sorted: samples.sorted())

        // Allocation counting runs as a separate pass so the hook never skews timing.
        let allocationCalls = max(100, min(batch * 10, 1_000_000))
        let allocations = AllocationCounter.count { for _ in 0..<allocationCalls { body() } }

        return MicroResult(
            name: benchmark.name,
            samples: iterations,
            batch: batch,
            minNanoseconds: summary.min,
            medianNanoseconds: summary.median,
            p99Nanoseconds: summary.p99,
            meanNanoseconds: summary.mean,
            allocationsPerOp: allocations.map { Double($0) / Double(allocationCalls) },
            retainedBlocksPerOp: blocksBefore.flatMap { before in
                blocksAfter.map { after in Double(after - before) / totalOps }
            })
    }
}
