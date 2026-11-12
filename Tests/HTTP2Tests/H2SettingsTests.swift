import HPACK
@testable import HTTP2
import HTTPCore
import Testing

/// #0043: the SETTINGS exchange, as a state machine and over an in-memory connection.
@Suite(.timeLimit(.minutes(1)))
struct H2SettingsTests {
    typealias Event = HTTP2Connection.Event
    typealias Action = HTTP2Connection.Action

    static let local = HTTP2Settings(headerTableSize: 1024, maxConcurrentStreams: 10, initialWindowSize: 100_000,
                                     maxFrameSize: 32_768, maxHeaderListSize: 8_192)

    /// A machine after `start` and the peer's (empty) SETTINGS.
    static func started(_ peer: HTTP2Settings = HTTP2Settings()) -> HTTP2Connection {
        var machine = HTTP2Connection(configuration: .init(localSettings: local, connectionWindowSize: 1 << 20))
        _ = machine.handle(.start)
        _ = machine.handle(.settings(peer))
        return machine
    }

    // MARK: State machine

    @Test func startSendsOurSettingsAndRaisesTheConnectionWindow() {
        var machine = HTTP2Connection(configuration: .init(localSettings: Self.local, connectionWindowSize: 1 << 20))
        #expect(machine.handle(.start) == .sendPreface(Self.local, windowIncrement: (1 << 20) - 65_535))
        #expect(machine.awaitingSettingsAck)
        var plain = HTTP2Connection()
        #expect(plain.handle(.start) == .sendPreface(HTTP2Settings(), windowIncrement: nil))
    }

    @Test func everyFrameBeforeTheFirstSettingsIsAProtocolError() {
        let events: [Event] = [
            .settingsAck, .ping(ack: false, opaqueData: 1), .goaway(lastStreamID: .connection, .noError),
            .windowUpdate(streamID: .connection, increment: 1), .rstStream(streamID: HTTP2StreamID(1), .cancel),
            .priority(streamID: HTTP2StreamID(1)), .headers(streamID: HTTP2StreamID(1), endStream: true, trailers: false),
            .data(streamID: HTTP2StreamID(1), dataLength: 0, flowControlledLength: 0, endStream: true), .unknownFrame,
            .streamError(.stream(HTTP2StreamID(1), .frameSizeError, reason: "x")),
        ]
        for event in events {
            var machine = HTTP2Connection()
            _ = machine.handle(.start)
            guard case .goaway(let last, let error) = machine.handle(event) else {
                Issue.record("\(event) did not fail the connection")
                continue
            }
            #expect(last == .connection)
            #expect(error.code == .protocolError)
            #expect(machine.isFailed)
            // Everything afterwards is ignored; local sends are dropped.
            #expect(machine.handle(.settings(HTTP2Settings())) == .none)
            #expect(machine.handle(.sendHeaders(streamID: HTTP2StreamID(1), endStream: true)) == .drop)
        }
    }

    @Test func peerSettingsAreAppliedAndAcknowledged() {
        var machine = Self.started()
        let peer = HTTP2Settings(headerTableSize: 0, enablePush: false, maxConcurrentStreams: 7, initialWindowSize: 10,
                                 maxFrameSize: 20_000, maxHeaderListSize: 4_000)
        #expect(machine.handle(.settings(peer)) == .acknowledgeSettings(headerTableSize: 0))
        #expect(machine.peerHeaderTableSize == 0)
        #expect(machine.peerInitialWindowSize == 10)
        #expect(machine.peerMaxFrameSize == 20_000)
        #expect(machine.peerMaxHeaderListSize == 4_000)
        // ENABLE_PUSH 1 is allowed from a client (a server just never pushes).
        #expect(machine.handle(.settings(HTTP2Settings(enablePush: true))) == .acknowledgeSettings(headerTableSize: nil))
        // An empty SETTINGS is acknowledged and changes nothing.
        #expect(machine.handle(.settings(HTTP2Settings())) == .acknowledgeSettings(headerTableSize: nil))
        #expect(machine.peerMaxFrameSize == 20_000)
    }

