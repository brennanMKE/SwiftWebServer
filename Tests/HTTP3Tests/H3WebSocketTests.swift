import HTTP3
import HTTPCore
import HTTPTestSupport
import QPACK
import Synchronization
import Testing
import WebSockets

// #0111: WebSockets over HTTP/3 with extended CONNECT (RFC 9220), over the in-memory
// multiplexed transport, with an in-repo h3 WebSocket client.

/// A client WebSocket frame, masked.
func wsFrame(_ opcode: WSOpcode, _ payload: [UInt8], fin: Bool = true, rsv: UInt8 = 0, masked: Bool = true) -> [UInt8] {
    var buffer = ByteBuffer()
    WSFrameWriter.appendFrame(fin: fin, reservedBits: rsv, opcode: opcode, payload: ByteBuffer(bytes: payload),
                              maskKey: masked ? 0x1A2B_3C4D : nil, into: &buffer)
    return buffer.withUnsafeReadableBytes { Array($0) }
}

func wsClose(_ code: UInt16) -> [UInt8] {
    wsFrame(.close, [UInt8(code >> 8), UInt8(code & 0xFF)])
}

/// A stream that reports the peer's RESET_STREAM code.
protocol ResetCodeReporting: ByteStreamTransport {
    var receivedResetCode: UInt64? { get }
}

extension InMemoryMultiplexedTransport.Stream: ResetCodeReporting {}

/// The in-memory client used by most tests.
typealias H3WebSocketClient = H3WebSocketStreamClient<MuxStream>

/// The client side of one WebSocket over an h3 request stream: sends DATA frames carrying
/// WebSocket bytes and reads the response HEADERS, then WebSocket frames out of DATA.
final class H3WebSocketStreamClient<Stream: ResetCodeReporting> {
    struct Frame: Equatable {
        var opcode: WSOpcode
        var reservedBits: UInt8
        var payload: [UInt8]
        var closeCode: UInt16? {
            guard opcode == .close, payload.count >= 2 else { return nil }
            return UInt16(payload[0]) << 8 | UInt16(payload[1])
        }
    }

    let stream: Stream
    var h3 = H3FrameParser(configuration: .init(streamKind: .request, role: .client))
    var ws = WSFrameParser(configuration: .init(allowedReservedBits: 0x40, expectsMaskedFrames: false))
    var raw: [UInt8] = []
    var wsBytes = ByteBuffer()
    var payload = ByteBuffer()
    var header: WSFrameHeader?
    var headers: [(name: String, value: String)]?
    /// The server ended the stream (FIN).
    var finished = false
    /// The server reset the stream with this code.
    var resetCode: UInt64?

    init(stream: Stream) {
        self.stream = stream
    }

    /// Sends the extended CONNECT HEADERS on `stream` (no FIN).
    static func start(
        on stream: Stream, path: String = "/ws",
        extra: [(String, String)] = [("sec-websocket-version", "13")],
        pseudo: [(String, String)]? = nil
    ) async throws -> H3WebSocketStreamClient {
        let fields = pseudo ?? [(":method", "CONNECT"), (":protocol", "websocket"), (":scheme", "https"),
                                (":authority", "localhost"), (":path", path)]
        try await stream.send(ByteBuffer(bytes: H3Wire.headers(fields + extra)), endOfStream: false)
        return H3WebSocketStreamClient(stream: stream)
    }

    var status: String? { headers?.first { $0.name == ":status" }?.value }
    func header(_ name: String) -> String? { headers?.first { $0.name == name }?.value }

    func send(_ wsBytes: [UInt8], fin: Bool = false) async throws {
        try await stream.send(ByteBuffer(bytes: H3Wire.data(wsBytes)), endOfStream: fin)
    }

    /// Receives more bytes; false at FIN or reset.
    func pull() async -> Bool {
        guard !finished && resetCode == nil else { return false }
        var buffer = ByteBuffer()
        do {
            if try await stream.receive(into: &buffer, maxLength: 64 * 1024) == 0 {
                finished = true
                return false
            }
        } catch {
            resetCode = stream.receivedResetCode ?? 0
            return false
        }
        raw += buffer.withUnsafeReadableBytes { Array($0) }
        parseH3()
        return true
    }

