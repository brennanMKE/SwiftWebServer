@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0065: RFC 9218 extensible priorities. The `priority` request field and PRIORITY_UPDATE
/// frames order which stream's DATA is sent first when writers contend.
@Suite(.timeLimit(.minutes(1)))
struct H2PriorityTests {
    static func id(_ value: UInt32) -> HTTP2StreamID { HTTP2StreamID(value) }
    static let chunk = ByteBuffer(bytes: Array(repeating: 7, count: 16_384))

    /// Shared state with streams 1, 3, 5, … dispatched at `priorities` and their heads sent.
    static func shared(_ priorities: [HTTPPriority]) -> HTTP2SharedState {
        var shared = HTTP2SharedState(configuration: HTTP2Configuration(outboundQueueSize: 1 << 22))
        var wakeups = HTTP2Wakeups()
        _ = shared.handle(.start, wakeups: &wakeups)
        _ = shared.handle(.settings(HTTP2Settings(initialWindowSize: 1 << 20)), wakeups: &wakeups)
        for (i, priority) in priorities.enumerated() {
            let stream = id(UInt32(2 * i + 1))
            _ = shared.handle(.headers(streamID: stream, endStream: true, trailers: false), wakeups: &wakeups)
            shared.openPriority(stream, priority)
            _ = shared.sendHeaders(streamID: stream, status: .ok, headers: HTTPFields(), contentLength: nil,
                                   endStream: false, wakeups: &wakeups)
        }
        return shared
    }

    /// Uses up the connection window on stream 1, then queues one writer per stream, in
    /// `order`. Returns their tickets by stream.
    static func contend(_ shared: inout HTTP2SharedState, order: [UInt32]) -> [UInt32: UInt64] {
        var wakeups = HTTP2Wakeups()
        var step = shared.sendData(streamID: id(1), bytes: chunk, endStream: false, wakeups: &wakeups)
        while case .sent = step {
            step = shared.sendData(streamID: id(1), bytes: chunk, endStream: false, wakeups: &wakeups)
        }
        var tickets: [UInt32: UInt64] = [:]
        if case .wait(let one) = step { tickets[1] = one }
        for stream in order where stream != 1 {
            if case .wait(let ticket) = shared.sendData(streamID: id(stream), bytes: chunk, endStream: false, wakeups: &wakeups) {
                tickets[stream] = ticket
            }
        }
        return tickets
    }

    /// Grants `count` turns by connection WINDOW_UPDATEs of one frame each; every granted
    /// writer sends one frame and queues again. Returns the streams in the order they sent.
    static func run(_ shared: inout HTTP2SharedState, tickets: inout [UInt32: UInt64], turns: Int) -> [UInt32] {
        var order: [UInt32] = []
        var wakeups = HTTP2Wakeups()
        for _ in 0..<turns {
            _ = shared.handle(.windowUpdate(streamID: .connection, increment: 16_384), wakeups: &wakeups)
            guard let granted = shared.granted,
                  let stream = tickets.first(where: { $0.value == granted })?.key else { break }
            _ = shared.sendData(streamID: id(stream), bytes: chunk, endStream: false, ticket: granted, wakeups: &wakeups)
            order.append(stream)
            if case .wait(let again) = shared.sendData(streamID: id(stream), bytes: chunk, endStream: false, wakeups: &wakeups) {
                tickets[stream] = again
            }
        }
        return order
    }

    // MARK: Scheduler

    /// Lower urgency goes first, whatever the queue order.
    @Test func urgentStreamSendsFirst() {
        var shared = Self.shared([HTTPPriority(urgency: 5), HTTPPriority(urgency: 0), HTTPPriority(urgency: 3)])
        var tickets = Self.contend(&shared, order: [1, 3, 5])
        let order = Self.run(&shared, tickets: &tickets, turns: 6)
        #expect(order == [3, 3, 3, 3, 3, 3])
    }

    /// The default priority for every stream keeps #0054's round robin.
    @Test func equalIncrementalStreamsTakeTurns() {
        let incremental = HTTPPriority(urgency: 3, incremental: true)
        var shared = Self.shared([incremental, incremental, incremental])
        var tickets = Self.contend(&shared, order: [1, 3, 5])
        #expect(Self.run(&shared, tickets: &tickets, turns: 6) == [1, 3, 5, 1, 3, 5])
    }

    /// Non-incremental streams of one urgency go one at a time, in stream order.
    @Test func equalNonIncrementalStreamsGoOneAtATime() {
        var shared = Self.shared([.default, .default, .default])
        var tickets = Self.contend(&shared, order: [1, 5, 3])
        #expect(Self.run(&shared, tickets: &tickets, turns: 4) == [1, 1, 1, 1])
    }

