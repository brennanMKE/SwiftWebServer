import Foundation

enum MicroCommand {
    static let usage = """
        usage: sws-bench micro [--filter TEXT] [--iterations N] [--warmup N] [--batch N] [--list] [--json]

          --filter TEXT    run benchmarks whose name contains TEXT
          --iterations N   timed samples per benchmark (default 200)
          --warmup N       untimed calls before sampling (default 1000)
          --batch N        calls per sample (default: calibrated to ~50 µs per sample)
          --list           print benchmark names and exit
          --json           print results as JSON
        """

    static func run(_ argv: [String]) throws -> Int32 {
        var args = try Arguments(argv, valueOptions: ["filter", "iterations", "warmup", "batch"])
        var options = MicroOptions()
        options.filter = args.string("filter")
        if let value = try args.int("iterations") { options.iterations = value }
        if let value = try args.int("warmup") { options.warmup = value }
        if let value = try args.int("batch") { options.batch = value }
        let list = args.flag("list") ?? false
        let json = args.flag("json") ?? false
        if args.flag("help") == true { print(usage); return 0 }
        try args.checkAllConsumed()

        registerAllBenchmarks()
        let selected = Benchmark.all.filter { benchmark in
            options.filter.map { benchmark.name.contains($0) } ?? true
        }
        // A suite runs as a whole; the filter matches its name.
        let suites = Benchmark.suites.filter { suite in
            options.filter.map { suite.name.contains($0) } ?? true
        }
        if list {
            for benchmark in selected { print(benchmark.name) }
            for suite in suites { print("\(suite.name) (self-timed suite)") }
            return 0
        }
        guard !selected.isEmpty || !suites.isEmpty else {
            FileHandle.standardError.write(Data("sws-bench micro: no benchmarks match\n".utf8))
            return 1
        }

        var results: [MicroResult] = []
        if !json {
            print(header())
        }
        for benchmark in selected {
            let result = MicroRunner.run(benchmark, options: options)
            results.append(result)
            if !json { print(row(result)) }
        }
        for suite in suites {
            for (name, nanoseconds) in suite.run() {
                let result = MicroResult(
                    name: "\(suite.name): \(name)", samples: 1, batch: 0,
                    minNanoseconds: nanoseconds, medianNanoseconds: nanoseconds, p99Nanoseconds: nanoseconds,
                    meanNanoseconds: nanoseconds, allocationsPerOp: nil, retainedBlocksPerOp: nil)
                results.append(result)
                if !json { print(row(result)) }
            }
        }
        if json {
            let report = MicroReport(machine: MachineInfo.current(), allocationMethod: allocationMethod, results: results)
            print(try JSONOutput.encode(report))
        } else {
            print("\nallocs/op: malloc_logger hook, \(AllocationCounter.isAvailable ? "available" : "unavailable"); "
                + "retained: malloc_zone_statistics blocks_in_use delta per op")
        }
        return 0
    }

    static let allocationMethod = "malloc_logger hook counting MALLOC_LOG_TYPE_ALLOCATE events in a separate untimed pass"

    private static func header() -> String {
        pad("benchmark", 44) + lpad("min ns", 11) + lpad("median ns", 11) + lpad("p99 ns", 11)
            + lpad("allocs/op", 11) + lpad("retained", 10) + lpad("batch", 9)
    }

    private static func row(_ r: MicroResult) -> String {
        pad(r.name, 44) + lpad(format(r.minNanoseconds), 11) + lpad(format(r.medianNanoseconds), 11)
            + lpad(format(r.p99Nanoseconds), 11)
            + lpad(r.allocationsPerOp.map { format($0) } ?? "n/a", 11)
            + lpad(r.retainedBlocksPerOp.map { format($0) } ?? "n/a", 10)
            + lpad(r.batch > 0 ? String(r.batch) : "self", 9)
    }

    static func format(_ value: Double) -> String {
        String(format: value < 100 ? "%.2f" : "%.0f", value)
    }
}

struct MicroReport: Codable {
    var tool = "sws-bench micro"
    var machine: MachineInfo
    var allocationMethod: String
    var results: [MicroResult]
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
}

func lpad(_ text: String, _ width: Int) -> String {
    text.count >= width ? " " + text : String(repeating: " ", count: width - text.count) + text
}
