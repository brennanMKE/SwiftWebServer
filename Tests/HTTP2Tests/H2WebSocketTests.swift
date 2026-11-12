import HPACK
@testable import HTTP2
import HTTPCore
import HTTPServer
import HTTPTestSupport
import NetworkTransport
import Synchronization
import Testing
import WebSockets

// #0067: WebSockets over HTTP/2 with extended CONNECT (RFC 8441), driven by an in-repo h2
// WebSocket client over in-memory transports (and once over loopback TCP).

/// A client WebSocket frame, masked.
private func wsFrame(_ opcode: WSOpcode, _ payload: [UInt8], fin: Bool = true, masked: Bool = true) -> [UInt8] {
    var buffer = ByteBuffer()
    WSFrameWriter.appendFrame(fin: fin, opcode: opcode, payload: ByteBuffer(bytes: payload),
                              maskKey: masked ? 0x1A2B_3C4D : nil, into: &buffer)
    return buffer.withUnsafeReadableBytes { Array($0) }
}

private func wsClose(_ code: UInt16) -> [UInt8] {
    wsFrame(.close, [UInt8(code >> 8), UInt8(code & 0xFF)])
}

private func rstStream(_ stream: UInt32, _ code: HTTP2ErrorCode) -> ByteBuffer {
    let value = code.rawValue
    return F.raw(type: .rstStream, streamID: stream,
                 payload: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
}

/// The client side of one WebSocket over an h2 stream. It honours the server's flow-control
/// windows when sending (waiting for WINDOW_UPDATE), and credits what it receives unless
/// ``autoCredit`` is off.
struct H2WebSocketClient {
    struct Frame: Equatable {
        var opcode: WSOpcode
        var payload: [UInt8]
        var closeCode: UInt16? {
            guard opcode == .close, payload.count >= 2 else { return nil }
            return UInt16(payload[0]) << 8 | UInt16(payload[1])
        }
    }

    let stream: UInt32
    var ws = WSFrameParser(configuration: .init(expectsMaskedFrames: false))
    var wsBytes = ByteBuffer()
    var payload = ByteBuffer()
    var header: WSFrameHeader?
    var headers: [(String, String)]?
    var headerEndsStream = false
    /// The server sent END_STREAM.
    var finished = false
    /// The server reset the stream with this code.
    var resetCode: HTTP2ErrorCode?
    /// Our send windows (the server's INITIAL_WINDOW_SIZE is 65,535; the connection window starts there too).
    var streamWindow = 65_535
    var connectionWindow = 65_535
    /// DATA payload bytes received on the stream.
    var received = 0
    var autoCredit = true

    init(stream: UInt32) {
        self.stream = stream
    }

    /// Sends the extended CONNECT HEADERS (no END_STREAM).
    static func connect(
        _ h2: inout H2Client, stream: UInt32 = 1, path: String = "/ws",
        extra: [(String, String)] = [("sec-websocket-version", "13")],
        pseudo: [(String, String)]? = nil
    ) async throws -> H2WebSocketClient {
        let fields = pseudo ?? [(":method", "CONNECT"), (":protocol", "websocket"), (":scheme", "http"),
                                (":path", path), (":authority", "localhost")]
        let block = h2.requests.block(fields + extra)
        try await h2.send(F.headers(stream, block: block, endStream: false))
        return H2WebSocketClient(stream: stream)
    }

    var status: String? { headers?.first { $0.0 == ":status" }?.1 }
    func header(_ name: String) -> String? { headers?.first { $0.0 == name }?.1 }

    /// Sends WebSocket bytes as DATA frames within the send windows, reading frames (and their
    /// WINDOW_UPDATEs) while a window is closed.
    mutating func send(_ bytes: [UInt8], fin: Bool = false, _ h2: inout H2Client) async throws {
        var offset = 0
        repeat {
            while (streamWindow <= 0 || connectionWindow <= 0) && offset < bytes.count {
                guard try await pull(&h2) else { throw TimedOut() }
            }
            let count = min(bytes.count - offset, streamWindow, connectionWindow, 16_384)
            let end = fin && offset + count == bytes.count
            try await h2.send(F.data(stream, Array(bytes[offset..<offset + count]), endStream: end))
            streamWindow -= count
            connectionWindow -= count
            offset += count
        } while offset < bytes.count
    }

    /// Sends as much of `bytes` as the windows allow now; returns how many were sent.
    mutating func sendWithinWindow(_ bytes: [UInt8], _ h2: inout H2Client) async throws -> Int {
        var offset = 0
        while offset < bytes.count && streamWindow > 0 && connectionWindow > 0 {
            let count = min(bytes.count - offset, streamWindow, connectionWindow, 16_384)
            try await h2.send(F.data(stream, Array(bytes[offset..<offset + count]), endStream: false))
            streamWindow -= count
            connectionWindow -= count
            offset += count
        }
        return offset
    }

    /// Reads one frame and applies it; false at end of the connection or the stream.
    mutating func pull(_ h2: inout H2Client, timeout: Duration = .seconds(10)) async throws -> Bool {
        guard !finished && resetCode == nil else { return false }
        guard let frame = try await h2.nextFrame(timeout: timeout) else { return false }
        switch frame {
        case .headers(stream, let endStream, _, let block):
            let fields = try decodeBlock(block, with: &h2.decoder)
            if headers == nil { headers = fields } else { Issue.record("trailers on a tunnel") }
            if endStream {
                headerEndsStream = true
                finished = true
            }
        case .data(stream, let bytes, let endStream):
            wsBytes.append(contentsOf: bytes)
            received += bytes.count
            if autoCredit && !bytes.isEmpty { try await credit(bytes.count, &h2) }
            if endStream { finished = true }
        case .rstStream(stream, let code):
            resetCode = code
        case .windowUpdate(let id, let increment):
            if id == 0 { connectionWindow += Int(increment) } else if id == stream { streamWindow += Int(increment) }
        case .ping(false, let data):
            try await h2.send(F.ping(data, ack: true))
        default:
            // GOAWAY included: streams below it keep running while the connection drains.
            break
        }
        return true
    }

    /// Returns `count` bytes of receive window to the server, on the stream and the connection.
    func credit(_ count: Int, _ h2: inout H2Client) async throws {
        try await h2.send(F.windowUpdate(stream, UInt32(count)), F.windowUpdate(0, UInt32(count)))
    }

    mutating func readHeaders(_ h2: inout H2Client) async throws {
        while headers == nil { guard try await pull(&h2) else { return } }
    }

    /// The next WebSocket frame from the server, or `nil` at END_STREAM or reset.
    mutating func next(_ h2: inout H2Client) async throws -> Frame? {
        while true {
            switch ws.parse(&wsBytes, payloadInto: &payload) {
            case .header(let h):
                header = h
                payload.clear()
            case .payload(_, let end):
                if end, let h = header {
                    header = nil
                    return Frame(opcode: h.opcode, payload: payload.withUnsafeReadableBytes { Array($0) })
                }
            case .needMoreBytes:
                wsBytes.discardReadBytes()
                guard try await pull(&h2) else { return nil }
            case .error(let code):
                Issue.record("server WebSocket frame error \(code)")
                return nil
            }
        }
    }

    /// Reads to the end of the stream; true when it ended with END_STREAM and no more frames.
    mutating func readsEndStream(_ h2: inout H2Client) async throws -> Bool {
        while let frame = try await next(&h2) { Issue.record("unexpected frame \(frame.opcode)") }
        return finished
    }
}

/// What the server-side WebSocket handler saw.
final class H2WSRecord: Sendable {
    struct State: Sendable {
        var closeCodes: [WebSocketCloseCode?] = []
        var paths: [String] = []
        var subprotocols: [String?] = []
    }
    let state = Mutex(State())
    let ended = ShutdownSignal()
    var snapshot: State { state.withLock { $0 } }
}

private func echoChain(
    _ record: H2WSRecord, configuration: WebSocketConfiguration = WebSocketConfiguration(), gate: ShutdownSignal? = nil
) -> MiddlewareChain<WebSocketUpgrade, HelloHandler> {
    MiddlewareChain(middleware: WebSocketUpgrade(path: "/ws", configuration: configuration, subprotocol: { request in
        request.offeredSubprotocols.contains("chat") ? "chat" : nil
    }) { socket, request in
        if let gate { await gate.wait() }
        // Echo until the connection ends (a send can fail once the peer is gone).
        for await message in socket.messages { try? await socket.send(message) }
        record.state.withLock {
            $0.closeCodes.append(socket.closeCode)
            $0.paths.append(request.path)
            $0.subprotocols.append(socket.subprotocol)
        }
        record.ended.trigger()
    }, next: HelloHandler())
}

private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
}

