@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0052: GOAWAY for connection errors and graceful shutdown (RFC 9113 §6.8), and the
/// lingering close.
@Suite(.timeLimit(.minutes(1)))
struct H2GoawayTests {
    static let maxStream = HTTP2StreamID.maxValue

    // MARK: State machine

    static func ready() -> HTTP2Connection {
        var machine = HTTP2Connection()
        _ = machine.handle(.start)
        _ = machine.handle(.settings(HTTP2Settings()))
        return machine
    }

    static func id(_ value: UInt32) -> HTTP2StreamID { HTTP2StreamID(value) }

    @Test func shutdownSendsTwoGoaways() {
        var machine = Self.ready()
        _ = machine.handle(.headers(streamID: Self.id(1), endStream: true, trailers: false))
        #expect(machine.handle(.shutdown) == .gracefulGoaway(lastStreamID: Self.id(Self.maxStream), final: false))
        #expect(machine.handle(.shutdown) == .none)
        // Streams in flight before the client saw the first GOAWAY are still served.
        #expect(machine.handle(.headers(streamID: Self.id(3), endStream: false, trailers: false))
                == .dispatch(streamID: Self.id(3), endStream: false))
        #expect(machine.handle(.finishShutdown) == .gracefulGoaway(lastStreamID: Self.id(3), final: true))
        #expect(machine.handle(.finishShutdown) == .none)
        // Above the last stream: new streams are refused, other frames ignored.
        #expect(machine.handle(.headers(streamID: Self.id(5), endStream: true, trailers: false))
                == .resetStream(streamID: Self.id(5), .refusedStream, windowIncrement: nil))
        #expect(machine.handle(.data(streamID: Self.id(5), dataLength: 1, flowControlledLength: 1, endStream: true)) == .none)
        // At or below it, streams carry on.
        #expect(machine.handle(.data(streamID: Self.id(3), dataLength: 1, flowControlledLength: 1, endStream: true))
                == .acceptData(connectionIncrement: nil))
    }

    @Test func peerGoawayIsAnsweredWithTheFinalGoaway() {
        var machine = Self.ready()
        _ = machine.handle(.headers(streamID: Self.id(1), endStream: false, trailers: false))
        #expect(machine.handle(.goaway(lastStreamID: .connection, .noError)) == .gracefulGoaway(lastStreamID: Self.id(1), final: true))
        #expect(machine.peerGoaway?.code == .noError)
        #expect(machine.handle(.headers(streamID: Self.id(3), endStream: true, trailers: false))
                == .resetStream(streamID: Self.id(3), .refusedStream, windowIncrement: nil))
        #expect(machine.handle(.shutdown) == .none)
    }

    @Test func connectionErrorAfterShutdownKeepsTheLowerLastStream() {
        var machine = Self.ready()
        _ = machine.handle(.headers(streamID: Self.id(1), endStream: false, trailers: false))
        _ = machine.handle(.finishShutdown)
        _ = machine.handle(.headers(streamID: Self.id(5), endStream: false, trailers: false))
        guard case .goaway(let last, let error) = machine.handle(.windowUpdate(streamID: .connection, increment: 0x7fff_ffff)) else {
            Issue.record("no GOAWAY")
            return
        }
        #expect(last == Self.id(1))
        #expect(error.code == .flowControlError)
    }

    // MARK: Graceful shutdown over a connection

    /// The acceptance test: a slow download in progress when the server drains completes, a
    /// new stream is refused, and `run()` returns.
    @Test func slowDownloadFinishesDuringShutdown() async throws {
        let shutdown = ShutdownSignal()
        let handler = ClosureHandler { request in
            if request.string(of: request.path) == "/late" { return HTTPResponse(body: .bytes(ByteBuffer("late"))) }
            return HTTPResponse(body: .stream(length: 10 * 1_000) { writer in
                for _ in 0..<10 {
                    try await writer.write(ByteBuffer(bytes: Array(repeating: 0x62, count: 1_000)))
                    try await Task.sleep(for: .milliseconds(20))
                }
            })
        }
        let config = HTTP2Configuration(lingerTimeout: .milliseconds(300))
        try await withRunningDriver(configuration: config, handler: handler, shutdown: shutdown) { client, _, returned in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/slow")))
            _ = try await client.frames(until: { if case .data(1, _, _) = $0 { return true }; return false })
            shutdown.trigger()
            var frames = try await client.frames(until: { if case .ping(false, _) = $0 { return true }; return false })
            #expect(frames.contains(.goaway(last: Self.maxStream, .noError, debug: "")), "\(frames)")
            guard case .ping(false, let data)? = frames.last else { return }
            try await client.send(F.ping(data, ack: true))
            frames = try await client.frames(until: \.isGoaway)
            #expect(frames.last == .goaway(last: 1, .noError, debug: ""), "\(frames)")
            // A new stream is refused.
            try await client.send(F.headers(3, block: client.requests.get("/late")))
            var body = 0
            var refused = false
            var ended = false
            // The download completes, then the server closes its side.
            _ = try await client.framesUntilClosed()
            for frame in client.reader.frames {
                switch frame {
                case .data(1, let bytes, let endStream):
                    body += bytes.count
                    ended = ended || endStream
                case .rstStream(3, .refusedStream): refused = true
                case .headers(3, _, _, _): Issue.record("stream 3 was served")
                default: break
                }
            }
            #expect(ended && refused)
            #expect(body == 10_000, "\(body)")
            // The client keeps its side open: run() returns after the lingering close.
            try await Self.waitUntil(returned, timeout: .seconds(5))
        }
    }

    /// A stream the client opened before it saw the first GOAWAY is still served.
    @Test func streamInFlightDuringTheFirstGoawayIsServed() async throws {
        let shutdown = ShutdownSignal()
        try await withH2Connection(shutdown: shutdown) { client in
            try await client.handshake()
            shutdown.trigger()
            let frames = try await client.frames(until: { if case .ping(false, _) = $0 { return true }; return false })
            #expect(frames.contains(.goaway(last: Self.maxStream, .noError, debug: "")), "\(frames)")
            guard case .ping(false, let data)? = frames.last else { return }
            try await client.send(F.headers(1, block: client.requests.get("/in-flight")))
            try await client.send(F.ping(data, ack: true))
            // The final GOAWAY may come before or after the response; both arrive.
            let rest = try await client.framesUntilClosed()
            #expect(rest.contains(.goaway(last: 1, .noError, debug: "")), "\(rest)")
            #expect(rest.contains(.data(stream: 1, Array("hello /in-flight".utf8), endStream: true)), "\(rest)")
        }
    }

    /// Without a PING ACK the final GOAWAY follows after `shutdownPingTimeout`.
    @Test func unansweredPingStillEndsTheShutdown() async throws {
        let shutdown = ShutdownSignal()
        let config = HTTP2Configuration(shutdownPingTimeout: .milliseconds(50))
        try await withH2Connection(configuration: config, shutdown: shutdown) { client in
            try await client.handshake()
            shutdown.trigger()
            let frames = try await client.framesUntilClosed()
            #expect(frames.filter(\.isGoaway) == [.goaway(last: Self.maxStream, .noError, debug: ""),
                                                  .goaway(last: 0, .noError, debug: "")], "\(frames)")
        }
    }

    /// Streams still running at the drain deadline are reset with CANCEL, then the connection
    /// closes.
    @Test func drainTimeoutCancelsStreams() async throws {
        let shutdown = ShutdownSignal()
        let handler = ClosureHandler { _ in
            try await Task.sleep(for: .seconds(60))
            return HTTPResponse(status: .ok)
        }
        let config = HTTP2Configuration(shutdownPingTimeout: .milliseconds(10), drainTimeout: .milliseconds(100))
        try await withH2Connection(configuration: config, handler: handler, shutdown: shutdown) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/forever")))
            try await Task.sleep(for: .milliseconds(20))
            shutdown.trigger()
            let frames = try await client.framesUntilClosed()
            #expect(frames.contains(.goaway(last: 1, .noError, debug: "")), "\(frames)")
            #expect(frames.contains(.rstStream(stream: 1, .cancel)), "\(frames)")
        }
    }

    /// An idle connection shuts down gracefully; a running stream defers it.
    @Test func idleTimeoutShutsDownGracefully() async throws {
        let gate = Gate()
        let handler = ClosureHandler { _ in
            await gate.wait()
            return HTTPResponse(status: .ok)
        }
        let config = HTTP2Configuration(shutdownPingTimeout: .milliseconds(10), idleTimeout: .milliseconds(100))
        try await withH2Connection(configuration: config, handler: handler) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/")))
            try await Task.sleep(for: .milliseconds(250))
            let start = ContinuousClock.now
            gate.open()
            let frames = try await client.framesUntilClosed()
            #expect(ContinuousClock.now - start >= .milliseconds(90))
            let goaways = frames.filter(\.isGoaway)
            #expect(goaways == [.goaway(last: Self.maxStream, .noError, debug: ""), .goaway(last: 1, .noError, debug: "")],
                    "\(frames)")
            // The response came before the first GOAWAY: the timer waited for the stream.
            let headers = try #require(frames.firstIndex { if case .headers(1, _, _, _) = $0 { return true }; return false })
            #expect(headers < frames.firstIndex(where: \.isGoaway)!)
        }
    }

    /// A GOAWAY from the client: streams in flight finish, new ones are refused, and the
    /// server closes after the last one.
    @Test func peerGoawayDrainsTheConnection() async throws {
        let gate = Gate()
        let handler = ClosureHandler { request in
            await gate.wait()
            return HTTPResponse(body: .bytes(ByteBuffer(bytes: Array(request.string(of: request.path).utf8))))
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/first")))
            try await Task.sleep(for: .milliseconds(20))
            try await client.send(F.goaway(0, .noError))
            #expect(try await client.frames(until: \.isGoaway).last == .goaway(last: 1, .noError, debug: ""))
            try await client.send(F.headers(3, block: client.requests.get("/second")))
            #expect(try await client.frames(until: { if case .rstStream = $0 { return true }; return false }).last
                    == .rstStream(stream: 3, .refusedStream))
            gate.open()
            let response = try await client.response(on: 1)
            #expect(String(decoding: response.body, as: UTF8.self) == "/first")
            _ = try await client.framesUntilClosed()
        }
    }

    // MARK: Connection errors and lingering close

    /// A connection error sends GOAWAY with the code and debug data, then half-closes: the
    /// client reads the GOAWAY and end of stream, may keep sending (the server discards it),
    /// and `run()` returns once the client closes, without waiting for the linger timeout.
    @Test func connectionErrorClosesLingering() async throws {
        let config = HTTP2Configuration(lingerTimeout: .seconds(30))
        try await withRunningDriver(configuration: config, handler: HelloHandler()) { client, _, returned in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/")))
            _ = try await client.response(on: 1)
            try await client.send(F.windowUpdate(0, 0x7fff_ffff))
            let frames = try await client.framesUntilClosed()
            #expect(frames.last == .goaway(last: 1, .flowControlError, debug: "FLOW_CONTROL_ERROR"), "\(frames)")
            // The server still reads (and discards) what the client sends after the error.
            for _ in 0..<4 { try await client.send(F.data(1, Array(repeating: 0, count: 8_000))) }
            try await Task.sleep(for: .milliseconds(50))
            #expect(returned.value == nil, "run() returned while lingering")
            await client.transport.close(.normal)
            try await Self.waitUntil(returned, timeout: .seconds(5))
        }
    }

    /// A client that never closes: `run()` returns after the linger timeout.
    @Test func lingeringCloseIsBounded() async throws {
        let config = HTTP2Configuration(lingerTimeout: .milliseconds(200))
        try await withRunningDriver(configuration: config, handler: HelloHandler()) { client, _, returned in
            try await client.send(F.preface, F.ping(1))  // PING before SETTINGS: PROTOCOL_ERROR.
            let start = ContinuousClock.now
            let frames = try await client.framesUntilClosed()
            #expect(frames.last == .goaway(last: 0, .protocolError, debug: "PROTOCOL_ERROR"), "\(frames)")
            try await Self.waitUntil(returned, timeout: .seconds(5))
            #expect(ContinuousClock.now - start >= .milliseconds(150))
        }
    }

    // MARK: Support

    static func waitUntil(_ returned: Box<ContinuousClock.Instant>, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while returned.value == nil {
            guard ContinuousClock.now < deadline else {
                Issue.record("run() did not return")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Like `withH2Driver`, but `body` also gets a box that is set when `run()` returns, and the
    /// client is not closed before `body` ends.
    func withRunningDriver<H: HTTPHandler>(
        configuration: HTTP2Configuration, handler: H, shutdown: ShutdownSignal = ShutdownSignal(),
        _ body: (inout H2Client, HTTP2ConnectionDriver<InMemoryTransport, H>, Box<ContinuousClock.Instant>) async throws -> Void
    ) async throws {
        let (client, server) = InMemoryTransport.makePair()
        let context = ConnectionContext(info: ConnectionInfo(), shutdown: shutdown)
        let driver = HTTP2ConnectionDriver(transport: server, handler: handler, context: context, configuration: configuration)
        let returned = Box<ContinuousClock.Instant>()
        try await withThrowingTaskGroup { group in
            group.addTask {
                await driver.run()
                returned.value = .now
            }
            var h2 = H2Client(client)
            do {
                try await body(&h2, driver, returned)
            } catch {
                await client.close(.abort)
                throw error
            }
            await client.close(.normal)
            try await group.waitForAll()
        }
    }
}
