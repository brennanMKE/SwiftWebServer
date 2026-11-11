import Foundation
import Synchronization
import Testing
import HTTPCore
import HTTPTestSupport
@testable import HTTP1

// MARK: - Support

/// Records how the server closed the transport.
final class ClosingTransport<Base: ByteStreamTransport>: ByteStreamTransport {
    let base: Base
    let reason = Mutex<CloseReason?>(nil)

    init(_ base: Base) { self.base = base }

    var info: ConnectionInfo { base.info }
    var closeReason: CloseReason? { reason.withLock { $0 } }

    func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        try await base.receive(into: &buffer, maxLength: maxLength)
    }

    func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws {
        try await base.send(bytes, endOfStream: endOfStream)
    }

    func sendFile(_ region: FileRegion) async throws {
        try await base.sendFile(region)
    }

    func close(_ reason: CloseReason) async {
        self.reason.withLock { if $0 == nil { $0 = reason } }
        await base.close(reason)
    }
}

/// `/slow` answers after 300 ms, `/stream` streams five chunks 100 ms apart, `/big` is 1 MiB,
/// `/echo` returns the request body; anything else answers with its path.
struct TimeoutHandler: HTTPHandler {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        let path = request.string(of: request.path)
        switch path {
        case "/slow":
            try await Task.sleep(for: .milliseconds(300))
            return HTTPResponse(body: .bytes(buffer("slow")))
        case "/stream":
            return HTTPResponse(body: .stream(length: nil) { writer in
                for i in 0..<5 {
                    try await Task.sleep(for: .milliseconds(100))
                    try await writer.write(buffer("part\(i);"))
                }
            })
        case "/big":
            return HTTPResponse(body: .bytes(ByteBuffer(repeating: 0x61, count: 1 << 20)))
        case "/huge":
            return HTTPResponse(body: .bytes(ByteBuffer(repeating: 0x62, count: 8 << 20)))
        case "/echo":
            var body = ByteBuffer()
            for try await chunk in request.body { body.append(chunk) }
            return HTTPResponse(body: .bytes(body))
        default:
            return HTTPResponse(body: .bytes(buffer(path)))
        }
    }
}

extension ByteBuffer {
    init(repeating byte: UInt8, count: Int) {
        self.init(capacity: count)
        append(contentsOf: [UInt8](repeating: byte, count: count))
    }
}

/// Short limits so the tests run in well under a second each.
func fastTimeouts(header: Duration? = .seconds(30), idle: Duration? = .seconds(30), body: Duration? = .seconds(30),
                  send: Duration? = .seconds(30), linger: Duration? = .milliseconds(200)) -> HTTP1Configuration {
    HTTP1Configuration(timeouts: HTTP1Timeouts(header: header, idle: idle, body: body, send: send, linger: linger))
}

/// Runs HTTP/1.1 over a scripted transport; returns what was sent, how it closed, and how long
/// the connection took.
func serveTimed(_ events: [InMemoryTransport.Event], configuration: HTTP1Configuration,
                shutdown: ShutdownSignal = ShutdownSignal()
) async -> (responses: [ParsedResponse], reason: CloseReason?, elapsed: Duration) {
    let base = InMemoryTransport.scripted(events)
    let transport = ClosingTransport(base)
    let start = ContinuousClock.now
    await HTTP1(configuration: configuration).run(transport, handler: TimeoutHandler(),
                                                  context: ConnectionContext(info: base.info, shutdown: shutdown))
    let elapsed = ContinuousClock.now - start
    return (parseWire(base.sentBytes).responses, transport.closeReason, elapsed)
}

/// Reads until end of stream (or an error) and returns everything received.
func readToEnd(_ client: InMemoryTransport) async -> ByteBuffer {
    var received = ByteBuffer()
    while (try? await client.receive(into: &received, maxLength: 64 * 1024)) ?? 0 > 0 {}
    return received
}

// MARK: - Timeouts