@Suite(.timeLimit(.minutes(1)))
struct H2WebSocketTests {
    static let wsConfiguration: HTTP2Configuration = {
        var configuration = HTTP2Configuration()
        configuration.enableConnectProtocol = true
        return configuration
    }()

    @Test func settingsAdvertiseExtendedConnectOnlyWithWebSockets() async throws {
        for (withWebSockets, expected) in [(true, true as Bool?), (false, nil)] {
            let handler: any HTTPHandler = withWebSockets ? echoChain(H2WSRecord()) : HelloHandler()
            try await withH2Connection(handler: handler) { h2 in
                try await h2.send(F.preface, F.settings())
                guard case .settings(let settings) = try await h2.nextFrame() else {
                    Issue.record("first frame is not SETTINGS")
                    return
                }
                #expect(settings.enableConnectProtocol == expected)
            }
        }
        #expect(HTTP2Configuration().localSettings.enableConnectProtocol == nil)
        #expect(Self.wsConfiguration.localSettings.enableConnectProtocol == true)
    }

    @Test func echoTextBinaryFragmentedPingAndClientClose() async throws {
        let record = H2WSRecord()
        try await withH2Connection(handler: echoChain(record)) { h2 in
            try await h2.handshake()
            var ws = try await H2WebSocketClient.connect(&h2, extra: [
                ("sec-websocket-version", "13"), ("sec-websocket-protocol", "superchat, chat")])
            try await ws.readHeaders(&h2)
            #expect(ws.status == "200")
            #expect(!ws.headerEndsStream)
            #expect(ws.header("sec-websocket-accept") == nil)
            #expect(ws.header("upgrade") == nil)
            #expect(ws.header("sec-websocket-protocol") == "chat")

            try await ws.send(wsFrame(.text, Array("héllo over h2".utf8)), &h2)
            #expect(try await ws.next(&h2) == .init(opcode: .text, payload: Array("héllo over h2".utf8)))

            try await ws.send(wsFrame(.binary, [0, 1, 2, 255]), &h2)
            #expect(try await ws.next(&h2) == .init(opcode: .binary, payload: [0, 1, 2, 255]))

            // A fragmented message with a ping between its fragments.
            try await ws.send(wsFrame(.text, Array("frag".utf8), fin: false), &h2)
            try await ws.send(wsFrame(.ping, [7, 7]), &h2)
            try await ws.send(wsFrame(.continuation, Array("mented".utf8)), &h2)
            #expect(try await ws.next(&h2) == .init(opcode: .pong, payload: [7, 7]))
            #expect(try await ws.next(&h2) == .init(opcode: .text, payload: Array("fragmented".utf8)))

            // Client-initiated close: the server echoes 1000; both sides end the stream.
            try await ws.send(wsClose(1000), &h2)
            #expect(try await ws.next(&h2)?.closeCode == 1000)
            try await ws.send([], fin: true, &h2)
            #expect(try await ws.readsEndStream(&h2))
            #expect(ws.resetCode == nil)
            await record.ended.wait()

            // The connection still serves ordinary requests.
            let block = h2.requests.get("/after")
            try await h2.send(F.headers(3, block: block))
            let response = try await h2.response(on: 3)
            #expect(String(decoding: response.body, as: UTF8.self) == "hello /after")
        }
        #expect(record.snapshot.closeCodes == [.normalClosure])
        #expect(record.snapshot.paths == ["/ws"])
        #expect(record.snapshot.subprotocols == ["chat"])
    }

