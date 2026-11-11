import HTTPCore
import HTTPServer
import HTTPTestSupport
import NetworkTransport
import Synchronization
import Testing

/// `Server` over in-memory listeners (#0079): connection limit, graceful drain, deadline
/// cancellation, startup failures and the #0005 shutdown races.
@Suite struct InMemoryServerTests {
    typealias MemoryServer = Server<InMemoryListener, NoContentHandler>

    func makeServer(
        _ configuration: ServerConfiguration = ServerConfiguration(drainTimeout: .seconds(5)),
        listener: InMemoryListener = InMemoryListener(),
        probe: Probe = Probe()
    ) -> MemoryServer {
        Server(configuration: configuration, listeners: [listener],
               protocols: [TestEchoProtocol(probe: probe)], handler: NoContentHandler())
    }

    @Test(.timeLimit(.minutes(1)))
    func servesUntilShutdownThenRunReturns() async throws {
        let listener = InMemoryListener()
        let probe = Probe()
        // The idle clients stay open, so shutdown cancels them at the (short) deadline.
        let server = makeServer(ServerConfiguration(drainTimeout: .milliseconds(100)), listener: listener, probe: probe)
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            #expect(try await server.waitUntilRunning() == [listener.address])
            #expect(server.lifecycleState == .running)

            let clients = [await listener.connect(), await listener.connect(), await listener.connect()]
            for (i, client) in clients.enumerated() {
                #expect(await roundTrip(client, "hello \(i)") == "hello \(i)")
            }
            #expect(server.openConnectionCount == 3)

            await server.shutdown()
            #expect(server.lifecycleState == .stopped)
            try await group.waitForAll()
        }
        // Every connection was closed and `run()` returned (#0029).
        #expect(probe.snapshot.finished == 3)
        #expect(server.openConnectionCount == 0)
        #expect(listener.isClosed)
    }

    /// `maxConnections = 2` with `.refuse`: the third connection is closed unserved while the
    /// first two are served (#0024).
    @Test(.timeLimit(.minutes(1)))
    func connectionLimitRefusesTheThirdConnection() async throws {
        let listener = InMemoryListener()
        let probe = Probe()
        let server = makeServer(
            ServerConfiguration(maxConnections: 2, connectionLimitPolicy: .refuse), listener: listener, probe: probe)
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            _ = try await server.waitUntilRunning()

            let first = await listener.connect()
            let second = await listener.connect()
            #expect(await roundTrip(first, "one") == "one")
            #expect(await roundTrip(second, "two") == "two")

            let third = await listener.connect()
            #expect(await peerClosed(third))
            #expect(server.refusedConnectionCount == 1)
            #expect(probe.snapshot.started == 2)   // no work started for the third

            // The first two are still served.
            #expect(await roundTrip(first, "again") == "again")
            #expect(await roundTrip(second, "again") == "again")

            // Room again after one closes.
            await first.close(.normal)
            try await eventually { server.openConnectionCount == 1 }
            let fourth = await listener.connect()
            #expect(await roundTrip(fourth, "four") == "four")
            #expect(server.peakConnectionCount == 2)

            for client in [second, third, fourth] { await client.close(.normal) }
            await server.shutdown()
            try await group.waitForAll()
        }
    }

    /// `.backpressure`: at the limit the server stops pulling from the listener, so the third
    /// connection waits in the listener's queue and is served once a slot frees.
    @Test(.timeLimit(.minutes(1)))
    func connectionLimitAppliesAcceptBackpressure() async throws {
        let listener = InMemoryListener()
        let probe = Probe()
        let server = makeServer(
            ServerConfiguration(maxConnections: 2, connectionLimitPolicy: .backpressure),
            listener: listener, probe: probe)
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            _ = try await server.waitUntilRunning()

            let first = await listener.connect()
            let second = await listener.connect()
            #expect(await roundTrip(first, "one") == "one")
            #expect(await roundTrip(second, "two") == "two")

            let third = await listener.connect()
            try await Task.sleep(for: .milliseconds(50))
            #expect(listener.pendingCount == 1)    // not pulled
            #expect(probe.snapshot.started == 2)
            #expect(server.refusedConnectionCount == 0)

            await first.close(.normal)
            #expect(await roundTrip(third, "three") == "three")
            #expect(listener.pendingCount == 0)
            #expect(server.peakConnectionCount == 2)
            #expect(server.openConnectionCount == 2)

            for client in [second, third] { await client.close(.normal) }
            await server.shutdown()
            try await group.waitForAll()
        }
    }

    /// Shutdown stops accepting, lets an in-flight exchange finish, then returns.
    @Test(.timeLimit(.minutes(1)))
    func shutdownDrainsInFlightConnections() async throws {
        let listener = InMemoryListener()
        let probe = Probe(gateOpen: false)
        let server = makeServer(ServerConfiguration(drainTimeout: .seconds(30)), listener: listener, probe: probe)
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            _ = try await server.waitUntilRunning()

            let client = await listener.connect()
            group.addTask {
                // In flight: the request is received but the answer waits for the gate.
                #expect(await roundTrip(client, "in flight") == "in flight")
                #expect(await peerClosed(client))
            }
            try await eventually { probe.snapshot.requests == 1 }

            let start = ContinuousClock.now
            server.requestShutdown()
            server.requestShutdown()   // double shutdown is a no-op (#0005)
            try await eventually { listener.isClosed }
            guard case .draining = server.lifecycleState else {
                Issue.record("expected draining, got \(server.lifecycleState)")
                return
            }
            // No new connections while draining.
            let late = await listener.connect()
            #expect(await peerClosed(late))

            probe.gate.trigger()
            await server.shutdown()
            #expect(ContinuousClock.now - start < .seconds(10))
            try await group.waitForAll()
        }
        #expect(probe.snapshot.sawShutdown == 1)
        #expect(probe.snapshot.cancelled == 0)
        #expect(server.lifecycleState == .stopped)
    }

    /// Connections still open at the drain deadline are cancelled.
    @Test(.timeLimit(.minutes(1)))
    func shutdownCancelsConnectionsAtTheDeadline() async throws {
        let listener = InMemoryListener()
        let probe = Probe(gateOpen: false)
        let server = makeServer(
            ServerConfiguration(drainTimeout: .milliseconds(200)), listener: listener, probe: probe)
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            _ = try await server.waitUntilRunning()

            let stuck = await listener.connect()     // its answer never comes: the gate stays shut
            let idle = await listener.connect()      // never sends anything
            var bytes = ByteBuffer()
            bytes.append(contentsOf: Array("x".utf8))
            try await stuck.send(bytes, endOfStream: false)
            try await eventually { probe.snapshot.requests == 1 && probe.snapshot.started == 2 }

            let start = ContinuousClock.now
            await server.shutdown()
            let elapsed = ContinuousClock.now - start
            #expect(elapsed >= .milliseconds(200))
            #expect(elapsed < .seconds(3))
            #expect(await peerClosed(stuck))
            #expect(await peerClosed(idle))
            try await group.waitForAll()
        }
        #expect(probe.snapshot.cancelled == 2)
        #expect(probe.snapshot.finished == 2)
        #expect(server.openConnectionCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func startupFailureThrowsOutOfRun() async throws {
        let listener = InMemoryListener(failure: TransportError.failed(code: 48))   // EADDRINUSE
        let server = makeServer(listener: listener)
        await #expect(throws: TransportError.failed(code: 48)) { try await server.run() }
        #expect(server.lifecycleState == .failed)
        await #expect(throws: TransportError.failed(code: 48)) { _ = try await server.waitUntilRunning() }
        await server.shutdown()   // after failure: returns at once
    }

    @Test(.timeLimit(.minutes(1)))
    func partialStartupFailureClosesTheListenersAlreadyBound() async throws {
        let good = InMemoryListener()
        let bad = InMemoryListener(failure: TransportError.failed(code: 48))
        let server = Server(configuration: ServerConfiguration(), listeners: [good, bad],
                            protocols: [TestEchoProtocol(probe: Probe())], handler: NoContentHandler())
        await #expect(throws: TransportError.self) { try await server.run() }
        #expect(good.isClosed)
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidConfigurationThrowsOutOfRun() async throws {
        let server = makeServer(ServerConfiguration(maxConnections: 0))
        await #expect(throws: ServerError.self) { try await server.run() }
        #expect(server.lifecycleState == .failed)

        let noProtocols = Server(configuration: ServerConfiguration(), listeners: [InMemoryListener()],
                                 protocols: [], handler: NoContentHandler())
        await #expect(throws: ServerError.noProtocols) { try await noProtocols.run() }
    }

    @Test(.timeLimit(.minutes(1)))
    func runTwiceIsRejected() async throws {
        let server = makeServer()
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            _ = try await server.waitUntilRunning()
            await #expect(throws: ServerError.alreadyStarted) { try await server.run() }
            await server.shutdown()
            try await group.waitForAll()
        }
        await #expect(throws: ServerError.alreadyStarted) { try await server.run() }
    }

    /// #0005: a shutdown requested before `run()` is not lost.
    @Test(.timeLimit(.minutes(1)))
    func shutdownBeforeRunMakesRunReturnAtOnce() async throws {
        let listener = InMemoryListener()
        let server = makeServer(listener: listener)
        await server.shutdown()
        await server.shutdown()
        try await server.run()
        #expect(server.lifecycleState == .stopped)
        #expect(listener.pendingCount == 0)
        await #expect(throws: CancellationError.self) { _ = try await server.waitUntilRunning() }
    }

    /// #0005: a shutdown while the listeners bind abandons startup; `run()` returns cleanly.
    @Test(.timeLimit(.minutes(1)))
    func shutdownWhileStartingAbandonsStartup() async throws {
        let listener = GatedListener()
        let server = Server(configuration: ServerConfiguration(), listeners: [listener],
                            protocols: [TestEchoProtocol(probe: Probe())], handler: NoContentHandler())
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            try await eventually { server.lifecycleState == .starting && listener.isListening }
            server.requestShutdown()
            #expect(server.lifecycleState == .stopped)
            listener.gate.trigger()
            try await group.waitForAll()
        }
        #expect(listener.base.isClosed)
        #expect(server.localAddresses.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingRunCancelsTheTree() async throws {
        let listener = InMemoryListener()
        let probe = Probe(gateOpen: false)
        let server = makeServer(listener: listener, probe: probe)
        let task = Task { try await server.run() }
        _ = try await server.waitUntilRunning()
        let client = await listener.connect()
        var bytes = ByteBuffer()
        bytes.append(contentsOf: Array("x".utf8))
        try await client.send(bytes, endOfStream: false)
        try await eventually { probe.snapshot.requests == 1 }
        task.cancel()
        try await task.value
        #expect(probe.snapshot.cancelled == 1)
        #expect(server.lifecycleState == .stopped)
        #expect(listener.isClosed)
    }

    /// Sniffed bytes are replayed to the protocol the registry picks.
    @Test(.timeLimit(.minutes(1)))
    func registrySniffsAndReplaysThePreface() async throws {
        let listener = InMemoryListener()
        let probe = Probe()
        let server = Server(configuration: ServerConfiguration(), listeners: [listener],
                            protocols: [NeverProtocol(), PrefixedEchoProtocol(probe: probe)],
                            handler: NoContentHandler())
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            _ = try await server.waitUntilRunning()
            let client = await listener.connect(client: .init(), server: .init(receiveChunking: .bytewise))
            #expect(await roundTrip(client, "ECHO hi") == "ECHO hi")
            let rejected = await listener.connect()
            var bytes = ByteBuffer()
            bytes.append(contentsOf: Array("nope".utf8))
            try await rejected.send(bytes, endOfStream: false)
            #expect(await peerClosed(rejected))
            await client.close(.normal)
            await server.shutdown()
            try await group.waitForAll()
        }
        #expect(probe.snapshot.started == 1)
    }
}

