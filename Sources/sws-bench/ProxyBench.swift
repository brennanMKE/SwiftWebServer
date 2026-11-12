import Darwin
import Foundation
import HTTPCore
import NetworkTransport
@_spi(Benchmark) import Proxy

/// Proxy microbenchmarks (#0120, #0121). Select with `sws-bench micro --filter Proxy`: the
/// per-request CPU work of the proxy without I/O (request head serialization, response head
/// parsing, mount lookup, request header rewriting).
func registerProxyBenchmarks() {
    let request = UpstreamRequest(method: .get, target: "/users/42?expand=1", host: "127.0.0.1:9000",
                                  headers: benchUpstreamFields())
    var head = ByteBuffer(capacity: 1024)
    Benchmark.register(name: "Proxy.writeHead (6 fields)") {
        head.clear()
        UpstreamHTTP1Client.benchWriteHead(request, into: &head)
        blackHole(head.readableBytes)
    }

    let response = Array("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\nDate: Wed, 11 Nov 2026 10:00:00 GMT\r\nCache-Control: no-store\r\nX-Request-Id: 8c1f2a\r\n\r\n".utf8)
    let parser = UpstreamResponseParser()
    Benchmark.register(name: "Proxy.parseHead (5 fields)") {
        blackHole(try? parser.parseHead(response, requestMethod: .get))
    }

    let mounts = [ProxyMount(path: "/api", upstreams: [UpstreamTarget(address: .tcp(host: "127.0.0.1", port: 9000))]),
                  ProxyMount(path: "/cgi-bin", upstreams: [UpstreamTarget(address: .tcp(host: "127.0.0.1", port: 9001))])]
    let proxy = ReverseProxy(mounts: mounts, client: UpstreamHTTP1Client())
    let context = RequestContext(connection: ConnectionInfo(remoteAddress: TransportAddress(host: "203.0.113.7", port: 5555)))
    for (name, path) in [("miss (static file)", "/assets/app.js"), ("hit", "/api/users/42")] {
        let (storage, request) = proxyBenchRequest(path)
        Benchmark.register(name: "Proxy.lookup \(name)") {
            blackHole(proxy.benchLookup(request))
        }
        blackHole(storage)
    }
    let (storage, apiRequest) = proxyBenchRequest("/api/users/42")
    Benchmark.register(name: "Proxy.makeUpstreamRequest (path, query, 6 fields)") {
        blackHole(proxy.benchUpstreamRequest(apiRequest, context: context))
    }
    blackHole(storage)
}

private func benchUpstreamFields() -> HTTPFields {
    var fields = HTTPFields()
    fields.append(name: "Accept", value: "application/json")
    fields.append(name: "User-Agent", value: "sws-bench")
    fields.append(name: "Accept-Encoding", value: "gzip, br")
    fields.append(name: "X-Forwarded-For", value: "203.0.113.7")
    fields.append(name: "X-Forwarded-Proto", value: "https")
    fields.append(name: "X-Request-Id", value: "8c1f2a")
    return fields
}

/// A `GET path?expand=1` request with typical browser fields, in its own storage.
private func proxyBenchRequest(_ path: String) -> (HTTPRequestStorage, HTTPRequest) {
    let storage = HTTPRequestStorage(bufferCapacity: 1024, fieldCapacity: 8)
    func add(_ text: String) -> ByteView {
        let start = storage.buffer.writerIndex
        storage.buffer.append(contentsOf: Array(text.utf8))
        return ByteView(offset: start, length: text.utf8.count)
    }
    let pathView = add(path)
    let queryView = add("expand=1")
    for (name, value) in [("Host", "example.com"), ("Accept", "application/json"), ("User-Agent", "sws-bench"),
                          ("Accept-Encoding", "gzip, br"), ("Connection", "keep-alive"), ("X-Request-Id", "8c1f2a")] {
        let nameView = add(name)
        let hash = storage.buffer.withSpan(of: nameView) { ASCII.fnv1aLowercased($0) }
        storage.appendField(nameView: nameView, hash: hash, valueView: add(value))
    }
    return (storage, HTTPRequest(method: .get, path: pathView, query: queryView, headers: storage.fieldsView))
}

