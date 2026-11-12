import HTTP1
import HTTPCore
import HTTPTestSupport
import NetworkTransport
@testable import Proxy
import Synchronization
import Testing

// #0122: timeouts, error mapping, retries, balancing, health, cancellation, backpressure.

/// What a scripted upstream observed.
final class UpstreamCounters: Sendable {
    let accepted = Atomic<Int>(0)
    let peerClosed = Atomic<Int>(0)
    let bytesSent = Atomic<Int>(0)
    let finished = Atomic<Int>(0)
}

/// An upstream on 127.0.0.1:0 that reads one request head per connection and hands the
/// connection and request path to `script`.
final class ScriptedUpstream: Sendable {
    typealias Script = @Sendable (BSDSocketTransport, String, UpstreamCounters) async -> Void
    let listener: BSDSocketListener
    let port: UInt16
    let counters = UpstreamCounters()
    let task: Task<Void, Never>

    init(_ script: @escaping Script) async throws {
        listener = try BSDSocketListener()
        port = try await listener.start()
        let l = listener
        let counters = counters
        task = Task {
            await withTaskGroup(of: Void.self) { group in
                do {
                    for try await conn in l.connections {
                        counters.accepted.add(1, ordering: .relaxed)
                        group.addTask {
                            var pending: [UInt8] = []
                            while UpstreamResponseParser.findHeadEnd(pending) == nil {
                                guard await TinyUpstream.read(conn, into: &pending) else {
                                    await conn.close(.normal)
                                    return
                                }
                            }
                            let head = String(decoding: pending, as: UTF8.self)
                            let path = String(head.split(separator: " ")[1])
                            await script(conn, path, counters)
                            await conn.close(.normal)
                        }
                    }
                } catch {}
                group.cancelAll()
            }
        }
    }

    var target: UpstreamTarget { UpstreamTarget(address: .tcp(host: "127.0.0.1", port: port)) }

    func stop() async {
        await listener.close()
        task.cancel()
        await task.value
    }

    static func send(_ conn: BSDSocketTransport, _ text: String) async {
        _ = try? await conn.send(ByteBuffer(bytes: Array(text.utf8)), endOfStream: false)
    }

    /// Waits until the proxy closes the connection, then counts it.
    static func awaitClose(_ conn: BSDSocketTransport, _ counters: UpstreamCounters) async {
        var b = ByteBuffer(capacity: 1024)
        while true {
            b.clear()
            guard let n = try? await conn.receive(into: &b, maxLength: 1024), n > 0 else { break }
        }
        counters.peerClosed.add(1, ordering: .relaxed)
    }
}

