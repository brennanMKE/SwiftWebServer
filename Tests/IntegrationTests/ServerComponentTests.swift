import HTTP1
import HTTPCore
import HTTPServer
import HTTPTestSupport
import Synchronization
import Testing

// #0083: `Server`'s builder initializer and `ServerComponent` lifecycle, over in-memory
// listeners and the HTTP/1.1 runner.

/// Records a component's lifecycle.
private final class Lifecycle: Sendable {
    struct State: Sendable {
        var started = 0
        var cancelled = 0
        var addresses: [TransportAddress] = []
        /// Open connections seen when the component was cancelled.
        var openAtCancel: Int?
        var sawDraining = false
    }
    let state = Mutex(State())
    var snapshot: State { state.withLock { $0 } }
}

/// Lets a component read a server created after it.
private final class CountSource: Sendable {
    let count = Mutex<(@Sendable () -> Int)?>(nil)
}

private struct ComponentError: Error, Equatable {}

/// Runs until cancelled; records start and cancellation.
private struct Background: ServerComponent {
    let lifecycle: Lifecycle
    let openConnections: @Sendable () -> Int

    func run(server: ServerHandle) async throws {
        lifecycle.state.withLock {
            $0.started += 1
            $0.addresses = server.localAddresses
        }
        do {
            try await Task.sleep(for: .seconds(3600))
        } catch {
            let open = openConnections()
            lifecycle.state.withLock {
                $0.cancelled += 1
                $0.openAtCancel = open
                $0.sawDraining = server.draining.isTriggered
            }
            throw error
        }
    }
}

/// Fails once started.
private struct Failing: ServerComponent {
    func run(server: ServerHandle) async throws {
        try await Task.sleep(for: .milliseconds(20))
        throw ComponentError()
    }
}

/// Asks the server to stop.
private struct Stopper: ServerComponent {
    func run(server: ServerHandle) async throws {
        server.requestShutdown()
    }
}

/// A middleware that is also a component (an access log with a flusher).
private struct Tagging: HTTPMiddleware, ServerComponent {
    let tag: String
    let lifecycle: Lifecycle

    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse {
        var response = try await next.handle(request, context: context)
        response.headers.append(.via, string: tag)
        return response
    }

    func run(server: ServerHandle) async throws {
        lifecycle.state.withLock { $0.started += 1 }
        do {
            try await Task.sleep(for: .seconds(3600))
        } catch {
            lifecycle.state.withLock { $0.cancelled += 1 }
            throw error
        }
    }
}

/// Reads the start time (an access log would).
private struct Timed: HTTPMiddleware, RequestStartTimeConsumer {
    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse {
        try await next.handle(request, context: context)
    }
}

private struct Hello: HTTPHandler {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        var response = HTTPResponse()
        response.body = .bytes(ByteBuffer("hello"))
        // The runner stamps the start time when a component asked for it.
        if let start = context.startTime, start <= MonotonicInstant.now() {
            response.headers.append(.server, "stamped")
        }
        return response
    }
}

/// Sends one `Connection: close` GET and returns everything the server wrote.
private func get(_ listener: InMemoryListener) async -> String {
    let client = await listener.connect()
    var out = ByteBuffer()
    out.append("GET / HTTP/1.1\r\nHost: memory\r\nConnection: close\r\n\r\n")
    var received = ByteBuffer()
    do {
        try await client.send(out, endOfStream: false)
        while try await client.receive(into: &received, maxLength: 4096) > 0 {}
    } catch {}
    await client.close(.normal)
    return received.withReadableSpan { span in
        String(decoding: (0..<span.count).map { span[$0] }, as: UTF8.self)
    }
}

