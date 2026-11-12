@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0056: one in-memory test per published HTTP/2 denial-of-service pattern, each asserting
/// the exact response.
@Suite(.timeLimit(.minutes(1)))
struct H2AbuseTests {
    /// Everything off except what a test turns on.
    static func limits(
        resets: Int? = nil, control: Int? = nil, empty: Int? = nil, windowUpdates: Int? = nil, smallFrames: Int? = nil,
        stall: Duration? = nil, streams: Int? = nil
    ) -> HTTP2AbuseLimits {
        HTTP2AbuseLimits(
            maxResetStreamsPerWindow: resets, maxControlFramesPerWindow: control, maxEmptyFramesPerWindow: empty,
            maxWindowUpdatesPerWindow: windowUpdates, maxSmallDataFramesPerWindow: smallFrames, windowStallTimeout: stall,
            maxStreamsPerConnection: streams)
    }

    static func config(_ limits: HTTP2AbuseLimits, maxConcurrentStreams: Int = 100) -> HTTP2Configuration {
        HTTP2Configuration(maxConcurrentStreams: maxConcurrentStreams, abuseLimits: limits)
    }

    /// Reads until GOAWAY (or the end) and returns its code.
    static func goawayCode(_ client: inout H2Client) async throws -> (HTTP2ErrorCode?, [H2Frame]) {
        let frames = try await client.frames(until: \.isGoaway)
        guard case .goaway(_, let code, _) = frames.last else { return (nil, frames) }
        return (code, frames)
    }

    // MARK: Monitor

    @Test func monitorCountsInAFixedWindow() {
        var monitor = HTTP2AbuseMonitor(limits: Self.limits(resets: 2))
        let start = ContinuousClock.now
        let results = [
            monitor.record(.resetStreams, now: start),
            monitor.record(.resetStreams, now: start + .seconds(1)),
            monitor.record(.resetStreams, now: start + .seconds(2)),
            // A new window starts after 10 s.
            monitor.record(.resetStreams, now: start + .seconds(11)),
            // Unlimited kinds never trip.
            monitor.record(.controlFrames, amount: 1_000_000, now: start),
        ]
        #expect(results == [true, true, false, true, true])
        #expect(monitor.count(.resetStreams) == 1)
    }

    // MARK: Rapid reset (CVE-2023-44487)

    @Test func rapidResetIsEnhanceYourCalm() async throws {
        try await withH2Driver(configuration: Self.config(Self.limits(resets: 10)), handler: H2ResetTests.SleepingHandler()) { client, driver in
            try await client.handshake()
            var frames: [ByteBuffer] = []
            for i in 0..<11 {
                let stream = UInt32(2 * i + 1)
                frames.append(F.headers(stream, block: client.requests.get("/sleep")))
                frames.append(H2ResetTests.rst(stream))
            }
            try await client.transport.send(F.join(frames), endOfStream: false)
            let (code, seen) = try await Self.goawayCode(&client)
            #expect(code == .enhanceYourCalm, "\(seen)")
            // Every handler is cancelled and the tasks end.
            for _ in 0..<200 where driver.liveStreamTasks > 0 { try await Task.sleep(for: .milliseconds(5)) }
            #expect(driver.liveStreamTasks == 0)
        }
    }

    /// Streams refused over MAX_CONCURRENT_STREAMS count like resets.
    @Test func refusedStreamFloodIsEnhanceYourCalm() async throws {
        let config = Self.config(Self.limits(resets: 10), maxConcurrentStreams: 1)
        try await withH2Connection(configuration: config, handler: H2ResetTests.SleepingHandler()) { client in
            try await client.handshake()
            var frames: [ByteBuffer] = []
            for i in 0..<12 { frames.append(F.headers(UInt32(2 * i + 1), block: client.requests.get("/sleep"))) }
            try await client.transport.send(F.join(frames), endOfStream: false)
            let (code, seen) = try await Self.goawayCode(&client)
            #expect(code == .enhanceYourCalm, "\(seen)")
            #expect(seen.filter { if case .rstStream(_, .refusedStream) = $0 { return true }; return false }.count == 10)
        }
    }

