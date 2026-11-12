import HTTP1
@testable import HTTP2
import HTTPCore
import HTTPServer
import NetworkTransport
import Proxy
import Synchronization
import Testing
import WebSockets

// #0123: an RFC 8441 WebSocket from the in-repo h2 client, through ReverseProxy, to an
// HTTP/1.1 WebSocket echo server on 127.0.0.1:0.

private func wsFrame(_ opcode: WSOpcode, _ payload: [UInt8], fin: Bool = true) -> [UInt8] {
    var buffer = ByteBuffer()
    WSFrameWriter.appendFrame(fin: fin, opcode: opcode, payload: ByteBuffer(bytes: payload),
                              maskKey: 0x0BAD_F00D, into: &buffer)
    return buffer.withUnsafeReadableBytes { Array($0) }
}

private final class ProxiedRecord: Sendable {
    let state = Mutex<(closeCodes: [WebSocketCloseCode?], keys: [String])>(([], []))
}

/// Runs an HTTP/1.1 WebSocket echo server and calls `body` with a proxy chain in front of it.
private func withUpstreamEcho(
    _ body: @Sendable (MiddlewareChain<ReverseProxy, HelloHandler>, ProxiedRecord) async throws -> Void
) async throws {
    let record = ProxiedRecord()
    let listener = try TCPListener(configuration: TCPListener.Configuration(
        host: "127.0.0.1", port: 0, tcp: TCPConfiguration(allowLocalEndpointReuse: false)))
    let server = Server(configuration: ServerConfiguration(drainTimeout: .milliseconds(200)),
                        listeners: [listener], protocols: [HTTP1()]) {
        WebSocketUpgrade(path: "/ws") { socket, request in
            let h = request.headers
            if let i = (0..<h.count).first(where: { h.nameString(at: $0).lowercased() == "sec-websocket-key" }) {
                record.state.withLock { $0.keys.append(h.valueString(at: i)) }
            }
            for await message in socket.messages {
                if case .text(let text) = message, text.hasPrefix("close:"), let code = UInt16(text.dropFirst(6)) {
                    try? await socket.close(code: WebSocketCloseCode(rawValue: code), reason: "bye")
                    continue
                }
                try? await socket.send(message)
            }
            record.state.withLock { $0.closeCodes.append(socket.closeCode) }
        }
        NotFoundHandler()
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await server.run() }
        defer { server.requestShutdown() }
        let port = try #require(try await server.waitUntilRunning().first?.port)
        let proxy = ReverseProxy(mounts: [ProxyMount(
            path: "/ws", upstreams: [UpstreamTarget(address: .tcp(host: "127.0.0.1", port: port))],
            websocket: true)], client: UpstreamHTTP1Client())
        try await body(MiddlewareChain(middleware: proxy, next: HelloHandler()), record)
        server.requestShutdown()
        try await group.waitForAll()
    }
}

private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
}

@Suite(.timeLimit(.minutes(1)))
struct H2ProxyWebSocketTests {
    @Test func extendedConnectEchoesThroughTheProxy() async throws {
        try await withUpstreamEcho { chain, record in
            try await withH2Connection(handler: chain) { h2 in
                try await h2.send(F.preface, F.settings())
                guard case .settings(let settings) = try await h2.nextFrame() else {
                    Issue.record("first frame is not SETTINGS"); return
                }
                // ReverseProxy with a websocket mount is an ExtendedConnectProvider.
                #expect(settings.enableConnectProtocol == true)
                try await h2.send(F.settingsAck)

                var ws = try await H2WebSocketClient.connect(&h2, path: "/ws")
                try await ws.readHeaders(&h2)
                #expect(ws.status == "200")
                #expect(ws.header("sec-websocket-accept") == nil)
                #expect(ws.header("upgrade") == nil)
                #expect(ws.header("connection") == nil)

                try await ws.send(wsFrame(.text, Array("héllo via proxy".utf8)), &h2)
                #expect(try await ws.next(&h2) == .init(opcode: .text, payload: Array("héllo via proxy".utf8)))

                // Backpressure: without credit, only the initial window of the echo arrives,
                // so the proxy stops reading the upstream; credit lets the rest through.
                ws.autoCredit = false
                let base = ws.received
                let big = (0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
                try await ws.send(wsFrame(.binary, big), &h2)
                while ws.received < base + 65_535 { guard try await ws.pull(&h2) else { break } }
                let before = ws.received
                #expect(before == base + 65_535)
                await #expect(throws: TimedOut.self) { _ = try await ws.pull(&h2, timeout: .milliseconds(300)) }
                #expect(ws.received == before)
                ws.autoCredit = true
                try await ws.credit(ws.received - base, &h2)
                #expect(try await ws.next(&h2)?.payload == big)

                // A client close reaches the upstream, whose close ends the stream.
                try await ws.send(wsFrame(.close, [0x03, 0xE8]), &h2)
                #expect(try await ws.next(&h2)?.closeCode == 1000)
                try await ws.send([], fin: true, &h2)
                #expect(try await ws.readsEndStream(&h2))
                #expect(ws.resetCode == nil)
                try await eventually { record.state.withLock { $0.closeCodes.count } == 1 }
            }
        }
        // (record checked inside: the upstream saw a generated key and a normal close.)
    }

    @Test func upstreamCloseEndsTheStreamAndTheKeyIsGenerated() async throws {
        try await withUpstreamEcho { chain, record in
            try await withH2Connection(handler: chain) { h2 in
                try await h2.handshake()
                var ws = try await H2WebSocketClient.connect(&h2, path: "/ws")
                try await ws.send(wsFrame(.text, Array("close:4001".utf8)), &h2)
                #expect(try await ws.next(&h2)?.closeCode == 4001)
                try await ws.send(wsFrame(.close, [0x0F, 0xA1]), fin: true, &h2)
                #expect(try await ws.readsEndStream(&h2))
                try await eventually { record.state.withLock { $0.closeCodes.count } == 1 }
                #expect(record.state.withLock { $0.closeCodes } == [WebSocketCloseCode(rawValue: 4001)])
                let keys = record.state.withLock { $0.keys }
                #expect(keys.count == 1 && keys[0].count == 24)
            }
        }
    }

    @Test func nonWebSocketPathIsProxiedNormally() async throws {
        try await withUpstreamEcho { chain, _ in
            try await withH2Connection(handler: chain) { h2 in
                try await h2.handshake()
                // The upstream answers a CONNECT for a path it does not serve as a WebSocket.
                var ws = try await H2WebSocketClient.connect(&h2, path: "/ws/missing")
                try await ws.readHeaders(&h2)
                #expect(ws.status == "404")
            }
        }
    }
}
