import Foundation
import HTTP1
import HTTP3
import HTTPCore
import HTTPServer
import HTTPTestSupport
import NetworkTransport
import Synchronization
import Testing

/// One `Server` over several kinds of listener (#0089): byte-stream listeners of different
/// types and a QUIC listener serving HTTP/3, with one connection limit, one drain and
/// per-listener counts.
@Suite struct MixedListenersTests {
    // MARK: In memory

    @Test(.timeLimit(.minutes(1)))
    func twoListenersShareOneServerAndCountSeparately() async throws {
        let first = InMemoryListener(address: TransportAddress(host: "memory", port: 1))
        let second = InMemoryListener(address: TransportAddress(host: "memory", port: 2))
        let probe = Probe()
        let server = Server(configuration: ServerConfiguration(maxConnections: 3, connectionLimitPolicy: .refuse,
                                                               drainTimeout: .milliseconds(100)),
                            listeners: [.byteStream(first, name: "a"), .byteStream(second, name: "b")],
                            protocols: [TestEchoProtocol(probe: probe)], handler: NoContentHandler())
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            #expect(try await server.waitUntilRunning() == [first.address, second.address])

            let a = await first.connect()
            let b1 = await second.connect()
            let b2 = await second.connect()
            #expect(await roundTrip(a, "a") == "a")
            #expect(await roundTrip(b1, "b1") == "b1")
            #expect(await roundTrip(b2, "b2") == "b2")
            // The limit is shared: a fourth connection on the first listener is refused.
            let refused = await first.connect()
            #expect(await roundTrip(refused, "x") == "")

            let stats = server.listenerStatistics
            #expect(stats.map(\.name) == ["a", "b"])
            #expect(stats.map(\.address) == [first.address, second.address])
            #expect(stats.map(\.accepted) == [1, 2])
            #expect(stats.map(\.open) == [1, 2])
            #expect(stats.map(\.refused) == [1, 0])
            #expect(server.openConnectionCount == 3)

            await server.shutdown()
            try await group.waitForAll()
        }
        #expect(first.isClosed && second.isClosed)
        #expect(server.listenerStatistics.map(\.open) == [0, 0])
    }

    /// Startup fails as a whole: a listener that cannot bind closes the ones bound before it,
    /// and `run()` throws.
    @Test(.timeLimit(.minutes(1)))
    func aListenerThatCannotBindClosesTheOthers() async throws {
        let first = InMemoryListener()
        let failing = InMemoryListener(failure: TransportError.failed(code: 48))
        let server = Server(listeners: [.byteStream(first, name: "http"), .byteStream(failing, name: "https")],
                            protocols: [TestEchoProtocol(probe: Probe())], handler: NoContentHandler())
        await #expect(throws: TransportError.failed(code: 48)) { try await server.run() }
        #expect(first.isClosed)
        #expect(server.lifecycleState == .failed)
    }

    /// Listeners made at bind time see the addresses bound before them and the ALPN tokens to
    /// offer: the registry's for byte streams, the protocol's own for multiplexed listeners.
    @Test(.timeLimit(.minutes(1)))
    func bindTimeListenersGetAddressesAndALPN() async throws {
        let seen = Mutex<[ServerListener.BindContext]>([])
        let first = InMemoryListener(address: TransportAddress(host: "memory", port: 7))
        let late = InMemoryListener(address: TransportAddress(host: "memory", port: 8))
        let server = Server(listeners: [
            .byteStream(first, name: "first"),
            .byteStream(name: "late") { bind in
                seen.withLock { $0.append(bind) }
                return late
            },
        ], protocols: [HTTP1(), TestEchoProtocol(probe: Probe())], handler: NoContentHandler())
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            #expect(try await server.waitUntilRunning() == [first.address, late.address])
            await server.shutdown()
            try await group.waitForAll()
        }
        let contexts = seen.withLock { $0 }
        #expect(contexts.count == 1)
        #expect(contexts.first?.boundAddresses == [first.address])
        #expect(contexts.first?.alpnTokens == ["http/1.1", "echo"])
    }

    // MARK: Cleartext, TLS and QUIC on loopback

    struct SlowHandler: HTTPHandler {
        let started: ShutdownSignal

        func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
            let path = request.string(of: request.path)
            if path == "/slow" {
                started.trigger()
                try await Task.sleep(for: .milliseconds(1500))
            }
            let alpn = context.connection.negotiatedALPN ?? "none"
            var body = ByteBuffer()
            body.append(contentsOf: Array("\(path) secure=\(context.connection.isSecure) alpn=\(alpn)".utf8))
            return HTTPResponse(body: .bytes(body))
        }
    }

    /// Cleartext (BSD sockets), TLS (Network.framework, ALPN from the registry) and HTTP/3 on
    /// the TLS port number (UDP), one `Server`: curl gets an answer from each, and a shutdown
    /// during a slow HTTP/3 request lets it finish (GOAWAY) before `run()` returns.
    @Test(.timeLimit(.minutes(1)), .enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/opt/curl/bin/curl")))
    func cleartextTLSAndHTTP3ServeTogetherAndDrain() async throws {
        let material = try TestIdentity.load()
        let identity = try TLSIdentity(pkcs12: material.pkcs12, password: TestIdentity.password)
        let tcp = TCPConfiguration(allowLocalEndpointReuse: false)
        let started = ShutdownSignal()
        let server = Server(configuration: ServerConfiguration(drainTimeout: .seconds(10)), listeners: [
            .byteStream(try BSDSocketListener(configuration: .init(host: "127.0.0.1", port: 0, tcp: tcp)), name: "http"),
            .byteStream(name: "https") { bind in
                try TCPListener(configuration: .init(host: "127.0.0.1", port: 0, tcp: tcp),
                                tls: TLSConfiguration(identity: identity, alpn: bind.alpnTokens))
            },
            .multiplexed(name: "h3", protocol: HTTP3()) { bind in
                try QUICListener(configuration: .init(host: "127.0.0.1", port: bind.boundAddresses[1].port,
                                                      quic: QUICConfiguration(alpn: bind.alpnTokens)),
                                 identity: identity)
            },
        ], protocols: [HTTP1()], handler: SlowHandler(started: started))

        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            defer { server.requestShutdown() }
            let addresses = try await server.waitUntilRunning()
            #expect(addresses.count == 3)
            let (http, https, h3) = (addresses[0].port, addresses[1].port, addresses[2].port)
            #expect(https == h3, "TCP and UDP share the port number")

            let h3Curl = URL(fileURLWithPath: "/opt/homebrew/opt/curl/bin/curl")
            var output = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"),
                                                    ["-sS", "--max-time", "10", "http://127.0.0.1:\(http)/a"])
            #expect(output.stdout == "/a secure=false alpn=none", "\(output.stderr)")
            output = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"),
                                                ["-sSk", "--max-time", "10", "https://127.0.0.1:\(https)/b"])
            #expect(output.stdout == "/b secure=true alpn=http/1.1", "\(output.stderr)")
            output = try await ChildProcess.run(h3Curl, ["-sSk", "--http3-only", "--max-time", "10",
                                                         "https://127.0.0.1:\(h3)/c"])
            #expect(output.stdout == "/c secure=true alpn=h3", "\(output.stderr)")
            #expect(server.listenerStatistics.map(\.accepted) == [1, 1, 1])

            // A shutdown while an HTTP/3 request is in flight: GOAWAY, the request finishes.
            let slow = try ChildProcess(executable: h3Curl, arguments: [
                "-sSk", "--http3-only", "--max-time", "15", "-w", " %{http_code}", "https://127.0.0.1:\(h3)/slow"])
            defer { slow.kill() }
            await started.wait()
            server.requestShutdown()
            #expect(try await slow.waitForExit(timeout: .seconds(20)) == 0)
            #expect(slow.stdout == "/slow secure=true alpn=h3 200", "\(slow.stderr)")
            try await group.waitForAll()
        }
        #expect(server.lifecycleState == .stopped)
        #expect(server.openConnectionCount == 0)
    }
}
