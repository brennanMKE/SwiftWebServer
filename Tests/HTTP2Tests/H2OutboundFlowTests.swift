@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0054: outbound flow control. Response writers wait for send window in a fair queue and
/// are woken one at a time, only when they can proceed.
@Suite(.timeLimit(.minutes(1)))
struct H2OutboundFlowTests {
    static func id(_ value: UInt32) -> HTTP2StreamID { HTTP2StreamID(value) }

    /// Shared state with the peer's `settings`, streams 1, 3, 5, … dispatched and their heads
    /// sent, and a queue large enough that only flow control makes writers wait.
    static func shared(streams: Int, peer settings: HTTP2Settings = HTTP2Settings(initialWindowSize: 1 << 20))
        -> HTTP2SharedState
    {
        var shared = HTTP2SharedState(configuration: HTTP2Configuration(outboundQueueSize: 1 << 22))
        var wakeups = HTTP2Wakeups()
        _ = shared.handle(.start, wakeups: &wakeups)
        _ = shared.handle(.settings(settings), wakeups: &wakeups)
        for i in 0..<streams {
            let stream = id(UInt32(2 * i + 1))
            _ = shared.handle(.headers(streamID: stream, endStream: true, trailers: false), wakeups: &wakeups)
            // Incremental (RFC 9218, #0065): streams of one urgency take turns frame by frame.
            shared.openPriority(stream, HTTPPriority(incremental: true))
            _ = shared.sendHeaders(streamID: stream, status: .ok, headers: HTTPFields(), contentLength: nil,
                                   endStream: false, wakeups: &wakeups)
        }
        return shared
    }

    static let chunk = ByteBuffer(bytes: Array(repeating: 7, count: 16_384))

    // MARK: Shared state

    /// The connection window is the contended resource: each WINDOW_UPDATE wakes exactly one
    /// writer, and a writer that sent goes to the back of the queue.
    @Test func connectionWindowIsSharedRoundRobin() {
        var shared = Self.shared(streams: 3)
        var wakeups = HTTP2Wakeups()
        // Stream 1 uses up the connection window (65,535): three full frames and a short one.
        var sent = 0
        var step = shared.sendData(streamID: Self.id(1), bytes: Self.chunk, endStream: false, wakeups: &wakeups)
        while case .sent(let length, _) = step {
            sent += length
            step = shared.sendData(streamID: Self.id(1), bytes: Self.chunk, endStream: false, wakeups: &wakeups)
        }
        #expect(sent == 65_535)
        guard case .wait(let one) = step,
              case .wait(let three) = shared.sendData(streamID: Self.id(3), bytes: Self.chunk, endStream: false, wakeups: &wakeups),
              case .wait(let five) = shared.sendData(streamID: Self.id(5), bytes: Self.chunk, endStream: false, wakeups: &wakeups)
        else {
            Issue.record("writers did not wait")
            return
        }
        #expect(shared.fairQueue == [one, three, five])

        // One update: only the first writer wakes (no thundering herd).
        wakeups = HTTP2Wakeups()
        _ = shared.handle(.windowUpdate(streamID: .connection, increment: 16_384), wakeups: &wakeups)
        #expect(shared.granted == one)
        #expect(shared.sendWaiters.values.filter(\.woken).count == 1)
        #expect(shared.sendData(streamID: Self.id(1), bytes: Self.chunk, endStream: false, ticket: one, wakeups: &wakeups)
                == .sent(length: 16_384, endStream: false))
        // Stream 1 comes back for more: behind 3 and 5.
        guard case .wait(let oneAgain) = shared.sendData(streamID: Self.id(1), bytes: Self.chunk, endStream: false, wakeups: &wakeups) else {
            Issue.record("stream 1 overtook")
            return
        }
        #expect(shared.fairQueue.suffix(1) == [oneAgain])
        #expect(shared.granted == nil)