@Suite struct ServerComponentTests {
    @Test(.timeLimit(.minutes(1)))
    func builderServerServesTheChain() async throws {
        let listener = InMemoryListener()
        let lifecycle = Lifecycle()
        let compression = false
        let server = Server(listeners: [listener], protocols: [HTTP1()]) {
            Tagging(tag: "outer", lifecycle: lifecycle)
            Timed()
            if compression { Tagging(tag: "disabled", lifecycle: lifecycle) }
            Tagging(tag: "inner", lifecycle: lifecycle)
            Hello()
        }
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            _ = try await server.waitUntilRunning()
            let response = await get(listener)
            #expect(response.hasPrefix("HTTP/1.1 200"))
            #expect(response.contains("via: inner\r\nvia: outer\r\n"))
            #expect(!response.contains("disabled"))
            #expect(response.contains("server: stamped"))
            #expect(response.hasSuffix("hello"))
            // The two enabled middlewares are also components; the disabled one is absent.
            try await eventually { lifecycle.snapshot.started == 2 }
            await server.shutdown()
            try await group.waitForAll()
        }
        #expect(lifecycle.snapshot.started == 2)
        #expect(lifecycle.snapshot.cancelled == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func builderWithoutHandlerAnswers404AndHandlerInitStillWorks() async throws {
        let listener = InMemoryListener()
        let lifecycle = Lifecycle()
        let server = Server(listeners: [listener], protocols: [HTTP1()]) {
            Tagging(tag: "only", lifecycle: lifecycle)
        }
        let plainListener = InMemoryListener()
        let plain = Server(listeners: [plainListener], protocols: [HTTP1()], handler: Hello())
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            group.addTask { try await plain.run() }
            _ = try await server.waitUntilRunning()
            _ = try await plain.waitUntilRunning()
            let notFound = await get(listener)
            #expect(notFound.hasPrefix("HTTP/1.1 404"))
            #expect(notFound.contains("via: only"))
            // No component reads the start time, so none was recorded.
            let plainResponse = await get(plainListener)
            #expect(plainResponse.hasSuffix("hello"))
            #expect(!plainResponse.contains("stamped"))
            await server.shutdown()
            await plain.shutdown()
            try await group.waitForAll()
        }
    }

    /// Components start once the listeners are bound and are cancelled after the last
    /// connection closed, not when draining starts.
    @Test(.timeLimit(.minutes(1)))
    func componentsStartAfterBindingAndStopAfterTheConnections() async throws {
        let listener = InMemoryListener()
        let lifecycle = Lifecycle()
        let box = CountSource()
        let background = Background(lifecycle: lifecycle) { box.count.withLock { $0 }?() ?? -1 }
        let server = Server(configuration: ServerConfiguration(drainTimeout: .seconds(5)),
                            listeners: [listener], protocols: [HTTP1()], components: [background],
                            handler: Hello())
        box.count.withLock { $0 = { server.openConnectionCount } }
        #expect(lifecycle.snapshot.started == 0)
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            _ = try await server.waitUntilRunning()
            try await eventually { lifecycle.snapshot.started == 1 }
            #expect(lifecycle.snapshot.addresses == [listener.address])

            // An idle keep-alive connection is open while draining starts.
            let client = await listener.connect()
            #expect(await roundTripHTTP(client).hasPrefix("HTTP/1.1 200"))
            await server.shutdown()
            try await group.waitForAll()
        }
        let state = lifecycle.snapshot
        #expect(state.cancelled == 1)
        #expect(state.openAtCancel == 0)
        #expect(state.sawDraining)
        #expect(server.lifecycleState == .stopped)
    }

    @Test(.timeLimit(.minutes(1)))
    func componentFailureShutsDownAndSurfacesFromRun() async throws {
        let listener = InMemoryListener()
        let lifecycle = Lifecycle()
        let server = Server(listeners: [listener], protocols: [HTTP1()],
                            components: [Failing(), Background(lifecycle: lifecycle) { 0 }],
                            handler: Hello())
        await #expect(throws: ComponentError()) { try await server.run() }
        #expect(server.lifecycleState == .stopped)
        #expect(listener.isClosed)
        // The other component was cancelled.
        #expect(lifecycle.snapshot.started == 1)
        #expect(lifecycle.snapshot.cancelled == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func componentCanRequestShutdown() async throws {
        let listener = InMemoryListener()
        let server = Server(listeners: [listener], protocols: [HTTP1()], components: [Stopper()],
                            handler: Hello())
        try await server.run()   // returns without anyone else calling shutdown
        #expect(server.lifecycleState == .stopped)
    }

    @Test(.timeLimit(.minutes(1)))
    func componentsDoNotStartWhenStartupFails() async throws {
        struct PortInUse: Error, Equatable {}
        let lifecycle = Lifecycle()
        let server = Server(listeners: [InMemoryListener(failure: PortInUse())], protocols: [HTTP1()],
                            components: [Background(lifecycle: lifecycle) { 0 }], handler: Hello())
        await #expect(throws: PortInUse()) { try await server.run() }
        #expect(lifecycle.snapshot.started == 0)
    }
}

/// One keep-alive GET on an open connection; returns the head and body received.
private func roundTripHTTP(_ client: InMemoryTransport) async -> String {
    var out = ByteBuffer()
    out.append("GET / HTTP/1.1\r\nHost: memory\r\n\r\n")
    var received = ByteBuffer()
    do {
        try await client.send(out, endOfStream: false)
        while true {
            if try await client.receive(into: &received, maxLength: 4096) == 0 { break }
            let text = received.withReadableSpan { span in
                String(decoding: (0..<span.count).map { span[$0] }, as: UTF8.self)
            }
            if text.hasSuffix("hello") { return text }
        }
    } catch {}
    return received.withReadableSpan { span in
        String(decoding: (0..<span.count).map { span[$0] }, as: UTF8.self)
    }
}
