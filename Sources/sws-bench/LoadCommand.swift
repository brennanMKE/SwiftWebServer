import Foundation

enum LoadCommand {
    static let usage = """
        usage: sws-bench load --url URL [--path PATH] [--connections N] [--duration SECONDS]
                              [--keepalive | --no-keepalive] [--grace SECONDS] [--json]

          --url URL          http://host:port[/path] (http only)
          --path PATH        request target; overrides the URL's path (default /)
          --connections N    concurrent connections, one request in flight each (default 16)
          --duration S       seconds to issue requests, e.g. 10, 10s, 500ms (default 10)
          --keepalive        reuse connections (default); --no-keepalive opens one per request
                             and sends Connection: close
          --grace S          time allowed for in-flight requests after the duration (default 5)
          --json             print the result as JSON
        """

    static func run(_ argv: [String]) async throws -> Int32 {
        var args = try Arguments(argv, valueOptions: ["url", "path", "connections", "duration", "grace"])
        if args.flag("help") == true { print(usage); return 0 }
        let urlText = args.string("url")
        let pathOverride = args.string("path")
        let connections = try args.int("connections")
        let duration = try args.seconds("duration")
        let grace = try args.seconds("grace")
        let keepAlive = args.flag("keepalive")
        let json = args.flag("json") ?? false
        try args.checkAllConsumed()

        guard let urlText else {
            printError("sws-bench load: --url is required\n\n" + usage)
            return 2
        }
        guard let url = URL(string: urlText), url.scheme == "http", let host = url.host() else {
            printError("sws-bench load: --url must be http://host:port/...")
            return 2
        }
        var options = LoadOptions()
        options.host = host
        options.port = UInt16(url.port ?? 80)
        let urlPath = url.path(percentEncoded: true)
        options.path = urlPath.isEmpty ? "/" : urlPath
        if let pathOverride { options.path = pathOverride.hasPrefix("/") ? pathOverride : "/" + pathOverride }
        if let connections { options.connections = max(1, connections) }
        if let duration { options.duration = duration }
        if let grace { options.grace = grace }
        if let keepAlive { options.keepAlive = keepAlive }

        let result = await LoadRunner.run(options)
        if json {
            print(try JSONOutput.encode(LoadReport(machine: MachineInfo.current(), result: result)))
        } else {
            print(describe(result))
        }
        return result.requests > 0 ? 0 : 1
    }

    static func describe(_ r: LoadResult) -> String {
        var lines: [String] = []
        lines.append("sws-bench load \(r.url)")
        lines.append("  connections \(r.connections), keep-alive \(r.keepAlive ? "on" : "off"), "
            + "duration \(String(format: "%.2f", r.durationSeconds)) s")
        lines.append("  requests     \(r.requests)  (\(String(format: "%.0f", r.requestsPerSecond)) req/s, "
            + "\(String(format: "%.1f", r.bodyMegabytesPerSecond)) MiB/s body)")
        if let latency = r.latencyMilliseconds {
            lines.append("  latency ms   p50 \(ms(latency.p50))  p90 \(ms(latency.p90))  p99 \(ms(latency.p99))  "
                + "max \(ms(latency.max))  mean \(ms(latency.mean))")
        }
        let statuses = r.statusCounts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        lines.append("  statuses     \(statuses.isEmpty ? "none" : statuses)")
        let errors = r.errorsByKind.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        lines.append("  errors       \(r.errors)\(errors.isEmpty ? "" : "  (\(errors))")")
        lines.append("  connections opened \(r.connectionsOpened), stale keep-alive retries \(r.staleConnectionRetries)")
        return lines.joined(separator: "\n")
    }

    private static func ms(_ value: Double) -> String {
        String(format: value < 10 ? "%.3f" : "%.1f", value)
    }
}

struct LoadReport: Codable {
    var tool = "sws-bench load"
    var machine: MachineInfo
    var result: LoadResult
}
