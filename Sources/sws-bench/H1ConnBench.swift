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
        pipelined (16 requests per receive) traffic, with the hello handler of `serve`, then the
        same with that handler behind middleware chains (#0083):

          empty        the handler alone in a `CompiledChain` (an empty chain: what every
                       chain with a middleware pays; the builder returns a lone handler as is)
          chain3       three no-op middlewares in front of the handler
          chain3inline the same with `@inline(__always)` middlewares (equal to chain3 when the
                       optimizer inlined the plain ones)
          disabledif   `if disabled { NoOp() }` in front of the handler (the condition is read at
                       run time, so the component is compiled in but absent)
          starttime    the bare handler with `RequestContext.startTime` stamped per request

        The `dispatch` rows call the handler in a loop without the connection, through `any
        HTTPHandler` (unspecialized, as the protocol runners call it), so they isolate the
        chain's own cost.
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

        let hello = HelloHandler()
        // Never true, but the optimizer cannot know that.
        let disabled = ProcessInfo.processInfo.environment["SWS_BENCH_NEVER_SET"] != nil
        let empty = CompiledChain(hello)
        let chain3 = MiddlewareBuilder.build {
            NoOpMiddleware()
            NoOpMiddleware()
            NoOpMiddleware()
            hello
        }
        let chain3Inline = MiddlewareBuilder.build {
            InlineNoOpMiddleware()
            InlineNoOpMiddleware()
            InlineNoOpMiddleware()
            hello
        }
        let disabledIf = MiddlewareBuilder.build {
            if disabled { NoOpMiddleware() }
            hello
        }

        var results: [Result] = []
        for (name, pipeline) in [("keepalive", 1), ("pipelined16", 16)] {
            let count = max(requests, 1000)
            results.append(await measure(name: "h1conn.\(name) request", requests: count, pipeline: pipeline, handler: hello))
            results.append(await measure(name: "h1conn.\(name) empty", requests: count, pipeline: pipeline, handler: empty))
            results.append(await measure(name: "h1conn.\(name) chain3", requests: count, pipeline: pipeline, handler: chain3))
            results.append(await measure(name: "h1conn.\(name) chain3inline", requests: count, pipeline: pipeline, handler: chain3Inline))
            results.append(await measure(name: "h1conn.\(name) disabledif", requests: count, pipeline: pipeline, handler: disabledIf))
            results.append(await measure(name: "h1conn.\(name) starttime", requests: count, pipeline: pipeline, handler: hello,
                                         recordsStartTime: true))
        }
        let calls = max(requests * 10, 10_000)
        results.append(await dispatch(name: "dispatch request", calls: calls, handler: hello))
        results.append(await dispatch(name: "dispatch empty", calls: calls, handler: empty))
        results.append(await dispatch(name: "dispatch chain3", calls: calls, handler: chain3))
        results.append(await dispatch(name: "dispatch chain3inline", calls: calls, handler: chain3Inline))
        results.append(await dispatch(name: "dispatch disabledif", calls: calls, handler: disabledIf))
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(results), as: UTF8.self))
        } else {
            for r in results {
                let allocs = r.allocationsPerRequest.map { String(format: "%.3f", $0) } ?? "n/a"
                print("\(r.name.padding(toLength: 32, withPad: " ", startingAt: 0)) "
                    + "\(String(format: "%8.1f", r.nanosecondsPerRequest)) ns/req  \(allocs) allocs/req")
            }
        }
        return 0
    }

    static func measure<H: HTTPHandler>(name: String, requests: Int, pipeline: Int, handler: H,
                                        recordsStartTime: Bool = false) async -> Result {
        let protocolInstance = HTTP1()
        // Warm up.
        _ = await serve(protocolInstance, handler, batches: 100, pipeline: pipeline, recordsStartTime: recordsStartTime)
        let longBatches = requests / pipeline
        let shortBatches = max(1, longBatches / 10)
        let short = await serve(protocolInstance, handler, batches: shortBatches, pipeline: pipeline,
                                recordsStartTime: recordsStartTime)
        let long = await serve(protocolInstance, handler, batches: longBatches, pipeline: pipeline,
                               recordsStartTime: recordsStartTime)
        let extraRequests = Double((longBatches - shortBatches) * pipeline)
        let ns = Stats.nanoseconds(long.elapsed - short.elapsed) / extraRequests
        var allocs: Double?
        if let a = long.allocations, let b = short.allocations { allocs = Double(a - b) / extraRequests }
        return Result(name: name, nanosecondsPerRequest: ns, allocationsPerRequest: allocs)
    }

    static func serve<H: HTTPHandler>(_ proto: HTTP1, _ handler: H, batches: Int, pipeline: Int,
                                      recordsStartTime: Bool = false)
        async -> (elapsed: Duration, allocations: Int?) {
        var batch = ByteBuffer()
        for _ in 0..<pipeline { batch.append(contentsOf: Array(request.utf8)) }
        let transport = RepeatingTransport(batch: batch, count: batches)
        let context = ConnectionContext(info: ConnectionInfo(), recordsRequestStartTime: recordsStartTime)
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

    /// ns and allocations per direct `handle` call (no connection, no clock read): the cost of
    /// the chain itself. Short and long runs as in ``measure(name:requests:pipeline:handler:)``.
    static func dispatch<H: HTTPHandler>(name: String, calls: Int, handler: H) async -> Result {
        let storage = HTTPRequestStorage(bufferCapacity: 256, fieldCapacity: 8)
        storage.buffer.append("/")
        let request = HTTPRequest(method: .get, path: ByteView(offset: 0, length: 1), headers: storage.fieldsView)
        let context = RequestContext()
        // Through an existential, as the protocol runners call it: unspecialized.
        let handler: any HTTPHandler = opaque(handler)
        func loop(_ n: Int) async -> (Duration, Int?) {
            let clock = ContinuousClock()
            var elapsed = Duration.zero
            var statuses = 0
            let allocations = await AllocationCounter.countAsync {
                let start = clock.now
                for _ in 0..<n {
                    let response = try? await handler.handle(request, context: context)
                    statuses &+= Int(response?.status.code ?? 0)
                }
                elapsed = clock.now - start
            }
            blackHole(statuses)
            return (elapsed, allocations)
        }
        _ = await loop(1000)
        let shortCalls = max(1, calls / 10)
        let short = await loop(shortCalls)
        let long = await loop(calls)
        let extra = Double(calls - shortCalls)
        var allocs: Double?
        if let a = long.1, let b = short.1 { allocs = Double(a - b) / extra }
        return Result(name: name, nanosecondsPerRequest: Stats.nanoseconds(long.0 - short.0) / extra,
                      allocationsPerRequest: allocs)
    }
}

/// ``NoOpMiddleware`` that the optimizer always inlines into the chain.
struct InlineNoOpMiddleware: HTTPMiddleware {
    @inline(__always)
    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse {
        try await next.handle(request, context: context)
    }
}

/// Hides `value`'s type from the optimizer, so calls through the result stay unspecialized.
@inline(never) @_optimize(none)
func opaque(_ value: some HTTPHandler) -> any HTTPHandler { value }

/// Passes the request on: a stand-in for a component that has nothing to do for it.
struct NoOpMiddleware: HTTPMiddleware {
    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse {
        try await next.handle(request, context: context)
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