/// A protocol that matches nothing.
struct NeverProtocol: ConnectionProtocol {
    static var alpnTokens: [String] { [] }
    static func matchesCleartextPreface(_ bytes: borrowing ByteBuffer) -> SniffResult { .noMatch }
    func run<T: ByteStreamTransport, H: HTTPHandler>(_ t: T, handler: H, context: ConnectionContext) async {
        Issue.record("NeverProtocol must not be selected")
    }
}

/// ``TestEchoProtocol`` that is only chosen for connections starting with `ECHO`.
struct PrefixedEchoProtocol: ConnectionProtocol {
    let probe: Probe
    static var alpnTokens: [String] { [] }
    static func matchesCleartextPreface(_ bytes: borrowing ByteBuffer) -> SniffResult {
        let magic = Array("ECHO".utf8)
        let have = bytes.withReadableSpan { span in (0..<min(span.count, magic.count)).map { span[$0] } }
        guard have.elementsEqual(magic.prefix(have.count)) else { return .noMatch }
        return have.count == magic.count ? .match : .needMoreBytes
    }
    func run<T: ByteStreamTransport, H: HTTPHandler>(_ t: T, handler: H, context: ConnectionContext) async {
        await TestEchoProtocol(probe: probe).run(t, handler: handler, context: context)
    }
}