    /// Urgency first, then incremental streams of that urgency interleave.
    @Test func mixedUrgenciesAndIncremental() {
        let urgentIncremental = HTTPPriority(urgency: 1, incremental: true)
        var shared = Self.shared([HTTPPriority(urgency: 6), urgentIncremental, urgentIncremental])
        var tickets = Self.contend(&shared, order: [1, 3, 5])
        #expect(Self.run(&shared, tickets: &tickets, turns: 6) == [3, 5, 3, 5, 3, 5])
    }

    /// Strict priority would starve the background stream; one turn in
    /// ``HTTP2SharedState/fairShareInterval`` goes to the oldest waiter.
    @Test func lowPriorityStillProgresses() {
        var shared = Self.shared([HTTPPriority(urgency: 7), HTTPPriority(urgency: 0)])
        var tickets = Self.contend(&shared, order: [1, 3])
        let order = Self.run(&shared, tickets: &tickets, turns: 2 * HTTP2SharedState.fairShareInterval)
        let background = order.filter { $0 == 1 }.count
        #expect(background >= 1 && background <= 2, "\(order)")
        #expect(order.prefix(HTTP2SharedState.fairShareInterval - 1).allSatisfy { $0 == 3 }, "\(order)")
    }

    // MARK: PRIORITY_UPDATE

    static func field(_ value: String) -> [UInt8] { Array(value.utf8) }

    static func update(_ shared: inout HTTP2SharedState, _ stream: UInt32, _ value: String) {
        var wakeups = HTTP2Wakeups()
        field(value).withUnsafeBytes { shared.priorityUpdate(id(stream), field: $0, wakeups: &wakeups) }
    }

    /// An update for a running stream applies at once and reorders the contended writers.
    @Test func updateAfterOpenReorders() {
        var shared = Self.shared([.default, .default])
        Self.update(&shared, 3, "u=0")
        #expect(shared.priorities[3] == HTTPPriority(urgency: 0))
        var tickets = Self.contend(&shared, order: [1, 3])
        #expect(Self.run(&shared, tickets: &tickets, turns: 2) == [3, 3])
        Self.update(&shared, 3, "u=7")
        #expect(Self.run(&shared, tickets: &tickets, turns: 2) == [1, 1])
    }

    /// An update for a stream not yet opened is kept and wins over the request's field.
    @Test func updateBeforeOpenIsKeptForTheStream() {
        var shared = Self.shared([.default])
        Self.update(&shared, 5, "u=1, i")
        #expect(shared.earlyPriorities[5] == HTTPPriority(urgency: 1, incremental: true))
        #expect(shared.priorities[5] == nil)
        var wakeups = HTTP2Wakeups()
        _ = shared.handle(.headers(streamID: Self.id(5), endStream: true, trailers: false), wakeups: &wakeups)
        shared.openPriority(Self.id(5), HTTPPriority(urgency: 6))
        #expect(shared.priorities[5] == HTTPPriority(urgency: 1, incremental: true))
        #expect(shared.earlyPriorities.isEmpty)
    }

    /// Updates for closed streams, server streams and invalid values are ignored; the early
    /// buffer is bounded.
    @Test func ignoredUpdates() {
        var shared = Self.shared([.default, .default])
        var wakeups = HTTP2Wakeups()
        shared.streamEnded(Self.id(1), wakeups: &wakeups)
        Self.update(&shared, 1, "u=0")
        #expect(shared.priorities[1] == nil && shared.earlyPriorities.isEmpty)
        Self.update(&shared, 4, "u=0")
        #expect(shared.earlyPriorities.isEmpty)
        Self.update(&shared, 3, "u=0,,")
        #expect(shared.priorities[3] == .default)
        for stream in stride(from: UInt32(101), to: 101 + 2 * UInt32(shared.maxEarlyPriorities + 10), by: 2) {
            Self.update(&shared, stream, "u=2")
        }
        #expect(shared.earlyPriorities.count == shared.maxEarlyPriorities)
    }

    // MARK: Frames

    static func priorityUpdateFrame(prioritized: UInt32, _ value: String, on stream: UInt32 = 0) -> [UInt8] {
        let payload: [UInt8] = [UInt8(prioritized >> 24), UInt8(prioritized >> 16 & 0xff), UInt8(prioritized >> 8 & 0xff),
                                UInt8(prioritized & 0xff)] + Array(value.utf8)
        let length = payload.count
        return [UInt8(length >> 16), UInt8(length >> 8 & 0xff), UInt8(length & 0xff), 0x10, 0,
                UInt8(stream >> 24), UInt8(stream >> 16 & 0xff), UInt8(stream >> 8 & 0xff), UInt8(stream & 0xff)] + payload
    }

    @Test func parserReadsPriorityUpdate() {
        let run = parse([Self.priorityUpdateFrame(prioritized: 7, "u=2, i")])
        #expect(run.frames == [.priorityUpdate(prioritized: 7, Array("u=2, i".utf8))])
        for split in 1..<12 {
            let bytes = Self.priorityUpdateFrame(prioritized: 7, "u=2")
            let chunks = [Array(bytes[..<split]), Array(bytes[split...])]
            #expect(parse(chunks).frames == [.priorityUpdate(prioritized: 7, Array("u=2".utf8))])
        }
    }