    /// Our settings are in force only after the ACK (RFC 9113 §6.5.3).
    @Test func localSettingsApplyOnlyAfterTheAck() {
        var machine = Self.started()
        #expect(machine.appliedLocalSettings == HTTP2Settings())
        #expect(machine.handle(.ping(ack: false, opaqueData: 9)) == .sendPingAck(opaqueData: 9))
        #expect(machine.appliedLocalSettings == HTTP2Settings())
        #expect(machine.handle(.settingsAck) == .applyLocalSettings(Self.local))
        #expect(machine.appliedLocalSettings == Self.local)
        #expect(!machine.awaitingSettingsAck)
        // A second (unsolicited) ACK changes nothing.
        #expect(machine.handle(.settingsAck) == .none)
    }

    @Test func settingsTimeoutBeforeTheAck() {
        var machine = Self.started()
        guard case .goaway(_, let error) = machine.handle(.settingsTimeout) else {
            Issue.record("no GOAWAY")
            return
        }
        #expect(error.code == .settingsTimeout)

        var acked = Self.started()
        _ = acked.handle(.settingsAck)
        #expect(acked.handle(.settingsTimeout) == .none)
        #expect(!acked.isFailed)
    }

    @Test func initialWindowSizeChangesMoveStreamSendWindows() {
        var machine = Self.started()
        let one = HTTP2StreamID(1)
        let three = HTTP2StreamID(3)
        #expect(machine.handle(.headers(streamID: one, endStream: true, trailers: false)) == .dispatch(streamID: one, endStream: true))
        #expect(machine.handle(.headers(streamID: three, endStream: true, trailers: false)) == .dispatch(streamID: three, endStream: true))
        #expect(machine.handle(.sendHeaders(streamID: one, endStream: false)) == .send)
        #expect(machine.handle(.sendData(streamID: one, length: 1_000, endStream: false)) == .sendData(length: 1_000, endStream: false))
        #expect(machine.sendWindow(of: one) == 65_535 - 1_000)
        // Shrinking makes the window negative (§6.9.2): no DATA until it is positive again.
        #expect(machine.handle(.settings(HTTP2Settings(initialWindowSize: 500))) == .acknowledgeSettings(headerTableSize: nil))
        #expect(machine.sendWindow(of: one) == -500)
        #expect(machine.sendWindow(of: three) == 500)
        #expect(machine.handle(.sendData(streamID: one, length: 10, endStream: true)) == .waitForWindow)
        #expect(machine.handle(.windowUpdate(streamID: one, increment: 510)) == .windowChanged)
        #expect(machine.handle(.sendData(streamID: one, length: 10, endStream: true)) == .sendData(length: 10, endStream: true))
        #expect(machine.sendWindow(of: one) == nil)
        // Growing past 2^31 - 1 in any stream window is a connection FLOW_CONTROL_ERROR.
        #expect(machine.handle(.windowUpdate(streamID: three, increment: 1_000)) == .windowChanged)
        guard case .goaway(_, let error) = machine.handle(.settings(HTTP2Settings(initialWindowSize: HTTP2Settings.maxWindowSize))) else {
            Issue.record("no GOAWAY")
            return
        }
        #expect(error.code == .flowControlError)
    }

    @Test func dataIsCappedByThePeerMaxFrameSize() {
        var machine = Self.started(HTTP2Settings(initialWindowSize: 1 << 20))
        let one = HTTP2StreamID(1)
        _ = machine.handle(.headers(streamID: one, endStream: true, trailers: false))
        _ = machine.handle(.windowUpdate(streamID: .connection, increment: 1 << 20))
        _ = machine.handle(.sendHeaders(streamID: one, endStream: false))
        #expect(machine.handle(.sendData(streamID: one, length: 50_000, endStream: true)) == .sendData(length: 16_384, endStream: false))
        _ = machine.handle(.settings(HTTP2Settings(maxFrameSize: 40_000)))
        #expect(machine.handle(.sendData(streamID: one, length: 33_616, endStream: true)) == .sendData(length: 33_616, endStream: true))
    }