/// An in-memory listener whose `listen()` waits for a gate, to hold the server in `starting`.
final class GatedListener: TransportListener {
    let base = InMemoryListener()
    let gate = ShutdownSignal()
    private let listening = Atomic<Bool>(false)

    var isListening: Bool { listening.load(ordering: .acquiring) }

    func listen() async throws -> TransportAddress {
        listening.store(true, ordering: .releasing)
        while !gate.isTriggered { await gate.wait() }
        return try await base.listen()
    }

    var connections: InMemoryListener.Connections { base.connections }

    func close() async { await base.close() }
}

/// `Server` over the Network.framework TCP listener on 127.0.0.1 port 0 (#0079).
@Suite struct TCPServerTests {
    func makeServer(_ configuration: ServerConfiguration = ServerConfiguration(drainTimeout: .seconds(2)),
                    port: UInt16 = 0, probe: Probe = Probe()) throws -> Server<TCPListener, NoContentHandler> {
        let listener = try TCPListener(configuration: TCPListener.Configuration(
            host: "127.0.0.1", port: port, tcp: TCPConfiguration(allowLocalEndpointReuse: false)))
        return Server(configuration: configuration, listeners: [listener],
                      protocols: [TestEchoProtocol(probe: probe)], handler: NoContentHandler())
    }

