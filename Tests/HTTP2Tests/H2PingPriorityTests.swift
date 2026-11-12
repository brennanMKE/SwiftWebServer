@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0050: PING and the deprecated PRIORITY scheme (RFC 9113 §5.3, §6.3, §6.7).
@Suite(.timeLimit(.minutes(1)))
struct H2PingPriorityTests {
    static func ready() -> HTTP2Connection {
        var machine = HTTP2Connection()
        _ = machine.handle(.start)
        _ = machine.handle(.settings(HTTP2Settings()))
        return machine
    }

    // MARK: PING, state machine

    @Test func pingIsAcknowledgedWithTheSamePayload() {
        var machine = Self.ready()
        #expect(machine.handle(.ping(ack: false, opaqueData: 0x0102_0304_0506_0708))
                == .sendPingAck(opaqueData: 0x0102_0304_0506_0708))
    }

    @Test func unsolicitedPingAckIsIgnored() {
        var machine = Self.ready()
        #expect(machine.handle(.ping(ack: true, opaqueData: 42)) == .none)
        #expect(!machine.isFailed)
    }

    @Test func serverPingIsMatchedToItsAck() {
        var machine = Self.ready()
        #expect(machine.handle(.sendPing(opaqueData: 7)) == .sendPing(opaqueData: 7))
        #expect(machine.handle(.ping(ack: true, opaqueData: 8)) == .none)
        #expect(machine.handle(.ping(ack: true, opaqueData: 7)) == .pingAcknowledged(opaqueData: 7))
        // A second ACK for the same PING is unsolicited.
        #expect(machine.handle(.ping(ack: true, opaqueData: 7)) == .none)
        #expect(machine.outstandingPings.isEmpty)
    }

    @Test func outstandingPingsAreBounded() {
        var machine = Self.ready()
        for i in 0..<UInt64(HTTP2Connection.maxOutstandingPings) {
            #expect(machine.handle(.sendPing(opaqueData: i)) == .sendPing(opaqueData: i))
        }
        #expect(machine.handle(.sendPing(opaqueData: 99)) == .none)
        #expect(machine.handle(.sendPing(opaqueData: 0)) == .none, "duplicate opaque data")
        #expect(machine.handle(.pingAbandoned(opaqueData: 1)) == .none)
        #expect(machine.handle(.ping(ack: true, opaqueData: 1)) == .none, "abandoned PING")
        #expect(machine.handle(.sendPing(opaqueData: 99)) == .sendPing(opaqueData: 99))
    }

    @Test func pingOnAStreamIsAConnectionProtocolError() throws {
        var parser = HTTP2FrameParser(configuration: .init(role: .server))
        let frame = F.raw(type: .ping, streamID: 1, payload: Array(repeating: 0, count: 8))
        #expect(throws: HTTP2Error.self) {
            try frame.withUnsafeReadableBytes { input throws(HTTP2Error) in _ = try parser.parse(input) }
        }
    }

    // MARK: PRIORITY, state machine and parser

    @Test func priorityFramesAreIgnoredInEveryStreamState() {
        var machine = Self.ready()
        // Idle: no stream is opened (§5.1).
        #expect(machine.handle(.priority(streamID: HTTP2StreamID(5))) == .none)
        #expect(machine.streams.stream(HTTP2StreamID(5)) == nil)
        #expect(machine.handle(.headers(streamID: HTTP2StreamID(5), endStream: false, trailers: false))
                == .dispatch(streamID: HTTP2StreamID(5), endStream: false))
        // Open, then closed.
        #expect(machine.handle(.priority(streamID: HTTP2StreamID(5))) == .none)
        _ = machine.handle(.rstStream(streamID: HTTP2StreamID(5), .cancel))
        #expect(machine.handle(.priority(streamID: HTTP2StreamID(5))) == .none)
        // Below the highest stream, never opened.
        #expect(machine.handle(.priority(streamID: HTTP2StreamID(3))) == .none)
        #expect(!machine.isFailed)
    }

    @Test(arguments: [(4, HTTP2ErrorCode.frameSizeError), (6, .frameSizeError)])
    func priorityWithTheWrongLengthIsAStreamFrameSizeError(length: Int, code: HTTP2ErrorCode) throws {
        var parser = HTTP2FrameParser(configuration: .init(role: .server))
        let frame = F.raw(type: .priority, streamID: 3, payload: Array(repeating: 0, count: length))
        let event = try frame.withUnsafeReadableBytes { input throws(HTTP2Error) in try parser.parse(input).event }
        guard case .streamError(let error) = event else {
            Issue.record("\(event)")
            return
        }
        #expect(error.streamID == HTTP2StreamID(3))
        #expect(error.code == code)
    }

    @Test func priorityDependingOnItselfIsAStreamProtocolError() throws {
        var parser = HTTP2FrameParser(configuration: .init(role: .server))
        let frame = F.raw(type: .priority, streamID: 3, payload: [0, 0, 0, 3, 16])
        let event = try frame.withUnsafeReadableBytes { input throws(HTTP2Error) in try parser.parse(input).event }
        guard case .streamError(let error) = event else {
            Issue.record("\(event)")
            return
        }
        #expect(error.code == .protocolError)
        var machine = Self.ready()
        _ = machine.handle(.headers(streamID: HTTP2StreamID(3), endStream: false, trailers: false))
        #expect(machine.handle(.streamError(error)) == .resetStream(streamID: HTTP2StreamID(3), .protocolError, windowIncrement: nil))
    }

    @Test func settingsAdvertiseNoRFC7540Priorities() {
        #expect(HTTP2Configuration().localSettings.noRFC7540Priorities == true)
    }

    // MARK: Over a connection

    /// HEADERS with the PRIORITY flag: `dependency, weight` before the block.
    static func prioritizedHeaders(_ stream: UInt32, dependsOn dependency: UInt32, block: [UInt8]) -> ByteBuffer {
        let fields: [UInt8] = [UInt8(dependency >> 24), UInt8((dependency >> 16) & 0xff),
                               UInt8((dependency >> 8) & 0xff), UInt8(dependency & 0xff), 200]
        return F.raw(type: .headers, flags: [.endHeaders, .endStream, .priority], streamID: stream, payload: fields + block)
    }

    @Test func priorityIsParsedAndIgnoredOverAConnection() async throws {
        try await withH2Connection { client in
            try await client.handshake()
            guard case .settings(let settings)? = client.reader.frames.first else {
                Issue.record("no SETTINGS")
                return
            }
            #expect(settings.noRFC7540Priorities == true)
            // PRIORITY on an idle stream, then a prioritized HEADERS: served as usual.
            try await client.send(F.raw(type: .priority, streamID: 1, payload: [0x80, 0, 0, 0, 255]))
            try await client.send(Self.prioritizedHeaders(1, dependsOn: 0, block: client.requests.get("/one")))
            #expect(String(decoding: try await client.response(on: 1).body, as: UTF8.self) == "hello /one")
            // A HEADERS frame that depends on its own stream is a stream error.
            try await client.send(Self.prioritizedHeaders(3, dependsOn: 3, block: client.requests.get("/self")))
            var frames = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(frames.last == .rstStream(stream: 3, .protocolError), "\(frames)")
            // So is a PRIORITY frame that does, and one of the wrong length.
            try await client.send(F.headers(5, block: client.requests.get("/five"), endStream: false))
            try await client.send(F.raw(type: .priority, streamID: 5, payload: [0, 0, 0, 5, 1]))
            frames = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(frames.last == .rstStream(stream: 5, .protocolError), "\(frames)")
            try await client.send(F.headers(7, block: client.requests.get("/seven"), endStream: false))
            try await client.send(F.raw(type: .priority, streamID: 7, payload: [0, 0, 0, 1]))
            frames = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(frames.last == .rstStream(stream: 7, .frameSizeError), "\(frames)")
            // The connection carries on.
            try await client.send(F.headers(9, block: client.requests.get("/nine")))
            #expect(String(decoding: try await client.response(on: 9).body, as: UTF8.self) == "hello /nine")
        }
    }

    /// A PING ACK goes out in the priority lane, ahead of response DATA queued before it.
    @Test func pingAckOvertakesQueuedData() async throws {
        let counting = Box<CountingTransport<InMemoryTransport>>()
        let handler = ClosureHandler { _ in HTTPResponse(body: .bytes(ByteBuffer(bytes: Array(repeating: 1, count: 30_000)))) }
        try await withH2Connection(handler: handler, server: { base in
            let transport = CountingTransport(base)
            counting.value = transport
            return transport
        }) { client in
            try await client.handshake()
            _ = try await client.frames(until: { $0 == .settingsAck })
            let transport = try #require(counting.value)
            // Hold the writer in the send of PING ACK 1, so the response and PING ACK 2 queue up.
            transport.closeGate()
            try await client.send(F.ping(1))
            try await Task.sleep(for: .milliseconds(30))
            try await client.send(F.headers(1, block: client.requests.get("/")))
            try await Task.sleep(for: .milliseconds(50))
            try await client.send(F.ping(2))
            try await Task.sleep(for: .milliseconds(50))
            transport.openGate()
            let frames = try await client.frames(until: { if case .data(1, _, true) = $0 { return true }; return false })
            let ack = try #require(frames.firstIndex(of: .ping(ack: true, 2)), "\(frames)")
            let firstData = try #require(frames.firstIndex { if case .data = $0 { return true }; return false })
            #expect(ack < firstData, "\(frames)")
        }
    }

    // MARK: Server PINGs

    @Test func serverPingMeasuresTheRoundTrip() async throws {
        try await withH2Driver { client, driver in
            try await client.handshake()
            async let rtt = driver.ping(timeout: .seconds(5))
            let frames = try await client.frames(until: { if case .ping(false, _) = $0 { return true }; return false })
            guard case .ping(false, let data)? = frames.last else {
                Issue.record("\(frames)")
                return
            }
            // An ACK with other data is ignored; the matching one completes the PING.
            try await client.send(F.ping(data &+ 1, ack: true))
            try await client.send(F.ping(data, ack: true))
            #expect(await rtt != nil)
            #expect(driver.state.withLock { $0.machine.outstandingPings.isEmpty })
        }
    }

    @Test func unansweredPingTimesOut() async throws {
        try await withH2Driver { client, driver in
            try await client.handshake()
            #expect(await driver.ping(timeout: .milliseconds(50)) == nil)
            #expect(driver.state.withLock { $0.machine.outstandingPings.isEmpty && $0.pingWaiters.isEmpty })
            #expect(!driver.state.withLock { $0.machine.isFailed })
        }
    }
}