    func parseH3() {
        let bytes = raw
        var offset = 0
        bytes.withUnsafeBytes { input in
            while offset < input.count {
                let rest = UnsafeRawBufferPointer(rebasing: input[offset...])
                guard let output = try? h3.parse(rest) else {
                    Issue.record("h3 frame error")
                    offset = input.count
                    return
                }
                switch output.event {
                case .headers(let location):
                    var decoder = QPACKDecoder(maxFieldSectionSize: 1 << 20)
                    var sink = CollectingSink()
                    h3.withPayload(location, in: rest) { section in _ = try? decoder.decode(section, into: &sink) }
                    if headers == nil { headers = sink.fields } else { Issue.record("trailers on a tunnel") }
                case .data(let range):
                    wsBytes.append(contentsOf: rest[range])
                default:
                    break
                }
                offset += output.consumed
                if output.consumed == 0 { break }
            }
        }
        raw = []
    }

    /// Waits for the response HEADERS.
    func readHeaders() async {
        while headers == nil { guard await pull() else { return } }
    }

    /// The next WebSocket frame from the server, or `nil` at FIN or reset.
    func next() async -> Frame? {
        while true {
            switch ws.parse(&wsBytes, payloadInto: &payload) {
            case .header(let h):
                header = h
                payload.clear()
            case .payload(_, let end):
                if end, let h = header {
                    header = nil
                    return Frame(opcode: h.opcode, reservedBits: h.reservedBits,
                                 payload: payload.withUnsafeReadableBytes { Array($0) })
                }
            case .needMoreBytes:
                wsBytes.discardReadBytes()
                guard await pull() else { return nil }
            case .error(let code):
                Issue.record("server WebSocket frame error \(code)")
                return nil
            }
        }
    }

    /// Reads to the end of the stream; true when it ended with FIN and nothing else came.
    func readsFIN() async -> Bool {
        while let frame = await next() { Issue.record("unexpected frame \(frame)") }
        return finished
    }
}

extension H3WebSocketStreamClient where Stream == MuxStream {
    static func connect(
        _ transport: InMemoryMultiplexedTransport, path: String = "/ws",
        extra: [(String, String)] = [("sec-websocket-version", "13")],
        pseudo: [(String, String)]? = nil
    ) async throws -> H3WebSocketClient {
        try await start(on: try await transport.openBidirectionalStream(), path: path, extra: extra, pseudo: pseudo)
    }
}

/// What the server-side WebSocket handler saw.
final class H3WSRecord: Sendable {
    struct State: Sendable {
        var closeCodes: [WebSocketCloseCode?] = []
        var compression: [PerMessageDeflate.Parameters?] = []
        var paths: [String] = []
    }
    let state = Mutex(State())
    let ended = Flag()
    var snapshot: State { state.withLock { $0 } }
}

func echoChain(_ record: H3WSRecord, configuration: WebSocketConfiguration = WebSocketConfiguration())
    -> MiddlewareChain<WebSocketUpgrade, PathHandler> {
    MiddlewareChain(middleware: WebSocketUpgrade(path: "/ws", configuration: configuration) { socket, request in
        // Echo until the connection ends (a send can fail once the peer is gone).
        for await message in socket.messages { try? await socket.send(message) }
        record.state.withLock {
            $0.closeCodes.append(socket.closeCode)
            $0.compression.append(socket.compression)
            $0.paths.append(request.path)
        }
        record.ended.set()
    }, next: PathHandler())
}