@Suite struct HTTP1TimeoutTests {
    @Test(.timeLimit(.minutes(1)))
    func slowHeadGets408AndCloses() async {
        // Part of a head, then nothing.
        let stalled = await serveTimed([.bytes(buffer("GET / HTTP/1.1\r\nHost: x\r\n")), .delay(.seconds(30))],
                                       configuration: fastTimeouts(header: .milliseconds(200)))
        #expect(stalled.responses.map(\.status) == [408])
        #expect(stalled.responses.first?.header("connection") == "close")
        #expect(stalled.reason == .timeout)
        #expect(stalled.elapsed >= .milliseconds(200) && stalled.elapsed < .seconds(3), "\(stalled.elapsed)")

        // Slowloris: one byte every 50 ms. Progress does not extend the header limit.
        var trickle: [InMemoryTransport.Event] = []
        for byte in "GET / HTTP/1.1\r\nHost: x\r\nX-Slow: \(String(repeating: "s", count: 100))\r\n\r\n".utf8 {
            trickle.append(.bytes(ByteBuffer(repeating: byte, count: 1)))
            trickle.append(.delay(.milliseconds(50)))
        }
        let slowloris = await serveTimed(trickle, configuration: fastTimeouts(header: .milliseconds(300)))
        #expect(slowloris.responses.map(\.status) == [408])
        #expect(slowloris.reason == .timeout)
        #expect(slowloris.elapsed < .seconds(3), "\(slowloris.elapsed)")
    }

    @Test(.timeLimit(.minutes(1)))
    func idleKeepAliveConnectionClosesSilently() async {
        let afterRequest = await serveTimed([.bytes(buffer(get("/a"))), .delay(.seconds(30))],
                                            configuration: fastTimeouts(idle: .milliseconds(200)))
        #expect(afterRequest.responses.map(\.status) == [200])
        #expect(afterRequest.responses.first?.header("connection") == "keep-alive")
        #expect(afterRequest.reason == .timeout)
        #expect(afterRequest.elapsed >= .milliseconds(200) && afterRequest.elapsed < .seconds(3))

        // Legacy #0012: a client that connects and sends nothing.
        let silent = await serveTimed([.delay(.seconds(30))], configuration: fastTimeouts(idle: .milliseconds(200)))
        #expect(silent.responses.isEmpty)
        #expect(silent.reason == .timeout)
        #expect(silent.elapsed < .seconds(3))
    }

    @Test(.timeLimit(.minutes(1)))
    func bodyStallGets408ButSteadyProgressDoesNot() async {
        let head = "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n"
        let stalled = await serveTimed([.bytes(buffer(head + "abc")), .delay(.seconds(30))],
                                       configuration: fastTimeouts(body: .milliseconds(200)))
        #expect(stalled.responses.map(\.status) == [408])
        #expect(stalled.responses.first?.header("connection") == "close")
        #expect(stalled.reason == .timeout)
        #expect(stalled.elapsed < .seconds(3))

        // Each gap is shorter than the limit, the whole body is not: the limit is inactivity.
        var steady: [InMemoryTransport.Event] = [.bytes(buffer(head))]
        for byte in "0123456789".utf8 {
            steady.append(.delay(.milliseconds(60)))
            steady.append(.bytes(ByteBuffer(repeating: byte, count: 1)))
        }
        steady.append(.endOfStream)
        let progressing = await serveTimed(steady, configuration: fastTimeouts(body: .milliseconds(250)))
        #expect(progressing.responses.map(\.status) == [200])
        #expect(progressing.responses.first?.text == "0123456789")
        #expect(progressing.reason == .normal)
    }