    /// Every validation rule, with its exact code: the frame parser validates SETTINGS
    /// (RFC 9113 §6.5.2) and the machine answers its connection error with one GOAWAY; valid
    /// frames, unknown identifiers included, are acknowledged.
    @Test(arguments: [
        ("ENABLE_PUSH 2", F.rawSettings([(0x2, 2)]), HTTP2ErrorCode?.some(.protocolError)),
        ("INITIAL_WINDOW_SIZE 2^31", F.rawSettings([(0x4, 0x8000_0000)]), .flowControlError),
        ("MAX_FRAME_SIZE 16383", F.rawSettings([(0x5, 16_383)]), .protocolError),
        ("MAX_FRAME_SIZE 2^24", F.rawSettings([(0x5, 1 << 24)]), .protocolError),
        ("ACK with payload", F.rawSettings([(0x1, 0)], flags: .ack), .frameSizeError),
        ("length not a multiple of 6", F.raw(type: .settings, streamID: 0, payload: [0, 1, 0, 0, 0]), .frameSizeError),
        ("on a stream", F.rawSettings([], streamID: 1), .protocolError),
        ("unknown identifiers", F.rawSettings([(0x99, 7), (0xff, 0xffff_ffff)]), nil),
        ("bounds", F.rawSettings([(0x2, 1), (0x4, 0x7fff_ffff), (0x5, 16_384), (0x5, 16_777_215)]), nil),
    ])
    func validation(name: String, frame: ByteBuffer, code: HTTP2ErrorCode?) {
        var parser = HTTP2FrameParser(configuration: .init(role: .server))
        var machine = HTTP2Connection()
        _ = machine.handle(.start)
        let action: Action
        do throws(HTTP2Error) {
            switch try parser.parse(frame).event {
            case .settings(let settings): action = machine.handle(.settings(settings))
            case let other:
                Issue.record("\(name): \(other)")
                return
            }
        } catch {
            action = machine.handle(.connectionError(error))
        }
        if let code {
            guard case .goaway(.connection, let error) = action else {
                Issue.record("\(name): \(action)")
                return
            }
            #expect(error.code == code, "\(name)")
            #expect(machine.handle(.connectionError(error)) == .none, "one GOAWAY only")
        } else {
            #expect(action == .acknowledgeSettings(headerTableSize: nil), "\(name)")
        }
    }

    // MARK: Over a connection

    /// Each invalid SETTINGS frame ends the connection with GOAWAY and the exact code.
    @Test(arguments: [
        ("ENABLE_PUSH 2", F.rawSettings([(0x2, 2)]), HTTP2ErrorCode.protocolError),
        ("INITIAL_WINDOW_SIZE 2^31", F.rawSettings([(0x4, 0x8000_0000)]), .flowControlError),
        ("MAX_FRAME_SIZE 16383", F.rawSettings([(0x5, 16_383)]), .protocolError),
        ("MAX_FRAME_SIZE 2^24", F.rawSettings([(0x5, 1 << 24)]), .protocolError),
        ("ACK with payload", F.rawSettings([(0x1, 0)], flags: .ack), .frameSizeError),
        ("length not a multiple of 6", F.raw(type: .settings, streamID: 0, payload: [0, 1, 0, 0, 0]), .frameSizeError),
        ("on a stream", F.rawSettings([], streamID: 1), .protocolError),
    ])
    func invalidSettingsEndTheConnection(name: String, frame: ByteBuffer, code: HTTP2ErrorCode) async throws {
        try await withH2Connection { client in
            try await client.handshake()
            try await client.send(frame)
            let frames = try await client.framesUntilClosed()
            #expect(frames.last == .goaway(last: 0, code, debug: "\(code.name)"), "\(name): \(frames)")
        }
    }

    @Test func unknownSettingsAreIgnoredAndAcknowledged() async throws {
        try await withH2Connection { client in
            try await client.send(F.preface, F.rawSettings([(0x99, 7), (0xff, 0xffff_ffff)]))
            let frames = try await client.frames(until: { $0 == .settingsAck })
            #expect(frames.last == .settingsAck)
            #expect(!frames.contains { $0.isGoaway })
        }
    }

    /// Our SETTINGS goes first, before the client's arrive; the client's are ACKed after.
    @Test func ackTiming() async throws {
        try await withH2Connection { client in
            try await client.send(F.preface)
            #expect(try await client.nextFrame() == .settings(HTTP2Configuration().localSettings))
            #expect(try await client.nextFrame() == .windowUpdate(stream: 0, (1 << 20) - 65_535))
            try await client.send(F.settings(HTTP2Settings(maxFrameSize: 20_000)))
            #expect(try await client.nextFrame() == .settingsAck)
            try await client.send(F.settingsAck)
            try await client.send(F.ping(5))
            #expect(try await client.nextFrame() == .ping(ack: true, 5))
        }
    }