/// Polls `condition` every 10 ms for up to `limit`.
func eventually(_ limit: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let end = ContinuousClock.now + limit
    while ContinuousClock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A TCP port on 127.0.0.1 with nothing listening.
func closedPort() async throws -> UInt16 {
    let listener = try BSDSocketListener()
    let port = try await listener.start()
    await listener.close()
    return port
}

func mount(_ upstreams: [UpstreamTarget], _ configure: (inout UpstreamPolicy) -> Void = { _ in }) -> ProxyMount {
    var m = ProxyMount(path: "/", upstreams: upstreams)
    configure(&m.policy)
    return m
}

func streamWriter(_ response: HTTPResponse) -> (@Sendable (any HTTPBodyWriter) async throws -> Void)? {
    guard case .stream(_, let writer) = response.body else { return nil }
    return writer
}

/// A request with an arbitrary method, built the way a connection builds one.
func proxyRequest(_ method: HTTPMethod, _ path: String) -> (HTTPRequestStorage, HTTPRequest) {
    let built = ProxyTestRequest(path, headers: [("Host", "example.com")])
    var request = built.request
    request.method = method
    return (built.storage, request)
}

/// Records each attempt's target and answers per target.
final class ScriptedClient: UpstreamClient {
    let attempts = Mutex<[UInt16]>([])
    let answer: @Sendable (UpstreamTarget) throws -> UpstreamResponse
    init(_ answer: @escaping @Sendable (UpstreamTarget) throws -> UpstreamResponse) { self.answer = answer }

    func send(_ request: UpstreamRequest, body: HTTPRequestBody, to target: UpstreamTarget) async throws -> UpstreamResponse {
        if case .tcp(_, let port) = target.address { attempts.withLock { $0.append(port) } }
        return try answer(target)
    }

    var ports: [UInt16] { attempts.withLock { $0 } }
}

func target(_ port: UInt16) -> UpstreamTarget { UpstreamTarget(address: .tcp(host: "127.0.0.1", port: port)) }
let okResponse = UpstreamResponse(status: .ok, headers: HTTPFields(), body: .empty)

// MARK: - Timeouts and error mapping

@Suite(.serialized) struct UpstreamTimeoutTests {
    @Test(.timeLimit(.minutes(1))) func refusedConnectionGives502() async throws {
        let port = try await closedPort()
        let client = UpstreamHTTP1Client()
        let proxy = ReverseProxy(mounts: [mount([target(port)])], client: client)
        #expect(try await send(proxy, "/x").status == .badGateway)
    }

    @Test(.timeLimit(.minutes(1))) func slowHeadGives504() async throws {
        let upstream = try await ScriptedUpstream { conn, _, counters in
            await ScriptedUpstream.awaitClose(conn, counters)
        }
        let client = UpstreamHTTP1Client()
        let proxy = ReverseProxy(mounts: [mount([upstream.target]) { $0.timeouts.response = .milliseconds(200) }], client: client)
        let start = ContinuousClock.now
        let response = try await send(proxy, "/slow")
        let elapsed = ContinuousClock.now - start
        #expect(response.status == .gatewayTimeout)
        #expect(elapsed >= .milliseconds(200) && elapsed < .seconds(3), "\(elapsed)")
        // The timed-out connection is closed, not pooled.
        #expect(await eventually { upstream.counters.peerClosed.load(ordering: .relaxed) == 1 })
        #expect(client.idleCount(for: upstream.target.address) == 0)
        await client.shutdown()
        await upstream.stop()
    }

    @Test(.timeLimit(.minutes(1))) func totalTimeoutBoundsTheHeadWait() async throws {
        let upstream = try await ScriptedUpstream { conn, _, counters in
            await ScriptedUpstream.awaitClose(conn, counters)
        }
        let client = UpstreamHTTP1Client()
        let proxy = ReverseProxy(mounts: [mount([upstream.target]) {
            $0.timeouts.response = .seconds(30)
            $0.timeouts.total = .milliseconds(200)
        }], client: client)
        let start = ContinuousClock.now
        #expect(try await send(proxy, "/slow").status == .gatewayTimeout)
        #expect(ContinuousClock.now - start < .seconds(3))
        await client.shutdown()
        await upstream.stop()
    }

    @Test(.timeLimit(.minutes(1))) func malformedHeadGives502() async throws {
        let upstream = try await ScriptedUpstream { conn, _, _ in
            await ScriptedUpstream.send(conn, "HTTP/1.1 2x0 Nope\r\n\r\n")
        }
        let client = UpstreamHTTP1Client()
        let proxy = ReverseProxy(mounts: [mount([upstream.target])], client: client)
        #expect(try await send(proxy, "/bad").status == .badGateway)
        await client.shutdown()
        await upstream.stop()
    }

    @Test(.timeLimit(.minutes(1))) func connectTimeoutGives504() async throws {
        // macOS resets loopback SYNs to a full accept queue instead of dropping them, so a
        // connect cannot be made to hang for real; the seam stalls before the connect instead.
        let upstream = try await ScriptedUpstream { conn, _, _ in
            await ScriptedUpstream.send(conn, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        }
        let client = UpstreamHTTP1Client(beforeConnect: { try await Task.sleep(for: .seconds(30)) })
        let proxy = ReverseProxy(mounts: [mount([upstream.target]) {
            $0.timeouts.connect = .milliseconds(150)
            $0.retries = 2
        }], client: client)
        let start = ContinuousClock.now
        #expect(try await send(proxy, "/x").status == .gatewayTimeout)
        // Three attempts (GET is retried after a connect failure), each cut at 150 ms.
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(450) && elapsed < .seconds(5), "\(elapsed)")
        #expect(client.connectionsOpened == 0)
        #expect(upstream.counters.accepted.load(ordering: .relaxed) == 0)
        await client.shutdown()
        await upstream.stop()
    }

    @Test(.timeLimit(.minutes(1))) func idleTimeoutAbortsMidBody() async throws {
        let upstream = try await ScriptedUpstream { conn, _, counters in
            await ScriptedUpstream.send(conn, "HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\nabc")
            await ScriptedUpstream.awaitClose(conn, counters)
        }
        let client = UpstreamHTTP1Client()
        let proxy = ReverseProxy(mounts: [mount([upstream.target]) { $0.timeouts.idle = .milliseconds(200) }], client: client)
        let response = try await send(proxy, "/stall")
        #expect(response.status == .ok)
        let writer = try #require(streamWriter(response))
        let collector = Collector()
        let start = ContinuousClock.now
        await #expect(throws: UpstreamError.timeout) { try await writer(collector) }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(collector.chunks.withLock { $0.flatMap { $0 } } == Array("abc".utf8))
        #expect(await eventually { upstream.counters.peerClosed.load(ordering: .relaxed) == 1 })
        #expect(client.idleCount(for: upstream.target.address) == 0)
        await client.shutdown()
        await upstream.stop()
    }

    @Test(.timeLimit(.minutes(1))) func totalTimeoutAbortsATricklingBody() async throws {
        let upstream = try await ScriptedUpstream { conn, _, _ in
            await ScriptedUpstream.send(conn, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
            for _ in 0..<200 {
                await ScriptedUpstream.send(conn, "1\r\nx\r\n")
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
        let client = UpstreamHTTP1Client()
        let proxy = ReverseProxy(mounts: [mount([upstream.target]) { $0.timeouts.total = .milliseconds(300) }], client: client)
        let writer = try #require(streamWriter(try await send(proxy, "/trickle")))
        let start = ContinuousClock.now
        await #expect(throws: UpstreamError.timeout) { try await writer(Collector()) }
        #expect(ContinuousClock.now - start < .seconds(3))
        await client.shutdown()
        await upstream.stop()
    }

    @Test func timeoutHelperRacesAndDiscards() async throws {
        let discarded = Atomic<Int>(0)
        await #expect(throws: UpstreamError.connectTimeout) {
            _ = try await withUpstreamTimeout(.milliseconds(20), error: .connectTimeout,
                                              discard: { _ in discarded.add(1, ordering: .relaxed) }) {
                try? await Task.sleep(for: .seconds(10))
                return 1
            }
        }
        #expect(discarded.load(ordering: .relaxed) == 1)
        #expect(try await withUpstreamTimeout(.seconds(10)) { 7 } == 7)
        #expect(throws: UpstreamError.timeout) {
            _ = try UpstreamTimeouts.limit(.seconds(1), deadline: .now - .seconds(1))
        }
    }
}

// MARK: - Aborting the downstream response

struct ProxyHandler: HTTPHandler {
    let proxy: ReverseProxy
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        try await proxy.handle(request, context: context, next: StaticHandler())
    }
}

@Suite struct UpstreamAbortTests {
    @Test(.timeLimit(.minutes(1))) func h1ClosesWithoutTheLastChunkAfterAMidBodyFailure() async throws {
        let client = FakeUpstreamClient {
            let sent = Mutex(false)
            let body = UpstreamResponseBody(knownLength: nil, next: {
                if sent.withLock({ let was = $0; $0 = true; return was }) { throw UpstreamError.timeout }
                return ByteBuffer("partial")
            }, discard: {})
            return UpstreamResponse(status: .ok, headers: HTTPFields(), body: body)
        }
        let proxy = ReverseProxy(mounts: [ProxyMount(path: "/", upstreams: [upstream])], client: client)
        let transport = InMemoryTransport.scripted([
            .bytes(ByteBuffer("GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n")),
            .delay(.seconds(2)), .endOfStream,
        ])
        let start = ContinuousClock.now
        await HTTP1().run(transport, handler: ProxyHandler(proxy: proxy),
                          context: ConnectionContext(info: transport.info))
        let wire = transport.sentBytes.withUnsafeReadableBytes { String(decoding: $0, as: UTF8.self) }
        #expect(wire.hasPrefix("HTTP/1.1 200"))
        #expect(wire.contains("partial"))
        // No terminating chunk and no second response: the connection was closed.
        #expect(!wire.hasSuffix("0\r\n\r\n"))
        #expect(wire.components(separatedBy: "HTTP/1.1 ").count == 2)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(client.count == 1)
    }
}

// MARK: - Retries

@Suite struct UpstreamRetryTests {
    @Test func connectFailuresRetryIdempotentRequestsOnly() async throws {
        let client = ScriptedClient { _ in throw UpstreamError.connectFailed("refused") }
        let proxy = ReverseProxy(mounts: [mount([target(1)]) { $0.retries = 2 }], client: client)
        #expect(try await send(proxy, "/a").status == .badGateway)
        #expect(client.ports == [1, 1, 1])

        for method in [HTTPMethod.post, .patch] {
            let posting = ScriptedClient { _ in throw UpstreamError.connectFailed("refused") }
            let postProxy = ReverseProxy(mounts: [mount([target(1), target(2)]) { $0.retries = 3 }], client: posting)
            let (storage, request) = proxyRequest(method, "/a")
            let response = try await postProxy.handle(request, context: peerContext, next: StaticHandler())
            withExtendedLifetime(storage) {}
            #expect(response.status == .badGateway)
            #expect(posting.ports.count == 1, "\(method) must never be retried")
        }
    }

    @Test func failuresAfterTheRequestWasSentAreNotRetried() async throws {
        for error in [UpstreamError.timeout, .closedEarly, .malformedResponse("x")] {
            let client = ScriptedClient { _ in throw error }
            let proxy = ReverseProxy(mounts: [mount([target(1), target(2)]) { $0.retries = 3 }], client: client)
            let status = try await send(proxy, "/a").status
            #expect(status == (error == .timeout ? .gatewayTimeout : .badGateway))
            #expect(client.ports.count == 1, "\(error)")
        }
    }

    @Test func failoverGoesToTheNextUpstream() async throws {
        let client = ScriptedClient { target in
            if case .tcp(_, 1) = target.address { throw UpstreamError.connectFailed("down") }
            return okResponse
        }
        let proxy = ReverseProxy(mounts: [mount([target(1), target(2), target(3)]) { $0.retries = 1 }], client: client)
        #expect(try await send(proxy, "/a").status == .ok)
        #expect(client.ports == [1, 2])
    }

    @Test func roundRobinSpreadsRequests() async throws {
        let client = ScriptedClient { _ in okResponse }
        let proxy = ReverseProxy(mounts: [mount([target(1), target(2), target(3)])], client: client)
        for _ in 0..<6 { _ = try await send(proxy, "/a") }
        #expect(client.ports == [1, 2, 3, 1, 2, 3])
    }

    @Test(.timeLimit(.minutes(1))) func stalePooledConnectionIsRetriedForGetOnly() async throws {
        // Answers one request per connection without `connection: close`, then closes.
        let upstream = try await ScriptedUpstream { conn, _, _ in
            await ScriptedUpstream.send(conn, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
        }
        let client = UpstreamHTTP1Client()
        let target = upstream.target
        func request(_ method: HTTPMethod) -> UpstreamRequest {
            UpstreamRequest(method: method, target: "/", host: "x", headers: HTTPFields())
        }
        #expect(try await collect(client.send(request(.get), body: .empty, to: target).body) == "ok")
        #expect(client.idleCount(for: target.address) == 1)
        try await Task.sleep(for: .milliseconds(100)) // the upstream closes the pooled connection
        #expect(try await collect(client.send(request(.get), body: .empty, to: target).body) == "ok")
        #expect(client.connectionsOpened == 2)

        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: UpstreamError.closedEarly) {
            _ = try await client.send(request(.post), body: .empty, to: target)
        }
        #expect(client.connectionsOpened == 2)
        await client.shutdown()
        await upstream.stop()
    }
}

// MARK: - Health

@Suite struct UpstreamHealthTests {
    @Test func passiveHealthMarksDownForTheCooldown() {
        let balancer = UpstreamBalancer(count: 2, policy: UpstreamHealthPolicy(maxFailures: 2, cooldown: .seconds(10)))
        let now = ContinuousClock.now
        #expect(balancer.order(now: now) == [0, 1])
        #expect(balancer.order(now: now) == [1, 0])
        balancer.recordFailure(0, now: now)
        #expect(balancer.isUp(0, now: now))
        balancer.recordFailure(0, now: now)
        #expect(!balancer.isUp(0, now: now))
        #expect(balancer.order(now: now) == [1])
        #expect(balancer.order(now: now) == [1])
        // After the cool-down it is tried again; a success clears the count.
        let later = now + .seconds(11)
        #expect(balancer.isUp(0, now: later))
        balancer.recordSuccess(0)
        balancer.recordFailure(0, now: later)
        #expect(balancer.isUp(0, now: later))
        // Every upstream down: try them all rather than fail outright.
        balancer.recordFailure(0, now: later)
        balancer.recordFailure(1, now: later)
        balancer.recordFailure(1, now: later)
        #expect(Set(balancer.order(now: later)) == [0, 1])
        // Passive tracking off.
        let off = UpstreamBalancer(count: 2, policy: UpstreamHealthPolicy(maxFailures: 0))
        for _ in 0..<10 { off.recordFailure(0) }
        #expect(off.isUp(0))
    }

    @Test func proxySkipsADownUpstream() async throws {
        let client = ScriptedClient { target in
            if case .tcp(_, 1) = target.address { throw UpstreamError.connectFailed("down") }
            return okResponse
        }
        let proxy = ReverseProxy(mounts: [mount([target(1), target(2)]) {
            $0.retries = 1
            $0.health = UpstreamHealthPolicy(maxFailures: 2, cooldown: .seconds(60))
        }], client: client)
        for _ in 0..<6 { #expect(try await send(proxy, "/a").status == .ok) }
        // 1 fails on the 1st and 3rd requests, then is skipped.
        #expect(client.ports == [1, 2, 2, 1, 2, 2, 2, 2])
    }

    @Test(.timeLimit(.minutes(1))) func activeCheckMarksUpstreamsUpAndDown() async throws {
        let upstream = try await ScriptedUpstream { conn, path, _ in
            let status = path == "/health" ? "200 OK" : "503 Unavailable"
            await ScriptedUpstream.send(conn, "HTTP/1.1 \(status)\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
        }
        let down = try await closedPort()
        let client = UpstreamHTTP1Client()
        let proxy = ReverseProxy(mounts: [mount([upstream.target, target(down)]) {
            $0.health.checkPath = "/health"
            $0.health.checkInterval = .milliseconds(200)
        }], client: client)
        let compiled = try #require(proxy.mounts.first)
        await ReverseProxy.checkOnce(compiled, client: client)
        #expect(compiled.balancer.isUp(0))
        #expect(!compiled.balancer.isUp(1))
        #expect(compiled.balancer.order() == [0])

        // As a component: runs until cancelled.
        let handle = ServerHandle(localAddresses: [], draining: ShutdownSignal(), requestShutdown: {})
        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await proxy.run(server: handle) }
            try? await Task.sleep(for: .milliseconds(300))
            group.cancelAll()
        }
        #expect(upstream.counters.accepted.load(ordering: .relaxed) >= 2)
        // A proxy with no check path returns at once.
        try await ReverseProxy(mounts: [mount([target(1)])], client: client).run(server: handle)
        await client.shutdown()
        await upstream.stop()
    }
}

// MARK: - Cancellation and backpressure

@Suite(.serialized) struct UpstreamCancelTests {
    @Test(.timeLimit(.minutes(1))) func clientCancelDuringHeadClosesTheUpstream() async throws {
        let upstream = try await ScriptedUpstream { conn, _, counters in
            await ScriptedUpstream.awaitClose(conn, counters)
        }
        let client = UpstreamHTTP1Client()
        let proxy = ReverseProxy(mounts: [mount([upstream.target])], client: client)
        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await send(proxy, "/wait") }
            #expect(await eventually { upstream.counters.accepted.load(ordering: .relaxed) == 1 })
            try? await Task.sleep(for: .milliseconds(50))
            group.cancelAll()
        }
        #expect(await eventually { upstream.counters.peerClosed.load(ordering: .relaxed) == 1 })
        #expect(client.idleCount(for: upstream.target.address) == 0)
        await client.shutdown()
        await upstream.stop()
    }

    @Test(.timeLimit(.minutes(1))) func clientCancelMidBodyClosesTheUpstream() async throws {
        let upstream = try await ScriptedUpstream { conn, _, counters in
            await ScriptedUpstream.send(conn, "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\nabc")
            await ScriptedUpstream.awaitClose(conn, counters)
        }
        let client = UpstreamHTTP1Client()
        let proxy = ReverseProxy(mounts: [mount([upstream.target])], client: client)
        let writer = try #require(streamWriter(try await send(proxy, "/body")))
        let collector = Collector()
        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await writer(collector) }
            #expect(await eventually { !collector.chunks.withLock { $0.isEmpty } })
            group.cancelAll()
        }
        #expect(await eventually { upstream.counters.peerClosed.load(ordering: .relaxed) == 1 })
        #expect(client.idleCount(for: upstream.target.address) == 0)
        await client.shutdown()
        await upstream.stop()
    }

    @Test(.timeLimit(.minutes(1))) func slowClientSlowsTheUpstream() async throws {
        let total = 64 * 1024 * 1024
        let upstream = try await ScriptedUpstream { conn, _, counters in
            await ScriptedUpstream.send(conn, "HTTP/1.1 200 OK\r\ncontent-length: \(total)\r\n\r\n")
            let chunk = ByteBuffer(bytes: [UInt8](repeating: 0x61, count: 64 * 1024))
            for _ in 0..<(total / (64 * 1024)) {
                do { try await conn.send(chunk, endOfStream: false) } catch { return }
                counters.bytesSent.add(64 * 1024, ordering: .relaxed)
            }
            counters.finished.add(1, ordering: .relaxed)
        }
        let client = UpstreamHTTP1Client()
        let proxy = ReverseProxy(mounts: [mount([upstream.target])], client: client)
        let writer = try #require(streamWriter(try await send(proxy, "/big")))
        /// Accepts one write, then blocks until cancelled.
        final class StalledWriter: HTTPBodyWriter, Sendable {
            let written = Atomic<Int>(0)
            func write(_ bytes: ByteBuffer) async throws {
                written.add(bytes.readableBytes, ordering: .relaxed)
                try await Task.sleep(for: .seconds(60))
            }
        }
        let stalled = StalledWriter()
        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await writer(stalled) }
            try? await Task.sleep(for: .milliseconds(500))
            // The proxy pulled one read; the upstream is held back by the socket buffers.
            #expect(stalled.written.load(ordering: .relaxed) <= 16 * 1024)
            #expect(upstream.counters.finished.load(ordering: .relaxed) == 0)
            #expect(upstream.counters.bytesSent.load(ordering: .relaxed) < 16 * 1024 * 1024)
            group.cancelAll()
        }
        await client.shutdown()
        await upstream.stop()
    }
}