        _ = shared.handle(.windowUpdate(streamID: .connection, increment: 16_384), wakeups: &wakeups)
        #expect(shared.granted == three)
        #expect(shared.sendData(streamID: Self.id(3), bytes: Self.chunk, endStream: false, ticket: three, wakeups: &wakeups)
                == .sent(length: 16_384, endStream: false))
        _ = shared.handle(.windowUpdate(streamID: .connection, increment: 16_384), wakeups: &wakeups)
        #expect(shared.granted == five)
    }

    /// A writer whose own stream window is closed waits for its stream only: connection
    /// updates do not wake it, a WINDOW_UPDATE on its stream does.
    @Test func streamWindowWaitersWakeOnlyForTheirStream() {
        var shared = Self.shared(streams: 2, peer: HTTP2Settings(initialWindowSize: 10))
        var wakeups = HTTP2Wakeups()
        #expect(shared.sendData(streamID: Self.id(1), bytes: Self.chunk, endStream: false, wakeups: &wakeups)
                == .sent(length: 10, endStream: false))
        guard case .wait(let one) = shared.sendData(streamID: Self.id(1), bytes: Self.chunk, endStream: false, wakeups: &wakeups) else {
            Issue.record("did not wait")
            return
        }
        #expect(shared.streamWaiters[1] == one)
        _ = shared.handle(.windowUpdate(streamID: .connection, increment: 100_000), wakeups: &wakeups)
        _ = shared.handle(.windowUpdate(streamID: Self.id(3), increment: 100), wakeups: &wakeups)
        #expect(shared.sendWaiters[one]?.woken == false)
        _ = shared.handle(.windowUpdate(streamID: Self.id(1), increment: 5), wakeups: &wakeups)
        #expect(shared.sendWaiters[one]?.woken == true)
        #expect(shared.sendData(streamID: Self.id(1), bytes: Self.chunk, endStream: false, ticket: one, wakeups: &wakeups)
                == .sent(length: 5, endStream: false))
    }

    /// A cancelled writer gives its turn to the next one.
    @Test func cancelledWriterPassesItsTurnOn() {
        var shared = Self.shared(streams: 2)
        var wakeups = HTTP2Wakeups()
        var step = shared.sendData(streamID: Self.id(1), bytes: Self.chunk, endStream: false, wakeups: &wakeups)
        while case .sent = step {
            step = shared.sendData(streamID: Self.id(1), bytes: Self.chunk, endStream: false, wakeups: &wakeups)
        }
        guard case .wait(let one) = step,
              case .wait(let three) = shared.sendData(streamID: Self.id(3), bytes: Self.chunk, endStream: false, wakeups: &wakeups)
        else {
            Issue.record("writers did not wait")
            return
        }
        _ = shared.handle(.windowUpdate(streamID: .connection, increment: 100), wakeups: &wakeups)
        #expect(shared.granted == one)
        shared.cancelWaiter(one, wakeups: &wakeups)
        #expect(shared.granted == three)
        #expect(shared.sendWaiters[one] == nil)
    }

    /// A reset stream's writer is woken at once wherever it waits, and its retry drops.
    @Test func resetWakesTheStreamsWriter() {
        var shared = Self.shared(streams: 1, peer: HTTP2Settings(initialWindowSize: 0))
        var wakeups = HTTP2Wakeups()
        guard case .wait(let one) = shared.sendData(streamID: Self.id(1), bytes: Self.chunk, endStream: false, wakeups: &wakeups) else {
            Issue.record("did not wait")
            return
        }
        _ = shared.handle(.rstStream(streamID: Self.id(1), .cancel), wakeups: &wakeups)
        #expect(shared.sendWaiters[one]?.woken == true)
        #expect(shared.sendData(streamID: Self.id(1), bytes: Self.chunk, endStream: false, ticket: one, wakeups: &wakeups) == .dropped)
        #expect(shared.sendWaiters.isEmpty)
    }

    @Test func windowOverflowIsAFlowControlErrorAtTheRightLevel() {
        var machine = HTTP2Connection()
        _ = machine.handle(.start)
        _ = machine.handle(.settings(HTTP2Settings()))
        _ = machine.handle(.headers(streamID: Self.id(1), endStream: true, trailers: false))
        #expect(machine.handle(.windowUpdate(streamID: Self.id(1), increment: HTTP2Settings.maxWindowSize))
                == .resetStream(streamID: Self.id(1), .flowControlError, windowIncrement: nil))
        #expect(!machine.isFailed)
        guard case .goaway(_, let error) = machine.handle(.windowUpdate(streamID: .connection, increment: HTTP2Settings.maxWindowSize)) else {
            Issue.record("no GOAWAY")
            return
        }
        #expect(error.code == .flowControlError)
    }

    // MARK: Connections

    /// The acceptance test: the client advertises a 1-byte window and opens it slowly; the
    /// file arrives intact, each DATA frame within the window.
    @Test func oneByteWindowDeliversTheBodyIntact() async throws {
        let body = (0..<3_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        let handler = ClosureHandler { _ in HTTPResponse(body: .bytes(ByteBuffer(bytes: body))) }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake(HTTP2Settings(initialWindowSize: 1))
            try await client.send(F.headers(1, block: client.requests.get("/file")))
            var window = 1
            var received: [UInt8] = []
            var frames = 0
            var increment = 1
            while received.count < body.count, let frame = try await client.nextFrame() {
                guard case .data(1, let bytes, let endStream) = frame else { continue }
                frames += 1
                #expect(bytes.count <= window, "DATA of \(bytes.count) bytes in a \(window)-byte window")
                window -= bytes.count
                received += bytes
                if endStream { break }
                if window == 0 {
                    // Open the window slowly: 1, 2, 4, … bytes, at most 256 at a time.
                    try await client.send(F.windowUpdate(1, UInt32(increment)))
                    window += increment
                    increment = Swift.min(increment * 2, 256)
                }
            }
            #expect(received == body)
            #expect(frames > 10)
        }
    }

    /// A large and a small response share a closed connection window: once the small one
    /// queues, the two take turns frame by frame. Both ask for `priority: i` (#0065): at the
    /// default, non-incremental, they would go one at a time.
    @Test func largeAndSmallStreamsProgressTogether() async throws {
        let large = ByteBuffer(bytes: Array(repeating: 1, count: 1 << 20))
        let small = ByteBuffer(bytes: Array(repeating: 3, count: 20_000))
        let handler = ClosureHandler { request in
            HTTPResponse(body: .bytes(request.string(of: request.path) == "/large" ? large : small))
        }
        try await withH2Driver(handler: handler) { client, driver in
            try await client.handshake(HTTP2Settings(initialWindowSize: 1 << 20))
            try await client.send(F.headers(1, block: client.requests.get("/large", extra: [("priority", "i")])))
            // The large response uses up the 65,535-byte connection window.
            var largeBytes = 0
            while largeBytes < 65_535, let frame = try await client.nextFrame() {
                if case .data(1, let bytes, _) = frame { largeBytes += bytes.count }
            }
            #expect(largeBytes == 65_535)
            try await client.send(F.headers(3, block: client.requests.get("/small", extra: [("priority", "i")])))
            // Wait until both writers queue for the connection window.
            for _ in 0..<400 where driver.state.withLock({ $0.fairQueue.count }) < 2 {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(driver.state.withLock { $0.fairQueue.count } == 2)

            var order: [(stream: UInt32, bytes: Int)] = []
            var smallDone = false
            for _ in 0..<4 {
                try await client.send(F.windowUpdate(0, 16_384))
                var round = 0
                while round < 16_384, !(smallDone && round > 0), let frame = try await client.nextFrame() {
                    guard case .data(let stream, let bytes, let endStream) = frame else { continue }
                    order.append((stream, bytes.count))
                    round += bytes.count
                    if stream == 3 && endStream { smallDone = true }
                }
            }
            #expect(smallDone, "\(order)")
            #expect(order.prefix(4).map(\.stream) == [1, 3, 1, 3], "\(order)")
        }
    }

    /// INITIAL_WINDOW_SIZE changes move open streams' windows, below zero and back (§6.9.2).
    @Test func initialWindowSizeChangeAdjustsOpenStreams() async throws {
        let body = Array(repeating: UInt8(5), count: 1_000)
        let handler = ClosureHandler { _ in HTTPResponse(body: .bytes(ByteBuffer(bytes: body))) }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake(HTTP2Settings(initialWindowSize: 100))
            try await client.send(F.headers(1, block: client.requests.get("/")))
            var sizes: [Int] = []
            func nextData(_ client: inout H2Client) async throws -> Int? {
                while let frame = try await client.nextFrame() {
                    if case .data(1, let bytes, _) = frame { return bytes.count }
                }
                return nil
            }
            sizes.append(try #require(try await nextData(&client)))
            // 100 - 100 - 50 = -50: nothing may be sent.
            try await client.send(F.settings(HTTP2Settings(initialWindowSize: 50)))
            _ = try await client.frames(until: { $0 == .settingsAck })
            try await client.send(F.windowUpdate(1, 60))
            sizes.append(try #require(try await nextData(&client)))
            // +950: the rest fits.
            try await client.send(F.settings(HTTP2Settings(initialWindowSize: 1_000)))
            sizes.append(try #require(try await nextData(&client)))
            #expect(sizes == [100, 10, 890])
        }
    }

    @Test func zeroIncrementIsAProtocolError() async throws {
        let gate = Gate()
        let handler = ClosureHandler { _ in
            await gate.wait()
            return HTTPResponse(status: .ok)
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            let zero: [UInt8] = [0, 0, 0, 0]
            try await client.send(F.headers(1, block: client.requests.get("/")), F.raw(type: .windowUpdate, streamID: 1, payload: zero))
            let seen = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(seen.last == .rstStream(stream: 1, .protocolError), "\(seen)")
            try await client.send(F.raw(type: .windowUpdate, streamID: 0, payload: zero))
            let closing = try await client.frames(until: \.isGoaway)
            guard case .goaway(_, let code, _) = closing.last else {
                Issue.record("no GOAWAY: \(closing)")
                return
            }
            #expect(code == .protocolError)
            gate.open()
        }
    }
}