    @Test func serverInitiatedCloseEndsTheStream() async throws {
        let record = H2WSRecord()
        let chain = MiddlewareChain(middleware: WebSocketUpgrade(path: "/ws") { socket, _ in
            for await message in socket.messages {
                if case .text("bye") = message { try await socket.close(code: .policyViolation, reason: "done") }
            }
            record.state.withLock { $0.closeCodes.append(socket.closeCode) }
            record.ended.trigger()
        }, next: HelloHandler())
        try await withH2Connection(handler: chain) { h2 in
            try await h2.handshake()
            var ws = try await H2WebSocketClient.connect(&h2)
            try await ws.send(wsFrame(.text, Array("bye".utf8)), &h2)
            let close = try await ws.next(&h2)
            #expect(close?.closeCode == 1008)
            #expect(close.map { Array($0.payload.dropFirst(2)) } == Array("done".utf8))
            try await ws.send(wsClose(1008), fin: true, &h2)
            #expect(try await ws.readsEndStream(&h2))
            await record.ended.wait()

            // An unmasked client frame: Close 1002, then END_STREAM.
            var bad = try await H2WebSocketClient.connect(&h2, stream: 3)
            try await bad.send(wsFrame(.text, [0x41], masked: false), &h2)
            #expect(try await bad.next(&h2)?.closeCode == 1002)
            try await bad.send([], fin: true, &h2)
            #expect(try await bad.readsEndStream(&h2))
        }
        #expect(record.snapshot.closeCodes.first == .policyViolation)
    }

