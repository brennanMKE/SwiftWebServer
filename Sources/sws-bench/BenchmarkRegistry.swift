/// The single registration point for microbenchmarks.
///
/// To add benchmarks for a target, create `Sources/sws-bench/<Name>Bench.swift`
/// containing a `func register<Name>Benchmarks()` that calls
/// `Benchmark.register(name:body:)`, then add one call to the list below.
/// Use a `Target.operation` naming scheme (e.g. `ByteBuffer.writeBytes`) so
/// `--filter` can select a target's benchmarks.
func registerAllBenchmarks() {
    registerHarnessBenchmarks()
    registerFieldsBenchmarks()   // M1.2: FieldsBench.swift
    registerParserBenchmarks()   // M1.3: ParserBench.swift
    registerSerializerBenchmarks()   // M1.4: SerializerBench.swift
    registerStaticFilesBenchmarks()   // M4.2: StaticFilesBench.swift
    registerSelfTimedSuites()
}

/// Calibration benchmarks for the harness itself: the cost of an empty op and of
/// one class allocation, which also checks that allocation counting works
/// (`harness.allocateObject` must report 1.00 allocations/op).
func registerHarnessBenchmarks() {
    Benchmark.register(name: "harness.noop") {}

    final class Box { var value = 0 }
    var counter = 0
    Benchmark.register(name: "harness.allocateObject") {
        let box = Box()
        box.value = counter
        counter &+= 1
        blackHole(box)
    }
}

/// Benchmarks written before the harness existed time themselves; they are reported
/// with their own ns/op and no percentiles or allocation counts. Converting one to
/// `Benchmark.register(name:body:)` closures adds both.
func registerSelfTimedSuites() {
    Benchmark.registerSuite(name: "bytebuffer") {
        runByteBufferBenchmarks()
    }
    Benchmark.registerSuite(name: "huffman") {
        HuffmanBench.run().map { result in
            (result.name, Stats.nanoseconds(result.elapsed) / Double(max(1, result.iterations)))
        }
    }
    Benchmark.registerSuite(name: "qpack") {
        QPACKBench.run().map { ($0.name, $0.nanosecondsPerIteration) }
    }
    Benchmark.registerSuite(name: "h3frame") {
        H3FrameBench.run().map { ("\($0.name) (per frame)", $0.nanosecondsPerFrame) }
    }
}