    @Test func parserRejectsInvalidPriorityUpdate() {
        #expect(parse([Self.priorityUpdateFrame(prioritized: 1, "u=1", on: 1)]).frames == [.connectionError(.protocolError)])
        #expect(parse([Self.priorityUpdateFrame(prioritized: 0, "u=1")]).frames == [.connectionError(.protocolError)])
        #expect(parse([[0, 0, 3, 0x10, 0, 0, 0, 0, 0, 0, 0, 1]]).frames == [.connectionError(.frameSizeError)])
    }

    // MARK: Connection

    /// End to end: a large response at `u=5` holds the connection window; a small one asks for
    /// `u=0` in its request; once both wait, the small one's DATA goes out first.
    @Test func urgentResponseOvertakesOverConnection() async throws {
        let large = ByteBuffer(bytes: Array(repeating: 1, count: 1 << 20))
        let small = ByteBuffer(bytes: Array(repeating: 3, count: 20_000))
        let handler = ClosureHandler { request in
            HTTPResponse(body: .bytes(request.string(of: request.path) == "/large" ? large : small))
        }
        try await withH2Driver(handler: handler) { client, driver in
            try await client.handshake(HTTP2Settings(initialWindowSize: 1 << 20))
            try await client.send(F.headers(1, block: client.requests.get("/large", extra: [("priority", "u=5")])))
            var largeBytes = 0
            while largeBytes < 65_535, let frame = try await client.nextFrame() {
                if case .data(1, let bytes, _) = frame { largeBytes += bytes.count }
            }
            try await client.send(F.headers(3, block: client.requests.get("/small", extra: [("priority", "u=0")])))
            for _ in 0..<400 where driver.state.withLock({ $0.fairQueue.count }) < 2 {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(driver.state.withLock { $0.priorities[3] } == HTTPPriority(urgency: 0))
            var order: [UInt32] = []
            var smallDone = false
            for _ in 0..<3 {
                try await client.send(F.windowUpdate(0, 16_384))
                var round = 0
                while round < 16_384, !(smallDone && round > 0), let frame = try await client.nextFrame() {
                    guard case .data(let stream, let bytes, let endStream) = frame else { continue }
                    order.append(stream)
                    round += bytes.count
                    if stream == 3 && endStream { smallDone = true }
                }
            }
            #expect(smallDone)
            #expect(order.prefix(3) == [3, 3, 1], "\(order)")
        }
    }

    /// PRIORITY_UPDATE before the stream opens reprioritizes it; one after it closed, and an
    /// update flood, behave (ignored; GOAWAY(ENHANCE_YOUR_CALM) past the control-frame limit).
    @Test func priorityUpdateFramesOverConnection() async throws {
        let gate = Gate()
        let handler = ClosureHandler { _ in
            await gate.wait()
            return HTTPResponse(status: .ok)
        }
        try await withH2Driver(handler: handler) { client, driver in
            try await client.handshake()
            try await client.send(ByteBuffer(bytes: Self.priorityUpdateFrame(prioritized: 1, "u=6, i")))
            try await client.send(F.headers(1, block: client.requests.get("/", extra: [("priority", "u=2")])))
            for _ in 0..<400 where driver.state.withLock({ $0.priorities[1] }) == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(driver.state.withLock { $0.priorities[1] } == HTTPPriority(urgency: 6, incremental: true))
            // After open.
            try await client.send(ByteBuffer(bytes: Self.priorityUpdateFrame(prioritized: 1, "u=0")))
            for _ in 0..<400 where driver.state.withLock({ $0.priorities[1] }) != HTTPPriority(urgency: 0) {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(driver.state.withLock { $0.priorities[1] } == HTTPPriority(urgency: 0))
            gate.open()
            _ = try await client.response(on: 1)
            // After close: ignored, the connection stays up.
            try await client.send(ByteBuffer(bytes: Self.priorityUpdateFrame(prioritized: 1, "u=4")))
            try await client.send(F.ping(42))
            _ = try await client.frames(until: { $0 == .ping(ack: true, 42) })
            #expect(driver.state.withLock { $0.priorities[1] == nil && $0.earlyPriorities.isEmpty })
        }
    }

    @Test func priorityUpdateFloodClosesTheConnection() async throws {
        var limits = HTTP2AbuseLimits()
        limits.maxControlFramesPerWindow = 20
        try await withH2Connection(configuration: HTTP2Configuration(abuseLimits: limits)) { client in
            try await client.handshake()
            var flood: [UInt8] = []
            for _ in 0..<30 { flood += Self.priorityUpdateFrame(prioritized: 1001, "u=1") }
            try await client.send(ByteBuffer(bytes: flood))
            let frames = try await client.framesUntilClosed()
            #expect(frames.contains { if case .goaway(_, .enhanceYourCalm, _) = $0 { true } else { false } }, "\(frames)")
        }
    }
}