// MARK: - Base path (the proxy alone prepends it)

@Suite(.serialized) struct UpstreamBasePathTests {
    @Test(.timeLimit(.minutes(1))) func upstreamSeesTheBasePathOnce() async throws {
        let seen = Mutex<[String]>([])
        let upstream = try await ScriptedUpstream { conn, path, _ in
            seen.withLock { $0.append(path) }
            await ScriptedUpstream.send(conn, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
        }
        let client = UpstreamHTTP1Client()
        let based = UpstreamTarget(address: upstream.target.address, basePath: "/app")
        let keep = ReverseProxy(mounts: [ProxyMount(path: "/cgi-bin", upstreams: [based])], client: client)
        let strip = ReverseProxy(mounts: [ProxyMount(path: "/cgi-bin", upstreams: [based], stripPrefix: true)], client: client)
        #expect(try await send(keep, "/cgi-bin/foo", query: "q=1").status == .ok)
        #expect(try await send(strip, "/cgi-bin/foo", query: "q=1").status == .ok)
        #expect(try await send(strip, "/cgi-bin").status == .ok)
        #expect(seen.withLock { $0 } == ["/app/cgi-bin/foo?q=1", "/app/foo?q=1", "/app/"])
        await client.shutdown()
        await upstream.stop()
    }
}
