import Foundation
import HTTP1
import HTTPCore

/// `sws-bench h1conn`: the HTTP/1.1 connection loop (#0080) over an in-process transport that
/// never suspends, so the numbers are the cost of our code per request: receive bookkeeping,
/// parse, handler call, serialize, send. Allocations are counted process-wide; the run is one
/// task, so they are the connection's own. Per-request figures are the difference between a
/// long and a short run, which cancels per-connection setup.
enum H1ConnBench {
    static let usage = """
        usage: sws-bench h1conn [--requests N] [--json]

          --requests N   requests in the long run (default 200000; the short run is N/10)

        Reports ns and allocations per request for keep-alive (one request per receive) and
        pipelined (16 requests per receive) traffic, with the hello handler of `serve`.
        """

    struct Result: Codable {
        var name: String
        var nanosecondsPerRequest: Double
        var allocationsPerRequest: Double?
    }

    static let request = "GET / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nUser-Agent: sws-bench\r\nAccept: */*\r\n\r\n"

    static func run(_ argv: [String]) async throws -> Int32 {
        var args = try Arguments(argv, valueOptions: ["requests"])
        if args.flag("help") == true { print(usage); return 0 }
        let requests = try args.int("requests") ?? 200_000
        let json = args.flag("json") ?? false
        try args.checkAllConsumed()

        var results: [Result] = []
        for (name, pipeline) in [("h1conn.keepalive request", 1), ("h1conn.pipelined16 request", 16)] {
            results.append(await measure(name: name, requests: max(requests, 1000), pipeline: pipeline))
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(results), as: UTF8.self))
        } else {
            for r in results {
                let allocs = r.allocationsPerRequest.map { String(format: "%.3f", $0) } ?? "n/a"
                print("\(r.name.padding(toLength: 30, withPad: " ", startingAt: 0)) "
                    + "\(String(format: "%8.1f", r.nanosecondsPerRequest)) ns/req  \(allocs) allocs/req")
            }
        }
        return 0
    }

    static func measure(name: String, requests: Int, pipeline: Int) async -> Result {
        let handler = HelloHandler()
        let protocolInstance = HTTP1()
        // Warm up.
        _ = await serve(protocolInstance, handler, batches: 100, pipeline: pipeline)
        let longBatches = requests / pipeline
        let shortBatches = max(1, longBatches / 10)
        let short = await serve(protocolInstance, handler, batches: shortBatches, pipeline: pipeline)
        let long = await serve(protocolInstance, handler, batches: longBatches, pipeline: pipeline)
        let extraRequests = Double((longBatches - shortBatches) * pipeline)
        let ns = Stats.nanoseconds(long.elapsed - short.elapsed) / extraRequests
        var allocs: Double?
        if let a = long.allocations, let b = short.allocations { allocs = Double(a - b) / extraRequests }
        return Result(name: name, nanosecondsPerRequest: ns, allocationsPerRequest: allocs)
    }

    static func serve(_ proto: HTTP1, _ handler: HelloHandler, batches: Int, pipeline: Int)
        async -> (elapsed: Duration, allocations: Int?) {
        var batch = ByteBuffer()
        for _ in 0..<pipeline { batch.append(contentsOf: Array(request.utf8)) }
        let transport = RepeatingTransport(batch: batch, count: batches)
        let context = ConnectionContext(info: ConnectionInfo())
        let clock = ContinuousClock()
        var elapsed = Duration.zero
        let allocations = await AllocationCounter.countAsync {
            let start = clock.now
            await proto.run(transport, handler: handler, context: context)
            elapsed = clock.now - start
        }
        precondition(transport.sentBytes > 0, "h1conn bench: nothing was sent")
        return (elapsed, allocations)
    }
}

/// Delivers the same batch `count` times, one batch per receive, then end of stream. Sends are
/// counted and dropped. Nothing suspends, so the loop measures only the connection's work.
final class RepeatingTransport: ByteStreamTransport, @unchecked Sendable {
    let batch: ByteBuffer
    var remaining: Int
    var sentBytes = 0

    init(batch: ByteBuffer, count: Int) {
        self.batch = batch
        self.remaining = count
    }

    var info: ConnectionInfo { ConnectionInfo() }

    func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        guard remaining > 0 else { return 0 }
        remaining -= 1
        precondition(batch.readableBytes <= maxLength)
        buffer.append(batch)
        return batch.readableBytes
    }

    func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws {
        sentBytes += bytes.readableBytes
    }

    func close(_ reason: CloseReason) async {}
}