    /// A frame above 16,384 bytes is a FRAME_SIZE_ERROR until our larger MAX_FRAME_SIZE is
    /// acknowledged, and accepted after.
    @Test func largerFrameSizeAppliesOnlyAfterTheAck() async throws {
        let config = HTTP2Configuration(maxFrameSize: 32_768)
        let big = F.raw(type: HTTP2FrameType(rawValue: 0x42), streamID: 0, payload: Array(repeating: 7, count: 20_000))
        try await withH2Connection(configuration: config) { client in
            try await client.handshake()
            try await client.send(big, F.ping(1))
            let frames = try await client.frames(until: { $0 == .ping(ack: true, 1) })
            #expect(frames.last == .ping(ack: true, 1), "\(frames)")
        }
        try await withH2Connection(configuration: config) { client in
            try await client.send(F.preface, F.settings(), big)
            let frames = try await client.framesUntilClosed()
            #expect(frames.last == .goaway(last: 0, .frameSizeError, debug: "FRAME_SIZE_ERROR"), "\(frames)")
        }
    }

    @Test func settingsTimeoutClosesTheConnection() async throws {
        let config = HTTP2Configuration(settingsTimeout: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        try await withH2Connection(configuration: config) { client in
            try await client.send(F.preface, F.settings())
            let frames = try await client.framesUntilClosed()
            #expect(frames.last == .goaway(last: 0, .settingsTimeout, debug: "SETTINGS_TIMEOUT"), "\(frames)")
        }
        #expect(clock.now - start < .seconds(5))
        // Acknowledged in time: no timeout.
        try await withH2Connection(configuration: config) { client in
            try await client.handshake()
            try await Task.sleep(for: .milliseconds(300))
            try await client.send(F.ping(3))
            #expect(try await client.frames(until: { $0 == .ping(ack: true, 3) }).allSatisfy { !$0.isGoaway })
        }
    }

    /// The peer's HEADER_TABLE_SIZE reaches the HPACK encoder in wire order: blocks queued
    /// before the SETTINGS ACK use the old table, the first block after it starts with the size
    /// update. A client decoder that applies the new limit at the ACK decodes every block.
    @Test func headerTableSizeChangesReachHPACKInOrder() throws {
        var shared = HTTP2SharedState(configuration: HTTP2Configuration())
        var wakeups = HTTP2Wakeups()
        _ = shared.handle(.start, wakeups: &wakeups)
        _ = shared.handle(.settings(HTTP2Settings()), wakeups: &wakeups)
        for id in [1, 3, 5] as [UInt32] {
            _ = shared.handle(.headers(streamID: HTTP2StreamID(id), endStream: true, trailers: false), wakeups: &wakeups)
        }
        var headers = HTTPFields()
        headers.append(name: "x-custom", value: "a value worth indexing")
        func respond(_ id: UInt32) {
            let step = shared.sendHeaders(streamID: HTTP2StreamID(id), status: .ok, headers: headers, contentLength: nil,
                                          endStream: true, wakeups: &wakeups)
            #expect(step == .sent(length: 0, endStream: true))
        }
        respond(1)
        _ = shared.handle(.settings(HTTP2Settings(headerTableSize: 0)), wakeups: &wakeups)
        respond(3)
        _ = shared.handle(.settings(HTTP2Settings(headerTableSize: 256)), wakeups: &wakeups)
        respond(5)
        guard case .send(let batch) = shared.nextWriterStep(wakeups: &wakeups) else {
            Issue.record("nothing queued")
            return
        }
        var decoder = HPACKDecoder()
        var blocks: [[UInt8]] = []
        var acks = 0
        for frame in H2FrameReader.frames(in: batch) {
            switch frame {
            case .settingsAck:
                acks += 1
                decoder.setMaxTableSizeLimit([4_096, 0, 256][acks - 1])
            case .headers(_, _, _, let block):
                blocks.append(block)
                let fields = try decodeBlock(block, with: &decoder)
                #expect(fields.map(\.0) == [":status", "x-custom"])
            default:
                break
            }
        }
        #expect(acks == 3)
        #expect(blocks.count == 3)
        // The first block indexes the field; after the shrink to 0 the next one starts with
        // a size update (001xxxxx) and the table is empty.
        #expect(blocks[0].first! & 0xe0 != 0x20)
        #expect(blocks[1].first! & 0xe0 == 0x20)
        #expect(blocks[2].first! & 0xe0 == 0x20)
        #expect(decoder.dynamicTable.maxSize == 256)
    }
}