    @Test func peerResetIsAnAbnormalClosureAndTheStreamTaskEnds() async throws {
        let record = H2WSRecord()
        try await withH2Driver(configuration: Self.wsConfiguration, handler: echoChain(record)) { h2, driver in
            try await h2.handshake()
            var ws = try await H2WebSocketClient.connect(&h2)
            try await ws.send(wsFrame(.text, Array("x".utf8)), &h2)
            #expect(try await ws.next(&h2)?.payload == Array("x".utf8))
            try await h2.send(rstStream(1, .cancel))
            await record.ended.wait()
            #expect(record.snapshot.closeCodes == [.abnormalClosure], "\(record.snapshot.closeCodes)")
            try await eventually { driver.liveStreamTasks == 0 }
            #expect(driver.liveStreamTasks == 0)

            // END_STREAM with no Close frame: 1006 on the server, which ends its side too.
            var finOnly = try await H2WebSocketClient.connect(&h2, stream: 3)
            try await finOnly.send(wsFrame(.text, Array("y".utf8)), &h2)
            #expect(try await finOnly.next(&h2)?.payload == Array("y".utf8))
            try await finOnly.send([], fin: true, &h2)
            #expect(try await finOnly.readsEndStream(&h2))
            try await eventually { record.snapshot.closeCodes.count == 2 }
            #expect(record.snapshot.closeCodes.last == .abnormalClosure)
        }
    }

    @Test func closeTimeoutResetsTheStream() async throws {
        // The server closes and the client never answers: after the close timeout the
        // tunnel is closed abortively, which is RST_STREAM(CANCEL).
        let chain = MiddlewareChain(middleware: WebSocketUpgrade(
            path: "/ws", configuration: WebSocketConfiguration(closeTimeout: .milliseconds(100))
        ) { socket, _ in
            try await socket.close(code: .goingAway)
            for await _ in socket.messages {}
        }, next: HelloHandler())
        try await withH2Connection(handler: chain) { h2 in
            try await h2.handshake()
            var ws = try await H2WebSocketClient.connect(&h2)
            #expect(try await ws.next(&h2)?.closeCode == 1001)
            #expect(try await ws.next(&h2) == nil)
            #expect(ws.resetCode == .cancel)
        }
    }