    /// Handlers of reset streams still being cancelled count against twice
    /// MAX_CONCURRENT_STREAMS: past it new streams are refused.
    @Test func runningHandlersBoundNewStreams() {
        var shared = HTTP2SharedState(configuration: Self.config(Self.limits(), maxConcurrentStreams: 2))
        var wakeups = HTTP2Wakeups()
        _ = shared.handle(.start, wakeups: &wakeups)
        _ = shared.handle(.settings(HTTP2Settings()), wakeups: &wakeups)
        for i in 0..<4 {
            let id = HTTP2StreamID(UInt32(2 * i + 1))
            #expect(shared.handle(.headers(streamID: id, endStream: true, trailers: false), wakeups: &wakeups)
                    == .dispatch(streamID: id, endStream: true))
            // The client resets it; its task (not tracked here) is still ending.
            _ = shared.handle(.rstStream(streamID: id, .cancel), wakeups: &wakeups)
        }
        #expect(shared.machine.streams.activeCount == 0)
        #expect(shared.activeStreams == 4)
        let ninth = HTTP2StreamID(9)
        #expect(shared.handle(.headers(streamID: ninth, endStream: true, trailers: false), wakeups: &wakeups)
                == .resetStream(streamID: ninth, .refusedStream, windowIncrement: nil))
        shared.streamEnded(HTTP2StreamID(1), wakeups: &wakeups)
        let eleventh = HTTP2StreamID(11)
        #expect(shared.handle(.headers(streamID: eleventh, endStream: true, trailers: false), wakeups: &wakeups)
                == .dispatch(streamID: eleventh, endStream: true))
    }

    // MARK: CONTINUATION flood (VU#421644)

    @Test func continuationFloodIsEnhanceYourCalm() async throws {
        try await withH2Connection(configuration: Self.config(Self.limits())) { client in
            try await client.handshake()
            let block = client.requests.get("/")
            var frames = [F.headers(1, block: [block[0]], endStream: true, endHeaders: false)]
            // One byte per CONTINUATION: the 33rd crosses `maxContinuationFrames` (32).
            for i in 1...33 {
                let byte: [UInt8] = [i < block.count ? block[i] : 0x82]
                frames.append(F.raw(type: .continuation, streamID: 1, payload: byte))
            }
            try await client.transport.send(F.join(frames), endOfStream: false)
            let (code, seen) = try await Self.goawayCode(&client)
            #expect(code == .enhanceYourCalm, "\(seen)")
        }
    }

    // MARK: Control-frame floods

    @Test func pingFloodIsEnhanceYourCalm() async throws {
        try await withH2Connection(configuration: Self.config(Self.limits(control: 50))) { client in
            try await client.handshake()
            try await client.send(F.join((0..<51).map { F.ping(UInt64($0)) }))
            let (code, seen) = try await Self.goawayCode(&client)
            #expect(code == .enhanceYourCalm)
            // The client's SETTINGS was the first counted frame: 49 PINGs fit, the 50th is over.
            #expect(seen.filter { if case .ping(true, _) = $0 { return true }; return false }.count == 49)
        }
    }

    @Test func settingsFloodIsEnhanceYourCalm() async throws {
        try await withH2Connection(configuration: Self.config(Self.limits(control: 50))) { client in
            // The client's first SETTINGS counts too.
            try await client.handshake()
            try await client.send(F.join((0..<50).map { _ in F.settings() }))
            let (code, seen) = try await Self.goawayCode(&client)
            #expect(code == .enhanceYourCalm)
            // The handshake's SETTINGS and 49 more are acknowledged; the 51st is over.
            #expect(seen.filter { $0 == .settingsAck }.count == 50)
        }
    }

    @Test func priorityAndUnknownFrameFloodIsEnhanceYourCalm() async throws {
        try await withH2Connection(configuration: Self.config(Self.limits(control: 20))) { client in
            try await client.handshake()
            var frames: [ByteBuffer] = []
            for i in 0..<10 { frames.append(F.raw(type: .priority, streamID: UInt32(2 * i + 1), payload: [0, 0, 0, 0, 16])) }
            for _ in 0..<10 { frames.append(F.raw(type: HTTP2FrameType(rawValue: 0xfa), streamID: 0, payload: [1, 2, 3])) }
            // With the client's SETTINGS, the last unknown frame is the 21st counted.
            try await client.send(F.join(frames))
            let (code, _) = try await Self.goawayCode(&client)
            #expect(code == .enhanceYourCalm)
        }
    }

    // MARK: Empty frames

    @Test func emptyDataFloodIsEnhanceYourCalm() async throws {
        let gate = Gate()
        let handler = ClosureHandler { _ in
            await gate.wait()
            return HTTPResponse(status: .ok)
        }
        try await withH2Connection(configuration: Self.config(Self.limits(empty: 10)), handler: handler) { client in
            try await client.handshake()
            var frames = [F.headers(1, block: client.requests.get("/", method: "POST"), endStream: false)]
            for _ in 0..<11 { frames.append(F.data(1, [], endStream: false)) }
            try await client.transport.send(F.join(frames), endOfStream: false)
            let (code, seen) = try await Self.goawayCode(&client)
            #expect(code == .enhanceYourCalm, "\(seen)")
            gate.open()
        }
    }

    @Test func emptyHeaderFragmentFloodIsEnhanceYourCalm() async throws {
        try await withH2Connection(configuration: Self.config(Self.limits(empty: 10))) { client in
            try await client.handshake()
            var frames = [F.headers(1, block: [], endStream: true, endHeaders: false)]
            for _ in 0..<10 { frames.append(F.raw(type: .continuation, streamID: 1, payload: [])) }
            try await client.transport.send(F.join(frames), endOfStream: false)
            let (code, seen) = try await Self.goawayCode(&client)
            #expect(code == .enhanceYourCalm, "\(seen)")
        }
    }

    // MARK: WINDOW_UPDATE flood

    @Test func windowUpdateFloodIsEnhanceYourCalm() async throws {
        try await withH2Connection(configuration: Self.config(Self.limits(windowUpdates: 20))) { client in
            try await client.handshake()
            try await client.send(F.join((0..<21).map { _ in F.windowUpdate(0, 1) }))
            let (code, _) = try await Self.goawayCode(&client)
            #expect(code == .enhanceYourCalm)
        }
    }

    // MARK: Slow read

    /// A client that keeps its window at a few bytes makes the server send tiny DATA frames:
    /// past the limit, GOAWAY(ENHANCE_YOUR_CALM).
    @Test func smallWindowSlowReadIsEnhanceYourCalm() async throws {
        let handler = ClosureHandler { _ in HTTPResponse(body: .bytes(ByteBuffer(bytes: Array(repeating: 1, count: 1_000)))) }
        try await withH2Connection(configuration: Self.config(Self.limits(smallFrames: 20)), handler: handler) { client in
            try await client.handshake(HTTP2Settings(initialWindowSize: 2))
            try await client.send(F.headers(1, block: client.requests.get("/")))
            var dataFrames = 0
            var code: HTTP2ErrorCode?
            while let frame = try await client.nextFrame() {
                if case .data(1, _, _) = frame {
                    dataFrames += 1
                    try await client.send(F.windowUpdate(1, 2))
                }
                if case .goaway(_, let c, _) = frame {
                    code = c
                    break
                }
            }
            #expect(code == .enhanceYourCalm)
            #expect(dataFrames == 21)
        }
    }

    /// A stream whose window stays at zero is reset after `windowStallTimeout`.
    @Test func zeroStreamWindowStallIsReset() async throws {
        let handler = ClosureHandler { _ in HTTPResponse(body: .bytes(ByteBuffer(bytes: Array(repeating: 1, count: 100)))) }
        let config = Self.config(Self.limits(stall: .milliseconds(200)))
        try await withH2Connection(configuration: config, handler: handler) { client in
            try await client.handshake(HTTP2Settings(initialWindowSize: 0))
            let start = ContinuousClock.now
            try await client.send(F.headers(1, block: client.requests.get("/")))
            let seen = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(seen.last == .rstStream(stream: 1, .enhanceYourCalm), "\(seen)")
            #expect(ContinuousClock.now - start >= .milliseconds(200))
            // The connection still serves streams that get window.
            try await client.send(F.headers(3, block: client.requests.get("/")), F.windowUpdate(3, 100))
            #expect(try await client.response(on: 3).body.count == 100)
        }
    }

    /// A connection whose window stays at zero while a response waits is closed.
    @Test func zeroConnectionWindowStallIsEnhanceYourCalm() async throws {
        let handler = ClosureHandler { _ in HTTPResponse(body: .bytes(ByteBuffer(bytes: Array(repeating: 1, count: 100_000)))) }
        let config = Self.config(Self.limits(stall: .milliseconds(200)))
        try await withH2Connection(configuration: config, handler: handler) { client in
            try await client.handshake(HTTP2Settings(initialWindowSize: 1 << 20))
            try await client.send(F.headers(1, block: client.requests.get("/")))
            let (code, seen) = try await Self.goawayCode(&client)
            #expect(code == .enhanceYourCalm)
            let sent = seen.reduce(0) { if case .data(1, let bytes, _) = $1 { return $0 + bytes.count }; return $0 }
            #expect(sent == 65_535)
        }
    }

    // MARK: Stream-identifier exhaustion

    /// After `maxStreamsPerConnection` streams the connection shuts down gracefully: the client
    /// is told to move to a new connection, and the connection closes after the last stream.
    @Test func streamLimitShutsDownGracefully() async throws {
        try await withH2Connection(configuration: Self.config(Self.limits(streams: 3))) { client in
            try await client.handshake()
            for stream: UInt32 in [1, 3] {
                try await client.send(F.headers(stream, block: client.requests.get("/\(stream)")))
                #expect(String(decoding: try await client.response(on: stream).body, as: UTF8.self) == "hello /\(stream)")
            }
            // The third stream reaches the limit: it is still served, and the shutdown starts.
            try await client.send(F.headers(5, block: client.requests.get("/5")))
            var goaways: [(UInt32, HTTP2ErrorCode)] = []
            var body: [UInt8] = []
            var ended = false
            while goaways.count < 2 || !ended, let frame = try await client.nextFrame() {
                switch frame {
                case .ping(false, let data): try await client.send(F.ping(data, ack: true))
                case .goaway(let last, let code, _): goaways.append((last, code))
                case .data(5, let bytes, let endStream):
                    body += bytes
                    ended = endStream
                default: break
                }
            }
            #expect(String(decoding: body, as: UTF8.self) == "hello /5")
            #expect(goaways.map(\.0) == [HTTP2StreamID.maxValue, 5])
            #expect(goaways.allSatisfy { $0.1 == .noError })
            // The last stream finished, so the connection closes: the client reconnects.
            let rest = try await client.framesUntilClosed()
            #expect(!rest.contains { if case .data = $0 { return true }; return false }, "\(rest)")
        }
    }

    // MARK: Slow preface

    /// A client that never sends the preface is closed after `settingsTimeout`.
    @Test func slowPrefaceIsClosed() async throws {
        let config = HTTP2Configuration(settingsTimeout: .milliseconds(200))
        try await withH2Connection(configuration: config) { client in
            try await client.send(ByteBuffer(bytes: Array("PRI * HTTP/2.0\r\n".utf8)))
            let frames = try await client.framesUntilClosed()
            guard case .settings = frames.first, case .goaway(_, .settingsTimeout, _) = frames.last else {
                Issue.record("\(frames)")
                return
            }
        }
    }
}