    @Test(.timeLimit(.minutes(1)))
    func sendStallAborts() async throws {
        // The client never reads; its small pipe fills and the server's send waits.
        let (client, server) = InMemoryTransport.makePair(client: .init(bufferCapacity: 8 * 1024))
        let transport = ClosingTransport(server)
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await HTTP1(configuration: fastTimeouts(send: .milliseconds(200)))
                    .run(transport, handler: TimeoutHandler(), context: ConnectionContext(info: server.info))
            }
            try await client.send(buffer(get("/big")), endOfStream: false)
            try await group.waitForAll()
        }
        #expect(transport.closeReason == .abort)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test(.timeLimit(.minutes(1)))
    func slowButSteadyDownloadIsNotAborted() async throws {
        // The whole 8 MiB takes longer than the send limit; each 1 MiB slice does not.
        let (client, server) = InMemoryTransport.makePair(client: .init(bufferCapacity: 16 * 1024))
        let transport = ClosingTransport(server)
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await HTTP1(configuration: fastTimeouts(send: .milliseconds(400)))
                    .run(transport, handler: TimeoutHandler(), context: ConnectionContext(info: server.info))
            }
            try await client.send(buffer(get("/huge", "Connection: close\r\n")), endOfStream: false)
            var received = ByteBuffer()
            var sincePause = 0
            while true {
                let count = try await client.receive(into: &received, maxLength: 64 * 1024)
                if count == 0 { break }
                sincePause += count
                if sincePause >= 16 * 1024 {
                    sincePause = 0
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            try await group.waitForAll()
            let responses = parseWire(received).responses
            #expect(responses.map(\.status) == [200])
            #expect(responses.first?.body.count == 8 << 20)
        }
        #expect(transport.closeReason == .normal)
        #expect(ContinuousClock.now - start > .milliseconds(400), "the download was not slower than the limit")
    }

    @Test func limitsAreConvertedOnce() {
        let ticks = HTTP1TimeoutTicks(HTTP1Timeouts(header: .seconds(1), idle: nil, body: .milliseconds(1),
                                                    send: nil, linger: .seconds(2)))
        #expect(ticks.idle == 0 && ticks.send == 0)
        #expect(ticks.shortest == ticks.body)
        #expect(ticks.header > ticks.body && ticks.linger > ticks.header)
        let back = HTTP1Ticks.duration(ticks.header)
        #expect(back > .milliseconds(999) && back < .milliseconds(1001))
        #expect(HTTP1TimeoutTicks(.disabled).shortest == 0)
    }
}

// MARK: - Draining

@Suite struct HTTP1DrainTests {
    @Test(.timeLimit(.minutes(1)))
    func idleConnectionsCloseAtOnce() async throws {
        // Idle after a response: the drain closes it without waiting for the drain deadline.
        let (client, server) = InMemoryTransport.makePair()
        let transport = ClosingTransport(server)
        let signal = ShutdownSignal()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await HTTP1(configuration: fastTimeouts())
                    .run(transport, handler: TimeoutHandler(), context: ConnectionContext(info: server.info, shutdown: signal))
            }
            try await client.send(buffer(get("/a")), endOfStream: false)
            var received = ByteBuffer()
            while parseWire(received).responses.isEmpty {
                #expect(try await client.receive(into: &received, maxLength: 4096) > 0)
            }
            let start = ContinuousClock.now
            signal.trigger()
            let rest = await readToEnd(client)
            #expect(rest.isEmpty)
            try await group.waitForAll()
            #expect(ContinuousClock.now - start < .seconds(1))
        }
        #expect(transport.closeReason == .shutdown)

        // Part of a head is not a request in flight: it closes too, with no response.
        let (client2, server2) = InMemoryTransport.makePair()
        let transport2 = ClosingTransport(server2)
        let signal2 = ShutdownSignal()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await HTTP1(configuration: fastTimeouts())
                    .run(transport2, handler: TimeoutHandler(), context: ConnectionContext(info: server2.info, shutdown: signal2))
            }
            try await client2.send(buffer("GET /a HTTP/1.1\r\nHo"), endOfStream: false)
            try await Task.sleep(for: .milliseconds(50))
            signal2.trigger()
            #expect(await readToEnd(client2).isEmpty)
            try await group.waitForAll()
        }
        #expect(transport2.closeReason == .shutdown)
    }

    @Test(.timeLimit(.minutes(1)))
    func inFlightRequestFinishesWithCloseAndPipelinedRequestsGetNothing() async throws {
        let (client, server) = InMemoryTransport.makePair()
        let signal = ShutdownSignal()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await HTTP1(configuration: fastTimeouts())
                    .run(server, handler: TimeoutHandler(), context: ConnectionContext(info: server.info, shutdown: signal))
            }
            try await client.send(buffer(get("/slow") + get("/next")), endOfStream: false)
            try await Task.sleep(for: .milliseconds(100))
            signal.trigger()   // while /slow is being handled
            let responses = parseWire(await readToEnd(client)).responses
            #expect(responses.map(\.status) == [200])
            #expect(responses.first?.text == "slow")
            #expect(responses.first?.header("connection") == "close")
            try await client.send(ByteBuffer(), endOfStream: true)
            try await group.waitForAll()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func inFlightStreamedResponseFinishes() async throws {
        let (client, server) = InMemoryTransport.makePair()
        let signal = ShutdownSignal()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await HTTP1(configuration: fastTimeouts())
                    .run(server, handler: TimeoutHandler(), context: ConnectionContext(info: server.info, shutdown: signal))
            }
            try await client.send(buffer(get("/stream") + get("/next")), endOfStream: false)
            try await Task.sleep(for: .milliseconds(150))
            signal.trigger()   // mid-stream: the head already said keep-alive
            let responses = parseWire(await readToEnd(client)).responses
            #expect(responses.map(\.status) == [200])
            #expect(responses.first?.text == "part0;part1;part2;part3;part4;")
            try await client.send(ByteBuffer(), endOfStream: true)
            try await group.waitForAll()
        }
    }
}

