import Foundation
import HTTP1
import HTTPCore
import HTTPServer
import NetworkTransport
@testable import Proxy
import Synchronization
import Testing
import WebSockets

// #0123: WebSocket / Upgrade passthrough over HTTP/1.1, against a real upstream WebSocket
// echo server on 127.0.0.1:0 and a proxy server on 127.0.0.1:0.

/// What the upstream WebSocket handler saw.
final class UpstreamWSRecord: Sendable {
    struct State: Sendable {
        var closeCodes: [WebSocketCloseCode?] = []
        var paths: [String] = []
        var forwardedFor: [String?] = []
        var finished = 0
    }
    let state = Mutex(State())
    var snapshot: State { state.withLock { $0 } }
}

/// Echoes every message on any path under /ws. `close:CODE` makes the server close with CODE.
func upstreamEcho(_ record: UpstreamWSRecord) -> WebSocketUpgrade {
    WebSocketUpgrade { socket, request in
        record.state.withLock {
            $0.paths.append(request.path)
            let h = request.headers
            $0.forwardedFor.append((0..<h.count).first { h.nameString(at: $0).lowercased() == "x-forwarded-for" }
                .map { h.valueString(at: $0) })
        }
        for await message in socket.messages {
            if case .text(let text) = message, text.hasPrefix("close:"), let code = UInt16(text.dropFirst(6)) {
                try? await socket.close(code: WebSocketCloseCode(rawValue: code), reason: "upstream bye")
                continue
            }
            try? await socket.send(message)
        }
        record.state.withLock {
            $0.closeCodes.append(socket.closeCode)
            $0.finished += 1
        }
    }
}

func loopbackListener() throws -> TCPListener {
    try TCPListener(configuration: TCPListener.Configuration(
        host: "127.0.0.1", port: 0, tcp: TCPConfiguration(allowLocalEndpointReuse: false)))
}

/// Runs an upstream echo server, then a proxy server in front of it, and calls `body` with
/// the proxy's port.
func withProxiedEcho(
    websocket: Bool = true,
    tunnel: ProxyTunnelConfiguration = ProxyTunnelConfiguration(),
    proxyDrain: Duration = .milliseconds(200),
    proxyShutdown: (@Sendable () -> Void)? = nil,
    _ body: @Sendable (_ proxyPort: UInt16, _ record: UpstreamWSRecord, _ stopProxy: @Sendable () -> Void) async throws -> Void
) async throws {
    let record = UpstreamWSRecord()
    let upstreamServer = Server(configuration: ServerConfiguration(drainTimeout: .milliseconds(200)),
                                listeners: [try loopbackListener()], protocols: [HTTP1()]) {
        upstreamEcho(record)
        NotFoundHandler()
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await upstreamServer.run() }
        defer { upstreamServer.requestShutdown() }
        guard let upstreamPort = try await upstreamServer.waitUntilRunning().first?.port else {
            Issue.record("no upstream address"); return
        }
        var proxy = ReverseProxy(mounts: [ProxyMount(
            path: "/ws", upstreams: [UpstreamTarget(address: .tcp(host: "127.0.0.1", port: upstreamPort))],
            websocket: websocket)], client: UpstreamHTTP1Client())
        proxy.tunnel = tunnel
        let proxyServer = Server(configuration: ServerConfiguration(drainTimeout: proxyDrain),
                                 listeners: [try loopbackListener()], protocols: [HTTP1()]) {
            proxy
            NotFoundHandler()
        }
        try await withThrowingTaskGroup(of: Void.self) { inner in
            inner.addTask { try await proxyServer.run() }
            defer { proxyServer.requestShutdown() }
            guard let proxyPort = try await proxyServer.waitUntilRunning().first?.port else {
                Issue.record("no proxy address"); return
            }
            try await body(proxyPort, record, { proxyServer.requestShutdown() })
            proxyServer.requestShutdown()
            try await inner.waitForAll()
        }
        upstreamServer.requestShutdown()
        try await group.waitForAll()
    }
}

