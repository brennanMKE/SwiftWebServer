@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0053: inbound flow control. Receive windows, batched WINDOW_UPDATEs as the handler
/// consumes body data, and FLOW_CONTROL_ERROR at the right level.
@Suite(.timeLimit(.minutes(1)))
struct H2InboundFlowTests {
    static let one = HTTP2StreamID(1)

    /// A machine after `start`, the peer's SETTINGS and (when `acknowledged`) the ACK of ours.
    static func machine(initialWindowSize: UInt32 = 65_535, connectionWindowSize: UInt32 = 1 << 20, acknowledged: Bool = true)
        -> HTTP2Connection
    {
        var machine = HTTP2Connection(configuration: .init(
            localSettings: HTTP2Settings(initialWindowSize: initialWindowSize), connectionWindowSize: connectionWindowSize))
        _ = machine.handle(.start)
        _ = machine.handle(.settings(HTTP2Settings()))
        if acknowledged { _ = machine.handle(.settingsAck) }
        return machine
    }

    static func data(_ id: HTTP2StreamID, _ length: Int, padding: Int = 0, endStream: Bool = false) -> HTTP2Connection.Event {
        .data(streamID: id, dataLength: length, flowControlledLength: length + padding, endStream: endStream)
    }

    // MARK: State machine

    @Test func receiveWindowBatchesCreditAtHalfTheWindow() {
        var window = HTTP2ReceiveWindow(size: 100)
        let fits = window.receive(100)
        #expect(fits)
        #expect(window.credit(49) == nil)
        #expect(window.credit(1) == 50)
        #expect(window.available == 50)
        let overflows = !window.receive(51)
        #expect(overflows)
        window.resize(to: 10)
        #expect(window.available == -91)
    }

    @Test func dataBeyondAStreamWindowResetsOnlyThatStream() {
        var machine = Self.machine()
        let three = HTTP2StreamID(3)
        _ = machine.handle(.headers(streamID: Self.one, endStream: false, trailers: false))
        _ = machine.handle(.headers(streamID: three, endStream: false, trailers: false))
        #expect(machine.handle(Self.data(Self.one, 65_535)) == .acceptData(connectionIncrement: nil))
        #expect(machine.receiveWindow(of: Self.one)?.available == 0)
        // One byte more is a stream error; the frame's connection credit is not lost.
        #expect(machine.handle(Self.data(Self.one, 1)) == .resetStream(streamID: Self.one, .flowControlError, windowIncrement: nil))
        #expect(machine.receiveWindow(of: Self.one) == nil)
        #expect(machine.pendingReceiveCredit == 1)
        #expect(!machine.isFailed)
        #expect(machine.handle(Self.data(three, 10)) == .acceptData(connectionIncrement: nil))
    }

    @Test func dataBeyondTheConnectionWindowIsAConnectionError() {
        var machine = Self.machine(initialWindowSize: 1 << 20, connectionWindowSize: 100_000)
        _ = machine.handle(.headers(streamID: Self.one, endStream: false, trailers: false))
        #expect(machine.handle(Self.data(Self.one, 100_000)) == .acceptData(connectionIncrement: nil))
        guard case .goaway(_, let error) = machine.handle(Self.data(Self.one, 1)) else {
            Issue.record("no GOAWAY")
            return
        }
        #expect(error.code == .flowControlError)
        #expect(error.isConnectionError)
    }