@Suite(.timeLimit(.minutes(1)))
struct H3WebSocketTests {
    @Test func settingsAdvertiseExtendedConnectWhenWebSocketsIsInTheChain() async throws {
        try await withH3Server(handler: echoChain(H3WSRecord())) { client, _ in
            var iterator = client.inboundStreams.makeAsyncIterator()
            let control = try #require(try await iterator.next())
            let expected = [0x00] + H3Wire.settings(H3Settings(
                qpackMaxTableCapacity: 0, maxFieldSectionSize: 16 * 1024, qpackBlockedStreams: 0,
                enableConnectProtocol: true))
            #expect(try await receive(expected.count, from: control) == expected)
        }
    }

    @Test func extendedConnectEchoAndCloseHandshake() async throws {
        let record = H3WSRecord()
        try await withH3Server(handler: echoChain(record)) { client, _ in
            let ws = try await H3WebSocketClient.connect(client)
            await ws.readHeaders()
            #expect(ws.status == "200")
            #expect(ws.header("sec-websocket-accept") == nil)
            #expect(ws.header("content-length") == nil)

            try await ws.send(wsFrame(.text, Array("héllo over h3".utf8)))
            #expect(await ws.next() == .init(opcode: .text, reservedBits: 0, payload: Array("héllo over h3".utf8)))
            // A 70 KB binary message, sent in several DATA frames and WebSocket fragments.
            let big = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }
            let frames = wsFrame(.binary, Array(big[..<30_000]), fin: false) + wsFrame(.continuation, Array(big[30_000...]))
            for start in stride(from: 0, to: frames.count, by: 16_000) {
                try await ws.send(Array(frames[start..<min(frames.count, start + 16_000)]))
            }
            #expect(await ws.next()?.payload == big)

            // Client-initiated close: the server echoes 1000, then FIN.
            try await ws.send(wsClose(1000))
            #expect(await ws.next()?.closeCode == 1000)
            try await ws.send([], fin: true)
            #expect(await ws.readsFIN())
            await record.ended.wait()
        }
        #expect(record.snapshot.closeCodes == [.normalClosure])
        #expect(record.snapshot.paths == ["/ws"])
    }

    @Test func serverInitiatedCloseAndProtocolViolation() async throws {
        let record = H3WSRecord()
        let chain = MiddlewareChain(middleware: WebSocketUpgrade(path: "/ws") { socket, _ in
            for await message in socket.messages {
                if case .text("bye") = message { try await socket.close(code: .policyViolation, reason: "done") }
            }
            record.state.withLock { $0.closeCodes.append(socket.closeCode) }
            record.ended.set()
        }, next: PathHandler())
        try await withH3Server(handler: chain) { client, _ in
            let ws = try await H3WebSocketClient.connect(client)
            try await ws.send(wsFrame(.text, Array("bye".utf8)))
            let close = await ws.next()
            #expect(close?.closeCode == 1008)
            #expect(close.map { Array($0.payload.dropFirst(2)) } == Array("done".utf8))
            try await ws.send(wsClose(1008), fin: true)
            #expect(await ws.readsFIN())
            await record.ended.wait()

            // An unmasked client frame: Close 1002, then FIN.
            let bad = try await H3WebSocketClient.connect(client)
            try await bad.send(wsFrame(.text, [0x41], masked: false))
            #expect(await bad.next()?.closeCode == 1002)
            try await bad.send([], fin: true)
            #expect(await bad.readsFIN())
        }
        #expect(record.snapshot.closeCodes.first == .policyViolation)
    }

    @Test func peerResetAndFINWithoutCloseAreAbnormalClosures() async throws {
        let record = H3WSRecord()
        let tracker = H3ConnectionTracker()
        try await withH3Server(handler: echoChain(record), tracker: tracker) { client, _ in
            let ws = try await H3WebSocketClient.connect(client)
            try await ws.send(wsFrame(.text, Array("x".utf8)))
            #expect(await ws.next()?.payload == Array("x".utf8))
            await ws.stream.reset(applicationError: HTTP3Error.requestCancelled.rawValue)
            await ws.stream.stopSending(applicationError: HTTP3Error.requestCancelled.rawValue)
            await record.ended.wait()
            #expect(record.snapshot.closeCodes == [.abnormalClosure], "\(record.snapshot.closeCodes)")
            try await waitUntil { tracker.liveRequestStreams == 0 && tracker.liveHandlers == 0 }

            // FIN with no Close frame: 1006 on the server, which ends its side with FIN.
            let finOnly = try await H3WebSocketClient.connect(client)
            try await finOnly.send(wsFrame(.text, Array("y".utf8)))
            #expect(await finOnly.next()?.payload == Array("y".utf8))
            try await finOnly.send([], fin: true)
            #expect(await finOnly.readsFIN())
            try await waitUntil { record.snapshot.closeCodes.count == 2 }
            #expect(record.snapshot.closeCodes.last == .abnormalClosure)

            // The connection still serves ordinary requests.
            let response = try await H3TestClient(transport: client).send(H3Wire.request(path: "/after"))
            #expect(response.bodyString == "hello /after")
        }
    }

    @Test func handshakeErrors() async throws {
        try await withH3Server(handler: echoChain(H3WSRecord())) { client, _ in
            // Wrong version: 400 with the supported version.
            let old = try await H3WebSocketClient.connect(client, extra: [("sec-websocket-version", "8")])
            await old.readHeaders()
            #expect(old.status == "400")
            #expect(old.header("sec-websocket-version") == "13")
            #expect(await old.readsFIN())

            // Another :protocol on the WebSocket path: 400.
            let other = try await H3WebSocketClient.connect(client, pseudo: [
                (":method", "CONNECT"), (":protocol", "connect-udp"), (":scheme", "https"),
                (":authority", "localhost"), (":path", "/ws")])
            await other.readHeaders()
            #expect(other.status == "400")

            // Extended CONNECT needs :scheme, :path and :authority: malformed otherwise.
            for missing in [":scheme", ":path", ":authority"] {
                let fields = [(":method", "CONNECT"), (":protocol", "websocket"), (":scheme", "https"),
                              (":authority", "localhost"), (":path", "/ws")].filter { $0.0 != missing }
                let stream = try await H3WebSocketClient.connect(client, pseudo: fields)
                await stream.readHeaders()
                #expect(stream.resetCode == HTTP3Error.messageError.rawValue, "without \(missing)")
            }
        }
    }

    @Test func protocolPseudoHeaderIsMalformedWithoutTheSetting() async throws {
        // No ExtendedConnectProvider in the chain: SETTINGS_ENABLE_CONNECT_PROTOCOL was not
        // sent, so :protocol is malformed (RFC 8441 §3, RFC 9220 §3).
        try await withH3Server(handler: PathHandler()) { client, _ in
            let ws = try await H3WebSocketClient.connect(client)
            await ws.readHeaders()
            #expect(ws.headers == nil)
            #expect(ws.resetCode == HTTP3Error.messageError.rawValue)
        }
    }

    @Test func requestsSeeHTTP3AndTheConnectProtocol() async throws {
        let seen = Mutex<[(HTTPVersion, String, HTTPMethod)]>([])
        let handler = ClosureHandler { request in
            seen.withLock { $0.append((request.version, request.string(of: request.connectProtocol), request.method)) }
            return HTTPResponse(status: .notFound)
        }
        try await withH3Server(handler: handler, configuration: H3Configuration(enableConnectProtocol: true)) { client, _ in
            _ = try await H3TestClient(transport: client).send(H3Wire.request(path: "/plain"))
            let ws = try await H3WebSocketClient.connect(client, path: "/elsewhere")
            await ws.readHeaders()
            #expect(ws.status == "404")
            #expect(await ws.readsFIN())
        }
        let values = seen.withLock { $0 }
        #expect(values.count == 2)
        #expect(values.allSatisfy { $0.0 == .http3 })
        #expect(values.map(\.1) == ["", "websocket"])
        #expect(values.map(\.2) == [.get, .connect])
    }

    @Test func tunnelIsNotBoundByTheRequestBodyLimit() async throws {
        let record = H3WSRecord()
        let configuration = H3Configuration(maxRequestBodySize: 1024)
        try await withH3Server(handler: echoChain(record), configuration: configuration) { client, _ in
            let ws = try await H3WebSocketClient.connect(client)
            for i in 0..<4 {
                let message = [UInt8](repeating: UInt8(65 + i), count: 4096)
                try await ws.send(wsFrame(.binary, message))
                #expect(await ws.next()?.payload == message)
            }
            try await ws.send(wsClose(1000), fin: true)
            #expect(await ws.next()?.closeCode == 1000)
            #expect(await ws.readsFIN())
        }
    }

    @Test func permessageDeflateOverHTTP3() async throws {
        let record = H3WSRecord()
        let chain = echoChain(record, configuration: WebSocketConfiguration(compression: PerMessageDeflate.Configuration()))
        try await withH3Server(handler: chain) { client, _ in
            let ws = try await H3WebSocketClient.connect(client, extra: [
                ("sec-websocket-version", "13"), ("sec-websocket-extensions", "permessage-deflate; client_max_window_bits")])
            await ws.readHeaders()
            #expect(ws.status == "200")
            #expect(ws.header("sec-websocket-extensions") == "permessage-deflate")
            // The "client" compresses with the same codec (client role: our window, its takeover).
            let compressor = try #require(PerMessageDeflate.Deflater(PerMessageDeflate.Parameters(minimumMessageSize: 0)))
            let inflater = try #require(PerMessageDeflate.Inflater(PerMessageDeflate.Parameters()))
            var scratch = ByteBuffer()
            for i in 0..<3 {
                let text = Array(#"{"n":\#(i),"msg":"compressed over a QUIC stream, compressed over a QUIC stream"}"#.utf8)
                let length = try #require(compressor.compress(ByteBuffer(bytes: text), into: &scratch))
                let payload = scratch.withUnsafeReadableBytes { Array($0[..<length]) }
                try await ws.send(wsFrame(.text, payload, rsv: 0x40))
                let echoed = try #require(await ws.next())
                #expect(echoed.reservedBits == 0x40)
                var inflated = ByteBuffer()
                try echoed.payload.withUnsafeBytes { bytes in try inflater.inflate(bytes, into: &inflated, limit: 1 << 20) }
                try inflater.finishMessage(into: &inflated, limit: 1 << 20)
                #expect(inflated.withUnsafeReadableBytes { Array($0) } == text)
            }
            try await ws.send(wsClose(1000), fin: true)
            #expect(await ws.next()?.closeCode == 1000)
            await record.ended.wait()
        }
        #expect(record.snapshot.compression.first??.serverMaxWindowBits == 15)
    }

    @Test func shutdownClosesWebSocketsWith1001AndTheConnectionDrains() async throws {
        let record = H3WSRecord()
        let shutdown = ShutdownSignal()
        let configuration = H3Configuration(timeouts: H3Timeouts(closeLinger: nil))
        try await withH3Server(handler: echoChain(record), configuration: configuration, shutdown: shutdown) { client, _ in
            let ws = try await H3WebSocketClient.connect(client)
            try await ws.send(wsFrame(.text, Array("hi".utf8)))
            #expect(await ws.next()?.payload == Array("hi".utf8))
            shutdown.trigger()
            #expect(await ws.next()?.closeCode == 1001)
            try await ws.send(wsClose(1001), fin: true)
            #expect(await ws.readsFIN())
            await record.ended.wait()
            // Every request below the GOAWAY finished: the server closes the connection.
            #expect(await serverCloseCode(client) == HTTP3Error.noError.rawValue)
        }
        #expect(record.snapshot.closeCodes == [.goingAway])
    }

    @Test func tunnelForAnOrdinaryRequestIs501() async throws {
        let handler = ClosureHandler { _ in HTTPResponse(status: .ok, body: .tunnel { _, _ in }) }
        try await withH3Server(handler: handler) { client, _ in
            let response = try await H3TestClient(transport: client).send()
            #expect(response.status == "501")
        }
    }
}