func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else { Issue.record("condition not met in time"); return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// A raw HTTP/1.1 WebSocket client over a BSD socket.
struct RawWSClient {
    let transport: BSDSocketTransport
    var input = ByteBuffer()
    var parser = WSFrameParser(configuration: .init(expectsMaskedFrames: false))
    var payload = ByteBuffer()
    var header: WSFrameHeader?
    var sawEndOfStream = false

    static let key = "dGhlIHNhbXBsZSBub25jZQ=="

    /// Connects and sends a handshake; returns the client and the response head.
    static func connect(port: UInt16, path: String = "/ws/chat",
                        extra: String = "Upgrade: websocket\r\nConnection: Upgrade\r\n") async throws -> (RawWSClient, String) {
        let transport = try await BSDSocketTransport.connect(host: "127.0.0.1", port: port)
        var client = RawWSClient(transport: transport)
        let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\(extra)"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try await transport.send(ByteBuffer(bytes: Array(request.utf8)), endOfStream: false)
        let head = try await client.readHead()
        return (client, head)
    }

    mutating func readHead() async throws -> String {
        while true {
            let bytes = input.withUnsafeReadableBytes { Array($0) }
            if let end = UpstreamResponseParser.findHeadEnd(bytes) {
                input.moveReaderIndex(forwardBy: end)
                return String(decoding: bytes[..<end], as: UTF8.self)
            }
            guard try await fill() else { return String(decoding: bytes, as: UTF8.self) }
        }
    }

    mutating func fill() async throws -> Bool {
        _ = input.discardReadBytes()
        let n = try await transport.receive(into: &input, maxLength: 64 * 1024)
        if n == 0 { sawEndOfStream = true }
        return n > 0
    }

    func send(_ opcode: WSOpcode, _ bytes: [UInt8], fin: Bool = true) async throws {
        var buffer = ByteBuffer()
        WSFrameWriter.appendFrame(fin: fin, opcode: opcode, payload: ByteBuffer(bytes: bytes), maskKey: 0x1234_5678, into: &buffer)
        try await transport.send(buffer, endOfStream: false)
    }

    /// The next frame, or nil at end of stream.
    mutating func next() async throws -> (opcode: WSOpcode, payload: [UInt8])? {
        while true {
            switch parser.parse(&input, payloadInto: &payload) {
            case .needMoreBytes:
                if sawEndOfStream { return nil }
                guard try await fill() else { return nil }
            case .header(let h):
                header = h
                payload.clear()
            case .payload(_, let end):
                if end, let h = header {
                    header = nil
                    return (h.opcode, payload.withUnsafeReadableBytes { Array($0) })
                }
            case .error(let code):
                Issue.record("frame error \(code)")
                return nil
            }
        }
    }

    /// True when the proxy ends the stream (EOF or reset) within `timeout`.
    mutating func readsEnd(within timeout: Duration = .seconds(5)) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            do {
                guard let frame = try await next() else { return true }
                if frame.opcode != .close { Issue.record("unexpected frame \(frame.opcode)") }
            } catch {
                return true
            }
        }
        return false
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ProxyWebSocketTests {
    @Test func urlSessionEchoThroughTheProxy() async throws {
        try await withProxiedEcho { port, record, _ in
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws/echo")!)
            task.maximumMessageSize = 8 * 1024 * 1024
            task.resume()

            try await task.send(.string("hello through the proxy"))
            guard case .string(let text) = try await task.receive() else { Issue.record("not text"); return }
            #expect(text == "hello through the proxy")

            let binary = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 * 7) })
            try await task.send(.data(binary))
            guard case .data(let echoed) = try await task.receive() else { Issue.record("not binary"); return }
            #expect(echoed == binary)

            // 4 MiB: far more than the splice buffer and the socket buffers, so each hop's
            // sends wait for the next hop to read (backpressure) on the way up and down.
            let large = Data((0..<(4 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
            try await task.send(.data(large))
            guard case .data(let largeEcho) = try await task.receive() else { Issue.record("not binary"); return }
            #expect(largeEcho == large)

            // A close from the client reaches the upstream.
            task.cancel(with: .normalClosure, reason: nil)
            try await waitFor { record.snapshot.finished == 1 }
            #expect(record.snapshot.closeCodes == [.normalClosure])
            #expect(record.snapshot.paths == ["/ws/echo"])
            #expect(record.snapshot.forwardedFor == ["127.0.0.1"])
        }
    }

    @Test func upstreamCloseReachesTheClient() async throws {
        try await withProxiedEcho { port, record, _ in
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
            task.resume()
            try await task.send(.string("close:4001"))
            await #expect(throws: (any Error).self) { _ = try await task.receive() }
            #expect(task.closeCode.rawValue == 4001)
            try await waitFor { record.snapshot.finished == 1 }
            #expect(record.snapshot.closeCodes == [WebSocketCloseCode(rawValue: 4001)])
        }
    }

    @Test func rawHandshakeHeadersAndLargeEcho() async throws {
        try await withProxiedEcho { port, record, _ in
            var (client, head) = try await RawWSClient.connect(port: port)
            let lower = head.lowercased()
            #expect(head.hasPrefix("HTTP/1.1 101"))
            #expect(lower.contains("upgrade: websocket"))
            #expect(lower.contains("connection: upgrade"))
            // RFC 6455 §1.3's sample key and accept: the upstream's answer reaches the client.
            #expect(head.contains("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))

            // 8 MiB in 64 KiB fragments, read back concurrently.
            let message = (0..<(8 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 13) }
            let sender = client
            async let sent: Void = {
                let piece = 64 * 1024
                for start in stride(from: 0, to: message.count, by: piece) {
                    let end = min(message.count, start + piece)
                    try await sender.send(start == 0 ? .binary : .continuation, Array(message[start..<end]),
                                          fin: end == message.count)
                }
            }()
            var received: [UInt8] = []
            while received.count < message.count {
                guard let frame = try await client.next() else { break }
                received += frame.payload
            }
            try await sent
            #expect(received == message)

            // Client Close: the upstream answers Close and ends; the proxy ends the client side.
            try await client.send(.close, [0x03, 0xE8])
            let close = try await client.next()
            #expect(close?.opcode == .close)
            #expect(try await client.readsEnd())
            await client.transport.close(.normal)
            try await waitFor { record.snapshot.finished == 1 }
        }
    }

    @Test func mountWithoutWebSocketStripsTheUpgrade() async throws {
        try await withProxiedEcho(websocket: false) { port, record, _ in
            // The upstream sees a plain GET on a WebSocket-only path and refuses it.
            let (client, head) = try await RawWSClient.connect(port: port)
            #expect(!head.hasPrefix("HTTP/1.1 101"), "\(head)")
            #expect(head.hasPrefix("HTTP/1.1 4"), "\(head)")
            await client.transport.close(.normal)
            #expect(record.snapshot.paths.isEmpty)
        }
    }

    @Test func otherUpgradeTokensAreStripped() async throws {
        try await withProxiedEcho { port, record, _ in
            let (client, head) = try await RawWSClient.connect(
                port: port, extra: "Upgrade: h2c\r\nConnection: Upgrade, HTTP2-Settings\r\nHTTP2-Settings: AAMAAABkAAQCAAAAAAIAAAAA\r\n")
            #expect(!head.hasPrefix("HTTP/1.1 101"), "\(head)")
            await client.transport.close(.normal)
            #expect(record.snapshot.paths.isEmpty)
        }
    }

    @Test func idleTunnelIsClosed() async throws {
        let tunnel = ProxyTunnelConfiguration(idleTimeout: .milliseconds(300))
        try await withProxiedEcho(tunnel: tunnel) { port, record, _ in
            var (client, head) = try await RawWSClient.connect(port: port)
            #expect(head.hasPrefix("HTTP/1.1 101"))
            try await client.send(.text, Array("ping".utf8))
            #expect(try await client.next()?.payload == Array("ping".utf8))
            let start = ContinuousClock.now
            #expect(try await client.readsEnd())
            #expect(ContinuousClock.now - start >= .milliseconds(250))
            await client.transport.close(.normal)
            try await waitFor { record.snapshot.finished == 1 }
        }
    }

    @Test func drainEndsTheTunnel() async throws {
        // A long drain deadline: the tunnel must end on the drain signal, not the deadline.
        try await withProxiedEcho(proxyDrain: .seconds(30)) { port, record, stopProxy in
            var (client, head) = try await RawWSClient.connect(port: port)
            #expect(head.hasPrefix("HTTP/1.1 101"))
            try await client.send(.text, Array("x".utf8))
            #expect(try await client.next()?.payload == Array("x".utf8))
            let start = ContinuousClock.now
            stopProxy()
            #expect(try await client.readsEnd())
            #expect(ContinuousClock.now - start < .seconds(5))
            await client.transport.close(.normal)
            try await waitFor { record.snapshot.finished == 1 }
        }
    }

    @Test func refusedUpstreamIs502() async throws {
        // Bind and close a listener to get a port nothing listens on.
        let listener = try BSDSocketListener()
        let port = try await listener.start()
        await listener.close()
        let proxy = ReverseProxy(mounts: [ProxyMount(path: "/ws", upstreams: [
            UpstreamTarget(address: .tcp(host: "127.0.0.1", port: port))], websocket: true)], client: UpstreamHTTP1Client())
        let server = Server(configuration: ServerConfiguration(drainTimeout: .milliseconds(200)),
                            listeners: [try loopbackListener()], protocols: [HTTP1()]) {
            proxy
            NotFoundHandler()
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.run() }
            defer { server.requestShutdown() }
            let proxyPort = try #require(try await server.waitUntilRunning().first?.port)
            let (client, head) = try await RawWSClient.connect(port: proxyPort)
            #expect(head.hasPrefix("HTTP/1.1 502"), "\(head)")
            await client.transport.close(.normal)
            server.requestShutdown()
            try await group.waitForAll()
        }
    }
}