// MARK: - Lingering close

@Suite struct HTTP1LingeringCloseTests {
    static let tooLarge = "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100000\r\n\r\n"

    @Test(.timeLimit(.minutes(1)))
    func errorResponseKeepsReadingUntilTheClientCloses() async throws {
        var configuration = fastTimeouts(linger: .seconds(20))
        configuration.maxBodySize = 1000
        let settings = configuration
        let (client, server) = InMemoryTransport.makePair()
        let transport = ClosingTransport(server)
        let finished = Atomic<Bool>(false)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await HTTP1(configuration: settings)
                    .run(transport, handler: TimeoutHandler(), context: ConnectionContext(info: server.info))
                finished.store(true, ordering: .releasing)
            }
            try await client.send(buffer(Self.tooLarge + String(repeating: "x", count: 500)), endOfStream: false)
            let responses = parseWire(await readToEnd(client)).responses
            #expect(responses.map(\.status) == [413])
            #expect(responses.first?.header("connection") == "close")
            // The response came with end of stream, but the server still reads what the client
            // was sending: no reset, and the connection stays open.
            for _ in 0..<20 {
                try await client.send(ByteBuffer(repeating: 0x78, count: 4096), endOfStream: false)
            }
            let stillOpen = !finished.load(ordering: .acquiring)
            #expect(stillOpen)
            try await client.send(ByteBuffer(), endOfStream: true)
            try await group.waitForAll()
        }
        #expect(transport.closeReason == .normal)
    }

    @Test(.timeLimit(.minutes(1)))
    func lingeringIsBounded() async throws {
        var configuration = fastTimeouts(linger: .milliseconds(200))
        configuration.maxBodySize = 1000
        let settings = configuration
        let (client, server) = InMemoryTransport.makePair()
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await HTTP1(configuration: settings)
                    .run(server, handler: TimeoutHandler(), context: ConnectionContext(info: server.info))
            }
            try await client.send(buffer(Self.tooLarge), endOfStream: false)
            #expect(parseWire(await readToEnd(client)).responses.map(\.status) == [413])
            // The client never closes: the linger limit ends the connection.
            try await group.waitForAll()
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(200) && elapsed < .seconds(3), "\(elapsed)")
    }

    @Test(.timeLimit(.minutes(1)))
    func cleanCloseDoesNotLinger() async throws {
        // `Connection: close` with nothing left unread: no reason to wait for the client.
        let (client, server) = InMemoryTransport.makePair()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await HTTP1(configuration: fastTimeouts(linger: .seconds(20)))
                    .run(server, handler: TimeoutHandler(), context: ConnectionContext(info: server.info))
            }
            try await client.send(buffer(get("/a", "Connection: close\r\n")), endOfStream: false)
            #expect(parseWire(await readToEnd(client)).responses.map(\.status) == [200])
            try await group.waitForAll()
        }
    }
}