    @Test(.timeLimit(.minutes(1)))
    func twoServersOnPortZeroInOneProcess() async throws {
        let first = try makeServer()
        let second = try makeServer()
        try await withThrowingTaskGroup { group in
            group.addTask { try await first.run() }
            group.addTask { try await second.run() }
            let a = try #require(try await first.waitUntilRunning().first)
            let b = try #require(try await second.waitUntilRunning().first)
            #expect(a.host == "127.0.0.1" && b.host == "127.0.0.1")
            #expect(a.port != 0 && b.port != 0 && a.port != b.port)

            for address in [a, b] {
                let client = try await TCPTransport.connect(host: address.host, port: address.port)
                #expect(await roundTrip(client, "port \(address.port)") == "port \(address.port)")
                await client.close(.normal)
            }
            async let stopFirst: Void = first.shutdown()
            async let stopSecond: Void = second.shutdown()
            _ = await (stopFirst, stopSecond)
            try await group.waitForAll()
        }
        #expect(first.lifecycleState == .stopped)
        #expect(second.lifecycleState == .stopped)
    }

    @Test(.timeLimit(.minutes(1)))
    func portAlreadyInUseThrowsOutOfRun() async throws {
        let holder = try makeServer()
        try await withThrowingTaskGroup { group in
            group.addTask { try await holder.run() }
            let address = try #require(try await holder.waitUntilRunning().first)

            let clash = try makeServer(port: address.port)
            await #expect(throws: TransportError.self) { try await clash.run() }
            #expect(clash.lifecycleState == .failed)

            await holder.shutdown()
            try await group.waitForAll()
        }
    }

    /// `maxConnections = 2` over TCP: the third connection is refused while the first two
    /// are served (issue #0079 acceptance criterion).
    @Test(.timeLimit(.minutes(1)))
    func maxConnectionsTwoRefusesTheThird() async throws {
        let server = try makeServer(ServerConfiguration(maxConnections: 2, connectionLimitPolicy: .refuse,
                                                        drainTimeout: .seconds(2)))
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            let address = try #require(try await server.waitUntilRunning().first)
            let first = try await TCPTransport.connect(host: address.host, port: address.port)
            #expect(await roundTrip(first, "one") == "one")
            let second = try await TCPTransport.connect(host: address.host, port: address.port)
            #expect(await roundTrip(second, "two") == "two")
            let third = try await TCPTransport.connect(host: address.host, port: address.port)
            #expect(await peerClosed(third))
            #expect(server.refusedConnectionCount == 1)
            #expect(await roundTrip(first, "still") == "still")
            #expect(await roundTrip(second, "still") == "still")
            for client in [first, second, third] { await client.close(.normal) }
            await server.shutdown()
            try await group.waitForAll()
        }
    }
}