/// `sws-bench proxy`: the proxy's added cost per request over a warm keep-alive pool, against
/// an in-process upstream on 127.0.0.1 that answers every request with the same 5-byte body.
enum ProxyBench {
    static let usage = """
        usage: sws-bench proxy [--requests N] [--json]

          --requests N   requests in the long run (default 20000; the short run is N/10)

        Each row runs requests one after another over one kept-alive upstream connection
        (so it includes two loopback socket round trips per request):

          raw             hand-written HTTP/1.1 client: send a fixed request, read the fixed answer
          client          UpstreamHTTP1Client.send + body drain (pooled connection)
          client-notimer  the same with every upstream timeout off
          proxy           ReverseProxy.handle (header rewrite, upstream request, response mapping)
                          + the streamed body written to a null writer
          proxy-notimer   the same with every upstream timeout off

        `proxy - raw` is the proxy's added cost per request. Allocations are process-wide
        (the upstream's included), so compare rows rather than reading them absolutely. Numbers
        are indicative: they depend on load (the load average is printed with the results).
        """

    struct Result: Codable {
        var name: String
        var nanosecondsPerRequest: Double
        var allocationsPerRequest: Double?
    }

    static let answer = "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 5\r\n\r\nhello"

    static func run(_ argv: [String]) async throws -> Int32 {
        var args = try Arguments(argv, valueOptions: ["requests"])
        if args.flag("help") == true { print(usage); return 0 }
        let requests = try args.int("requests") ?? 20_000
        let json = args.flag("json") ?? false
        try args.checkAllConsumed()

        let listener = try BSDSocketListener()
        let port = try await listener.start()
        let results = try await withThrowingTaskGroup(of: [Result]?.self) { group -> [Result] in
            group.addTask {
                await withTaskGroup(of: Void.self) { connections in
                    do {
                        for try await connection in listener.connections {
                            connections.addTask { await serve(connection) }
                        }
                    } catch {}
                    connections.cancelAll()
                }
                return nil
            }
            defer { group.cancelAll() }
            let results = try await measureAll(port: port, requests: requests)
            await listener.close()
            return results
        }
        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, 3)
        let loadText = String(format: "%.2f %.2f %.2f", load[0], load[1], load[2])
        if json {
            struct Report: Codable { var loadAverage: String; var results: [Result] }
            print(try JSONOutput.encode(Report(loadAverage: loadText, results: results)))
        } else {
            print("load average: \(loadText)")
            for r in results {
                let allocs = r.allocationsPerRequest.map { String(format: "%8.1f allocs", $0) } ?? ""
                print(r.name.padding(toLength: 16, withPad: " ", startingAt: 0) + String(format: "%10.0f ns/request  ", r.nanosecondsPerRequest) + allocs)
            }
            if let raw = results.first(where: { $0.name == "raw" }) {
                for name in ["proxy", "proxy-notimer"] {
                    guard let p = results.first(where: { $0.name == name }) else { continue }
                    print(String(format: "%@ - raw: %.0f ns/request added", name as NSString,
                                 p.nanosecondsPerRequest - raw.nanosecondsPerRequest))
                }
            }
        }
        return 0
    }

    /// Answers every request head with ``answer`` (requests carry no body).
    static func serve(_ connection: BSDSocketTransport) async {
        var buffer = ByteBuffer(capacity: 16 * 1024)
        let reply = ByteBuffer(bytes: Array(answer.utf8))
        while true {
            guard let n = try? await connection.receive(into: &buffer, maxLength: 16 * 1024), n > 0 else { break }
            var heads = 0
            var consumed = 0
            buffer.withUnsafeReadableBytes { bytes in
                var i = 3
                while i < bytes.count {
                    if bytes[i] == 10, bytes[i - 1] == 13, bytes[i - 2] == 10, bytes[i - 3] == 13 {
                        heads += 1
                        consumed = i + 1
                    }
                    i += 1
                }
            }
            buffer.moveReaderIndex(forwardBy: consumed)
            buffer.discardReadBytes()
            for _ in 0..<heads {
                guard (try? await connection.send(reply, endOfStream: false)) != nil else { return }
            }
        }
        await connection.close(.normal)
    }

    static func measureAll(port: UInt16, requests: Int) async throws -> [Result] {
        var results: [Result] = []
        // raw
        let raw = try await BSDSocketTransport.connect(host: "127.0.0.1", port: port)
        let rawRequest = ByteBuffer(bytes: Array("GET /users/42 HTTP/1.1\r\nhost: 127.0.0.1\r\naccept: */*\r\n\r\n".utf8))
        let answerLength = answer.utf8.count
        var rawBuffer = ByteBuffer(capacity: 16 * 1024)
        results.append(try await measure("raw", requests: requests) {
            try await raw.send(rawRequest, endOfStream: false)
            rawBuffer.clear()
            while rawBuffer.readableBytes < answerLength {
                _ = try await raw.receive(into: &rawBuffer, maxLength: 16 * 1024)
            }
        })
        await raw.close(.normal)

        let target = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: port))
        let upstreamRequest = UpstreamRequest(method: .get, target: "/users/42", host: "127.0.0.1:\(port)",
                                              headers: benchUpstreamFields())
        let noTimers = UpstreamTimeouts(connect: nil, response: nil, idle: nil, total: nil)
        for (name, timeouts) in [("client", UpstreamTimeouts()), ("client-notimer", noTimers)] {
            let client = UpstreamHTTP1Client()
            let options = UpstreamSendOptions(timeouts: timeouts)
            results.append(try await measure(name, requests: requests) {
                let response = try await client.send(upstreamRequest, body: .empty, to: target, options: options)
                while let chunk = try await response.body.next() { blackHole(chunk) }
            })
            await client.shutdown()
        }

        let (storage, request) = proxyBenchRequest("/api/users/42")
        let context = RequestContext(connection: ConnectionInfo(remoteAddress: TransportAddress(host: "203.0.113.7", port: 5555)))
        let writer = NullBodyWriter()
        for (name, timeouts) in [("proxy", UpstreamTimeouts()), ("proxy-notimer", noTimers)] {
            var mount = ProxyMount(path: "/api", upstreams: [target], stripPrefix: true)
            mount.policy.timeouts = timeouts
            let client = UpstreamHTTP1Client()
            let proxy = ReverseProxy(mounts: [mount], client: client)
            let next = NotFoundBench()
            results.append(try await measure(name, requests: requests) {
                let response = try await proxy.handle(request, context: context, next: next)
                guard case .stream(_, let body) = response.body else { fatalError("proxy bench: \(response.status)") }
                try await body(writer)
            })
            await client.shutdown()
        }
        blackHole(storage)
        return results
    }

    static func measure(_ name: String, requests: Int, _ body: () async throws -> Void) async throws -> Result {
        func loop(_ n: Int) async throws -> (Duration, Int?) {
            let clock = ContinuousClock()
            var elapsed = Duration.zero
            let allocations = try await AllocationCounter.countAsync {
                let start = clock.now
                for _ in 0..<n { try await body() }
                elapsed = clock.now - start
            }
            return (elapsed, allocations)
        }
        _ = try await loop(500)
        let shortRequests = max(1, requests / 10)
        let short = try await loop(shortRequests)
        let long = try await loop(requests)
        let extra = Double(requests - shortRequests)
        var allocs: Double?
        if let a = long.1, let b = short.1 { allocs = Double(a - b) / extra }
        return Result(name: name, nanosecondsPerRequest: Stats.nanoseconds(long.0 - short.0) / extra,
                      allocationsPerRequest: allocs)
    }
}

private struct NullBodyWriter: HTTPBodyWriter {
    func write(_ bytes: ByteBuffer) async throws { blackHole(bytes.readableBytes) }
}

private struct NotFoundBench: HTTPHandler {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        HTTPResponse(status: .notFound)
    }
}