    @Test func outboundFlowControlHoldsALargeMessageUntilTheClientCredits() async throws {
        let record = H2WSRecord()
        try await withH2Connection(handler: echoChain(record)) { h2 in
            try await h2.handshake()
            var ws = try await H2WebSocketClient.connect(&h2)
            ws.autoCredit = false
            let big = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
            try await ws.send(wsFrame(.binary, big), &h2)
            // The server may send only our initial window (65,535) of the echo.
            while ws.received < 65_535 { guard try await ws.pull(&h2) else { break } }
            #expect(ws.received == 65_535)
            await #expect(throws: TimedOut.self) { _ = try await ws.pull(&h2, timeout: .milliseconds(300)) }
            #expect(ws.received == 65_535)
            // Credit the rest: the whole message arrives.
            ws.autoCredit = true
            try await ws.credit(ws.received, &h2)
            #expect(try await ws.next(&h2)?.payload == big)
            try await ws.send(wsClose(1000), fin: true, &h2)
            #expect(try await ws.next(&h2)?.closeCode == 1000)
            #expect(try await ws.readsEndStream(&h2))
        }
    }

    @Test func inboundFlowControlStallsTheClientWhileTheApplicationDoesNotRead() async throws {
        let record = H2WSRecord()
        let gate = ShutdownSignal()
        // Small receive reads keep the session's own buffering well under the stream window.
        let configuration = WebSocketConfiguration(receiveSize: 4096)
        try await withH2Connection(handler: echoChain(record, configuration: configuration, gate: gate)) { h2 in
            try await h2.handshake()
            var ws = try await H2WebSocketClient.connect(&h2)
            try await ws.readHeaders(&h2)
            var messages: [[UInt8]] = []
            var wire: [UInt8] = []
            for i in 0..<16 {
                let message = [UInt8](repeating: UInt8(65 + i), count: 16_000)
                messages.append(message)
                wire += wsFrame(.binary, message)
            }
            // The application does not read: after one message waits for it and one more is
            // parsed, the server stops crediting, so the client cannot send everything.
            var sent = try await ws.sendWithinWindow(wire, &h2)
            while sent < wire.count {
                guard (try? await ws.pull(&h2, timeout: .milliseconds(300))) == true else { break }
                sent += try await ws.sendWithinWindow(Array(wire[sent...]), &h2)
            }
            #expect(sent < wire.count, "the client sent everything without the application reading")
            #expect(sent <= 2 * 65_535 + 4 * 16_100, "\(sent) bytes accepted")
            // The application reads: the rest flows and every message echoes.
            gate.trigger()
            if sent < wire.count { try await ws.send(Array(wire[sent...]), &h2) }
            for message in messages { #expect(try await ws.next(&h2)?.payload == message) }
            try await ws.send(wsClose(1000), fin: true, &h2)
            #expect(try await ws.next(&h2)?.closeCode == 1000)
            #expect(try await ws.readsEndStream(&h2))
        }
    }

    @Test func tunnelIsNotBoundByTheRequestBodyLimit() async throws {
        var configuration = Self.wsConfiguration
        configuration.maxRequestBodySize = 1024
        try await withH2Driver(configuration: configuration, handler: echoChain(H2WSRecord())) { h2, _ in
            try await h2.handshake()
            var ws = try await H2WebSocketClient.connect(&h2)
            for i in 0..<4 {
                let message = [UInt8](repeating: UInt8(65 + i), count: 4096)
                try await ws.send(wsFrame(.binary, message), &h2)
                #expect(try await ws.next(&h2)?.payload == message)
            }
            try await ws.send(wsClose(1000), fin: true, &h2)
            #expect(try await ws.next(&h2)?.closeCode == 1000)
            #expect(try await ws.readsEndStream(&h2))
        }
    }

    @Test func handshakeRejections() async throws {
        try await withH2Connection(handler: echoChain(H2WSRecord())) { h2 in
            try await h2.handshake()
            // Wrong version: 400 with the supported version, and the stream ends.
            var old = try await H2WebSocketClient.connect(&h2, stream: 1, extra: [("sec-websocket-version", "8")])
            try await old.readHeaders(&h2)
            #expect(old.status == "400")
            #expect(old.header("sec-websocket-version") == "13")
            #expect(old.finished)

            // Missing version: 400 as well.
            var none = try await H2WebSocketClient.connect(&h2, stream: 3, extra: [])
            try await none.readHeaders(&h2)
            #expect(none.status == "400")

            // Another :protocol on the WebSocket path: 400.
            var other = try await H2WebSocketClient.connect(&h2, stream: 5, pseudo: [
                (":method", "CONNECT"), (":protocol", "connect-udp"), (":scheme", "http"),
                (":path", "/ws"), (":authority", "localhost")])
            try await other.readHeaders(&h2)
            #expect(other.status == "400")

            // Extended CONNECT needs :scheme, :path and :authority: malformed otherwise.
            var stream: UInt32 = 7
            for missing in [":scheme", ":path", ":authority"] {
                let fields = [(":method", "CONNECT"), (":protocol", "websocket"), (":scheme", "http"),
                              (":path", "/ws"), (":authority", "localhost")].filter { $0.0 != missing }
                var ws = try await H2WebSocketClient.connect(&h2, stream: stream, pseudo: fields)
                try await ws.readHeaders(&h2)
                #expect(ws.headers == nil)
                #expect(ws.resetCode == .protocolError, "without \(missing)")
                stream += 2
            }

            // :protocol on a GET: malformed.
            var get = try await H2WebSocketClient.connect(&h2, stream: stream, pseudo: [
                (":method", "GET"), (":protocol", "websocket"), (":scheme", "http"),
                (":path", "/ws"), (":authority", "localhost")])
            try await get.readHeaders(&h2)
            #expect(get.resetCode == .protocolError)
            stream += 2

            // A CONNECT with :scheme and :path but no :protocol: malformed (RFC 9113 §8.5).
            var plain = try await H2WebSocketClient.connect(&h2, stream: stream, pseudo: [
                (":method", "CONNECT"), (":scheme", "http"), (":path", "/ws"), (":authority", "localhost")])
            try await plain.readHeaders(&h2)
            #expect(plain.resetCode == .protocolError)
            stream += 2

            // A plain CONNECT (:authority only) is not a WebSocket: the component passes it on.
            var proxy = try await H2WebSocketClient.connect(&h2, stream: stream, pseudo: [
                (":method", "CONNECT"), (":authority", "example.com:443")])
            try await proxy.readHeaders(&h2)
            #expect(proxy.status == "200")
            #expect(proxy.header("content-length") == "6")  // HelloHandler's "hello " with an empty path
            stream += 2

            // The connection survived every rejection.
            var ok = try await H2WebSocketClient.connect(&h2, stream: stream)
            try await ok.readHeaders(&h2)
            #expect(ok.status == "200")
            try await ok.send(wsClose(1000), fin: true, &h2)
            #expect(try await ok.next(&h2)?.closeCode == 1000)
        }
    }

    @Test func protocolPseudoHeaderIsMalformedWithoutTheSetting() async throws {
        // No WebSocket component: SETTINGS_ENABLE_CONNECT_PROTOCOL was not sent, so :protocol
        // is malformed (RFC 8441 §3).
        try await withH2Connection(handler: HelloHandler()) { h2 in
            try await h2.handshake()
            var ws = try await H2WebSocketClient.connect(&h2)
            try await ws.readHeaders(&h2)
            #expect(ws.headers == nil)
            #expect(ws.resetCode == .protocolError)
        }
    }

    @Test func requestsCarryTheConnectProtocol() async throws {
        let seen = Mutex<[(String, HTTPMethod)]>([])
        let handler = ClosureHandler { request in
            seen.withLock { $0.append((request.string(of: request.connectProtocol), request.method)) }
            return HTTPResponse(status: .notFound)
        }
        try await withH2Connection(configuration: Self.wsConfiguration, handler: handler) { h2 in
            try await h2.handshake()
            try await h2.send(F.headers(1, block: h2.requests.get("/plain")))
            _ = try await h2.response(on: 1)
            var ws = try await H2WebSocketClient.connect(&h2, stream: 3, path: "/elsewhere")
            try await ws.readHeaders(&h2)
            #expect(ws.status == "404")
        }
        let values = seen.withLock { $0 }
        #expect(values.map(\.0) == ["", "websocket"])
        #expect(values.map(\.1) == [.get, .connect])
    }

    @Test func shutdownClosesWebSocketsWith1001() async throws {
        let record = H2WSRecord()
        let shutdown = ShutdownSignal()
        try await withH2Connection(handler: echoChain(record), shutdown: shutdown) { h2 in
            try await h2.handshake()
            var ws = try await H2WebSocketClient.connect(&h2)
            try await ws.send(wsFrame(.text, Array("hi".utf8)), &h2)
            #expect(try await ws.next(&h2)?.payload == Array("hi".utf8))
            shutdown.trigger()
            #expect(try await ws.next(&h2)?.closeCode == 1001)
            try await ws.send(wsClose(1001), fin: true, &h2)
            #expect(try await ws.readsEndStream(&h2))
            await record.ended.wait()
        }
        #expect(record.snapshot.closeCodes == [.goingAway])
    }

    @Test func tunnelForAnOrdinaryRequestIs501() async throws {
        let handler = ClosureHandler { _ in HTTPResponse(status: .ok, body: .tunnel { _, _ in }) }
        try await withH2Connection(configuration: Self.wsConfiguration, handler: handler) { h2 in
            try await h2.handshake()
            try await h2.send(F.headers(1, block: h2.requests.get("/")))
            let response = try await h2.response(on: 1)
            #expect(response.head.first { $0.0 == ":status" }?.1 == "501")
        }
    }

    @Test func extendedConnectOverLoopbackTCP() async throws {
        let record = H2WSRecord()
        let listener = try TCPListener(configuration: .init(
            host: "127.0.0.1", port: 0, tcp: TCPConfiguration(allowLocalEndpointReuse: false)))
        let server = Server(configuration: ServerConfiguration(drainTimeout: .seconds(2)),
                            listeners: [listener], protocols: [HTTP2()], handler: echoChain(record))
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            defer { server.requestShutdown() }
            let port = try #require(try await server.waitUntilRunning().first?.port)
            let transport = try await TCPTransport.connect(host: "127.0.0.1", port: port)
            var h2 = H2Client(transport)
            try await h2.send(F.preface, F.settings())
            guard case .settings(let settings) = try await h2.nextFrame() else {
                Issue.record("first frame is not SETTINGS")
                return
            }
            #expect(settings.enableConnectProtocol == true)
            try await h2.send(F.settingsAck)
            var ws = try await H2WebSocketClient.connect(&h2)
            try await ws.readHeaders(&h2)
            #expect(ws.status == "200")
            let big = (0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
            try await ws.send(wsFrame(.binary, big), &h2)
            #expect(try await ws.next(&h2)?.payload == big)
            try await ws.send(wsFrame(.text, Array("over tcp".utf8)), &h2)
            #expect(try await ws.next(&h2) == .init(opcode: .text, payload: Array("over tcp".utf8)))
            try await ws.send(wsClose(1000), fin: true, &h2)
            #expect(try await ws.next(&h2)?.closeCode == 1000)
            #expect(try await ws.readsEndStream(&h2))
            await record.ended.wait()
            await transport.close(.normal)
            server.requestShutdown()
            try await group.waitForAll()
        }
        #expect(record.snapshot.closeCodes == [.normalClosure])
    }
}
