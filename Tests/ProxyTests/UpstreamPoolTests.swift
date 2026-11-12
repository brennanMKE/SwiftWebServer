import HTTPCore
import NetworkTransport
@testable import Proxy
import Synchronization
import Testing

// #0120: connection limits, the bounded wait queue, idle eviction and the liveness check.

private func get(_ path: String = "/cl") -> UpstreamRequest {
    UpstreamRequest(method: .get, target: path, host: "127.0.0.1", headers: HTTPFields())
}

private func options(_ pool: UpstreamPoolPolicy) -> UpstreamSendOptions {
    UpstreamSendOptions(pool: pool)
}

private func poolEventually(_ limit: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let end = ContinuousClock.now + limit
    while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct UpstreamPoolTests {
    @Test func requestsOverTheLimitWaitForAConnection() async throws {
        let upstream = try await TinyUpstream()
        let client = UpstreamHTTP1Client()
        let target = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: upstream.port))
        let pool = UpstreamPoolPolicy(maxConnections: 1, maxQueue: 4, queueTimeout: .seconds(10))
        // The first response's body is not read yet, so its connection stays checked out.
        let first = try await client.send(get(), body: .empty, to: target, options: options(pool))
        #expect(client.openCount(for: target.address) == 1)
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    let r = try await client.send(get(), body: .empty, to: target, options: options(pool))
                    return try await collect(r.body)
                }
            }
            try await eventually { client.waitingCount(for: target.address) == 2 }
            #expect(client.waitingCount(for: target.address) == 2)
            #expect(try await collect(first.body) == "hello")
            for try await body in group { #expect(body == "hello") }
        }
        #expect(client.connectionsOpened == 1)
        #expect(client.openCount(for: target.address) == 1)
        #expect(client.waitingCount(for: target.address) == 0)
        await client.shutdown()
        await upstream.stop()
    }

    @Test func fullQueueAndQueueTimeoutAreExhaustion() async throws {
        let upstream = try await TinyUpstream()
        let client = UpstreamHTTP1Client()
        let target = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: upstream.port))
        let first = try await client.send(get(), body: .empty, to: target,
                                          options: options(UpstreamPoolPolicy(maxConnections: 1)))
        // No queue: refused at once.
        await #expect(throws: UpstreamError.poolExhausted) {
            _ = try await client.send(get(), body: .empty, to: target,
                                      options: options(UpstreamPoolPolicy(maxConnections: 1, maxQueue: 0)))
        }
        // A queue, but nothing is released within the timeout.
        let start = ContinuousClock.now
        await #expect(throws: UpstreamError.poolExhausted) {
            _ = try await client.send(get(), body: .empty, to: target,
                                      options: options(UpstreamPoolPolicy(maxConnections: 1, queueTimeout: .milliseconds(100))))
        }
        #expect(ContinuousClock.now - start >= .milliseconds(100))
        #expect(client.waitingCount(for: target.address) == 0)
        // The held connection still completes and is pooled; the next request reuses it.
        #expect(try await collect(first.body) == "hello")
        let next = try await client.send(get(), body: .empty, to: target,
                                         options: options(UpstreamPoolPolicy(maxConnections: 1, maxQueue: 0)))
        #expect(try await collect(next.body) == "hello")
        #expect(client.connectionsOpened == 1)
        await client.shutdown()
        await upstream.stop()
    }

    @Test func failedConnectGivesTheSlotBack() async throws {
        // A port with nothing listening: bind, read the port, close.
        let listener = try BSDSocketListener()
        let port = try await listener.start()
        await listener.close()
        let client = UpstreamHTTP1Client()
        let target = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: port))
        let pool = UpstreamPoolPolicy(maxConnections: 1, maxQueue: 0)
        for _ in 0..<3 {
            await #expect(throws: UpstreamError.self) {
                _ = try await client.send(get(), body: .empty, to: target, options: options(pool))
            }
            #expect(client.openCount(for: target.address) == 0)
        }
    }

    @Test func droppedResponseGivesTheSlotBack() async throws {
        let upstream = try await TinyUpstream()
        let client = UpstreamHTTP1Client()
        let target = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: upstream.port))
        let pool = UpstreamPoolPolicy(maxConnections: 1, maxQueue: 0)
        for _ in 0..<3 {
            // The body is never read or discarded (a response dropped unsent).
            _ = try await client.send(get(), body: .empty, to: target, options: options(pool))
            #expect(client.openCount(for: target.address) == 0)
        }
        #expect(client.connectionsOpened == 3)
        await client.shutdown()
        await upstream.stop()
    }

    @Test func idleConnectionsExpire() async throws {
        let upstream = try await TinyUpstream()
        let client = UpstreamHTTP1Client()
        let target = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: upstream.port))
        let pool = UpstreamPoolPolicy(idleTimeout: .milliseconds(50))
        #expect(try await collect(client.send(get(), body: .empty, to: target, options: options(pool)).body) == "hello")
        #expect(client.idleCount(for: target.address) == 1)
        try await Task.sleep(for: .milliseconds(120))
        // Checkout skips (and closes) the expired connection.
        #expect(try await collect(client.send(get(), body: .empty, to: target, options: options(pool)).body) == "hello")
        #expect(client.connectionsOpened == 2)
        #expect(client.openCount(for: target.address) == 1)
        // The periodic sweep closes it without traffic.
        try await Task.sleep(for: .milliseconds(120))
        await client.evictIdleConnections(all: false)
        #expect(client.idleCount(for: target.address) == 0)
        #expect(client.openCount(for: target.address) == 0)
        await client.shutdown()
        await upstream.stop()
    }

    @Test func sweepClosesConnectionsTheUpstreamClosed() async throws {
        let upstream = try await ScriptedUpstream { conn, _, _ in
            // Keep-alive framing, then the upstream closes the idle connection.
            await ScriptedUpstream.send(conn, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
        }
        let client = UpstreamHTTP1Client()
        let target = upstream.target
        let r = try await client.send(get("/"), body: .empty, to: target, options: options(UpstreamPoolPolicy(idleTimeout: nil)))
        #expect(try await collect(r.body) == "ok")
        #expect(client.idleCount(for: target.address) == 1)
        try await eventually { !(client.pools.idleConnection(target.address)?.transport.isIdleAndOpen ?? false) }
        await client.evictIdleConnections(all: false)
        #expect(client.idleCount(for: target.address) == 0)
        #expect(client.openCount(for: target.address) == 0)
        await upstream.stop()
    }

    @Test func proxyAnswers503WhenThePoolIsExhausted() async throws {
        let proxy = ReverseProxy(mounts: [ProxyMount(path: "/", upstreams: [upstream])],
                                 client: FakeUpstreamClient { throw UpstreamError.poolExhausted })
        #expect(try await send(proxy, "/x").status == .serviceUnavailable)
    }

    @Test func sweepInterval() {
        #expect(ReverseProxy.sweepInterval([]) == .seconds(30))
        #expect(ReverseProxy.sweepInterval([nil, .seconds(10)]) == .seconds(5))
        #expect(ReverseProxy.sweepInterval([.milliseconds(100)]) == .seconds(1))
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct UpstreamInterimResponseTests {
    @Test func interimResponsesAreConsumed() async throws {
        let upstream = try await ScriptedUpstream { conn, _, _ in
            await ScriptedUpstream.send(conn, "HTTP/1.1 100 Continue\r\n\r\n"
                + "HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n"
                + "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nx-final: 1\r\n\r\nok")
        }
        let client = UpstreamHTTP1Client()
        let r = try await client.send(get("/"), body: .empty, to: upstream.target)
        #expect(r.status.code == 200)
        #expect(header(r.headers, "x-final") == ["1"])
        #expect(header(r.headers, "link").isEmpty)
        #expect(try await collect(r.body) == "ok")
        await client.shutdown()
        await upstream.stop()
    }
}