@Suite struct ProxyUpgradeDecisionTests {
    func request(_ headers: [(String, String)]) -> ProxyTestRequest { ProxyTestRequest("/ws", headers: headers) }

    @Test func decisions() {
        let target = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: 9000))
        let on = ReverseProxy(mounts: [ProxyMount(path: "/", upstreams: [target], websocket: true)], client: FakeUpstreamClient())
        let off = ReverseProxy(mounts: [ProxyMount(path: "/", upstreams: [target])], client: FakeUpstreamClient())
        let ws = request([("Upgrade", "websocket"), ("Connection", "keep-alive, Upgrade")])
        #expect(on.upgradeDecision(ws.request, mount: on.mounts[0].config) == .upgrade(.http1(token: "websocket")))
        #expect(off.upgradeDecision(ws.request, mount: off.mounts[0].config) == .none)
        let noConnection = request([("Upgrade", "websocket")])
        #expect(on.upgradeDecision(noConnection.request, mount: on.mounts[0].config) == .none)
        let h2c = request([("Upgrade", "h2c"), ("Connection", "Upgrade")])
        #expect(on.upgradeDecision(h2c.request, mount: on.mounts[0].config) == .none)
        var allowing = on
        allowing.tunnel.allowedUpgradeProtocols = ["h2c"]
        #expect(allowing.upgradeDecision(h2c.request, mount: on.mounts[0].config) == .upgrade(.http1(token: "h2c")))

        #expect(on.extendedConnectProtocols == ["websocket"])
        #expect(off.extendedConnectProtocols.isEmpty)
    }

    @Test func webSocketKeyAndAccept() {
        // RFC 6455 §1.3.
        #expect(ProxyWebSocketKey.accept(forKey: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        let key = ProxyWebSocketKey.generate()
        #expect(key.count == 24 && key.hasSuffix("=="))
        #expect(ProxyWebSocketKey.base64(Array("foobar".utf8)) == "Zm9vYmFy")
        #expect(ProxyWebSocketKey.base64(Array("fo".utf8)) == "Zm8=")
    }
}