    @Test func consumedBytesReturnStreamAndConnectionCreditAtHalfAWindow() {
        var machine = Self.machine(connectionWindowSize: 65_535)
        _ = machine.handle(.headers(streamID: Self.one, endStream: false, trailers: false))
        _ = machine.handle(Self.data(Self.one, 40_000))
        #expect(machine.handle(.bodyConsumed(streamID: Self.one, length: 30_000)) == .none)
        #expect(machine.handle(.bodyConsumed(streamID: Self.one, length: 10_000))
                == .sendWindowUpdate(connectionIncrement: 40_000, streamID: Self.one, streamIncrement: 40_000))
        #expect(machine.receiveWindow(of: Self.one)?.available == 65_535)
        #expect(machine.connectionReceiveWindow == 65_535)
    }

    @Test func paddingIsCreditedToTheStreamWithTheNextUpdate() {
        var machine = Self.machine()
        _ = machine.handle(.headers(streamID: Self.one, endStream: false, trailers: false))
        _ = machine.handle(Self.data(Self.one, 1_000, padding: 32_000))
        #expect(machine.receiveWindow(of: Self.one)?.available == 65_535 - 33_000)
        #expect(machine.receiveWindow(of: Self.one)?.pending == 32_000)
        #expect(machine.handle(.bodyConsumed(streamID: Self.one, length: 1_000))
                == .sendWindowUpdate(connectionIncrement: nil, streamID: Self.one, streamIncrement: 33_000))
    }

    @Test func noStreamCreditAfterEndStream() {
        var machine = Self.machine(connectionWindowSize: 65_535)
        _ = machine.handle(.headers(streamID: Self.one, endStream: false, trailers: false))
        _ = machine.handle(Self.data(Self.one, 40_000, endStream: true))
        #expect(machine.receiveWindow(of: Self.one) == nil)
        #expect(machine.handle(.bodyConsumed(streamID: Self.one, length: 40_000))
                == .sendWindowUpdate(connectionIncrement: 40_000, streamID: Self.one, streamIncrement: nil))
    }

    /// Before the ACK the peer may already use our larger window or still use 65,535; after it,
    /// the advertised window applies exactly, also to streams already open (§6.9.2).
    @Test func acknowledgedInitialWindowSizeAppliesExactly() {
        var machine = Self.machine(initialWindowSize: 16_384, acknowledged: false)
        _ = machine.handle(.headers(streamID: Self.one, endStream: false, trailers: false))
        #expect(machine.receiveWindow(of: Self.one)?.size == 65_535)
        #expect(machine.handle(Self.data(Self.one, 20_000)) == .acceptData(connectionIncrement: nil))
        _ = machine.handle(.settingsAck)
        #expect(machine.receiveWindow(of: Self.one)?.available == 16_384 - 20_000)
        #expect(machine.handle(Self.data(Self.one, 1)) == .resetStream(streamID: Self.one, .flowControlError, windowIncrement: nil))
        let three = HTTP2StreamID(3)
        _ = machine.handle(.headers(streamID: three, endStream: false, trailers: false))
        #expect(machine.receiveWindow(of: three)?.size == 16_384)

        var larger = Self.machine(initialWindowSize: 1 << 20, acknowledged: false)
        _ = larger.handle(.headers(streamID: Self.one, endStream: false, trailers: false))
        #expect(larger.handle(Self.data(Self.one, 100_000)) == .acceptData(connectionIncrement: nil))
        _ = larger.handle(.settingsAck)
        #expect(larger.receiveWindow(of: Self.one)?.available == (1 << 20) - 100_000)
    }

    // MARK: Connections

    /// A handler that never reads: the client stalls at the stream window, no stream credit
    /// comes back, and the server buffers exactly one window.
    @Test func clientStallsAtTheWindowWhenTheHandlerDoesNotRead() async throws {
        let gate = Gate()
        let handler = ClosureHandler { _ in
            await gate.wait()
            return HTTPResponse(status: .ok)
        }
        try await withH2Driver(handler: handler) { client, driver in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/up", method: "POST"), endStream: false))
            let sending = client
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var sender = sending
                    // Stops at 65,535 bytes and waits for a WINDOW_UPDATE that never comes.
                    _ = try? await sender.sendBody(H2RequestBodyTests.pattern(200_000), on: 1)
                }
                var buffered = 0
                for _ in 0..<400 {
                    buffered = driver.state.withLock { $0.bodies[1]?.bufferedBytes ?? 0 }
                    if buffered == 65_535 { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(buffered == 65_535)
                try await Task.sleep(for: .milliseconds(50))
                let window = driver.state.withLock { $0.machine.receiveWindow(of: Self.one) }
                #expect(window?.available == 0)
                #expect(driver.state.withLock { $0.bodies[1]?.bufferedBytes } == 65_535)
                group.cancelAll()
            }
            gate.open()
        }
    }

    /// A handler that reads: a 1 MB upload through 64 KiB windows completes, with one stream
    /// WINDOW_UPDATE per half window rather than per DATA frame.
    @Test func readingHandlerGetsTimelyBatchedUpdates() async throws {
        let body = H2RequestBodyTests.pattern(1 << 20)
        try await withH2Connection(handler: H2RequestBodyTests.echo()) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/up", method: "POST"), endStream: false))
            let others = try await client.sendBody(body, on: 1)
            let updates = others.compactMap { frame -> UInt32? in
                if case .windowUpdate(1, let increment) = frame { return increment }
                return nil
            }
            #expect(!updates.isEmpty)
            #expect(updates.allSatisfy { $0 >= 32_767 }, "\(updates)")
            // 64 DATA frames of 16 KiB; far fewer updates.
            #expect(updates.count <= 40, "\(updates.count)")
            let response = try await client.response(on: 1)
            #expect(String(decoding: response.body, as: UTF8.self) == "\(1 << 20) \(H2RequestBodyTests.checksum(body))")
        }
    }

    /// Window accounting across many streams: buffered bytes count against the connection
    /// window until consumed, and every consumed byte is credited back exactly once.
    @Test func windowAccountingAcrossManyStreams() async throws {
        let gate = Gate()
        let handler = ClosureHandler { request in
            await gate.wait()
            var count = 0
            for try await chunk in request.body { count += chunk.readableBytes }
            return HTTPResponse(body: .bytes(ByteBuffer(bytes: Array("\(count)".utf8))))
        }
        let streams = 20
        let perStream = 50_000
        try await withH2Driver(handler: handler) { client, driver in
            try await client.handshake()
            for i in 0..<streams {
                let id = UInt32(2 * i + 1)
                try await client.send(F.headers(id, block: client.requests.get("/\(i)", method: "POST"), endStream: false))
                // Five 10,000-byte DATA frames, the last with END_STREAM.
                try await client.send(F.join((0..<5).map {
                    F.data(id, Array(repeating: UInt8($0), count: perStream / 5), endStream: $0 == 4)
                }))
            }
            try await client.send(F.ping(9))
            let before = try await client.frames(until: { $0 == .ping(ack: true, 9) })
            // Only the preface's raise of the connection window: nothing was consumed yet.
            let raise = UInt32((1 << 20) - 65_535)
            #expect(!before.contains { if case .windowUpdate(_, let i) = $0 { return i != raise }; return false }, "\(before)")
            let total = streams * perStream
            #expect(driver.state.withLock { $0.machine.connectionReceiveWindow } == (1 << 20) - total)

            gate.open()
            var credited = 0
            var answered = 0
            while answered < streams, let frame = try await client.nextFrame() {
                switch frame {
                case .windowUpdate(0, let increment): credited += Int(increment)
                case .windowUpdate: Issue.record("stream credit after END_STREAM: \(frame)")
                case .data(_, let bytes, true):
                    #expect(String(decoding: bytes, as: UTF8.self) == "\(perStream)")
                    answered += 1
                default: break
                }
            }
            #expect(answered == streams)
            let machine = driver.state.withLock { $0.machine }
            #expect(machine.connectionReceiveWindow + machine.pendingReceiveCredit == 1 << 20)
            #expect(credited + machine.pendingReceiveCredit == total)
        }
    }

    /// The advertised (smaller) INITIAL_WINDOW_SIZE is enforced once acknowledged.
    @Test func smallerAdvertisedWindowIsEnforced() async throws {
        let gate = Gate()
        let handler = ClosureHandler { _ in
            await gate.wait()
            return HTTPResponse(status: .ok)
        }
        try await withH2Connection(configuration: HTTP2Configuration(initialWindowSize: 16_384), handler: handler) { client in
            try await client.handshake()
            try await client.send(F.ping(1))
            _ = try await client.frames(until: { $0 == .ping(ack: true, 1) })
            try await client.send(F.headers(1, block: client.requests.get("/", method: "POST"), endStream: false),
                                  F.data(1, Array(repeating: 1, count: 16_384), endStream: false),
                                  F.data(1, [1], endStream: false))
            let seen = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(seen.last == .rstStream(stream: 1, .flowControlError), "\(seen)")
            gate.open()
        }
    }
}
