import HTTP1
import HTTP3
import HTTPCore
import HTTPServer
import HTTPTestSupport
import NetworkTransport
import Proxy
import Synchronization
import Testing
import WebSockets

// #0123: an RFC 9220 WebSocket from the in-repo h3 client, through ReverseProxy, to an
// HTTP/1.1 WebSocket echo server on 127.0.0.1:0.

private final class H3ProxiedRecord: Sendable {
    let closeCodes = Mutex<[WebSocketCloseCode?]>([])
}

/// Runs an HTTP/1.1 WebSocket echo server and calls `body` with a proxy chain in front of it.
private func withUpstreamEcho(
    _ body: @Sendable (MiddlewareChain<ReverseProxy, PathHandler>, H3ProxiedRecord) async throws -> Void
) async throws {
    let record = H3ProxiedRecord()
    let listener = try TCPListener(configuration: TCPListener.Configuration(
        host: "127.0.0.1", port: 0, tcp: TCPConfiguration(allowLocalEndpointReuse: false)))
    let server = Server(configuration: ServerConfiguration(drainTimeout: .milliseconds(200)),
                        listeners: [listener], protocols: [HTTP1()]) {
        WebSocketUpgrade(path: "/ws") { socket, _ in
            for await message in socket.messages {
                if case .text(let text) = message, text.hasPrefix("close:"), let code = UInt16(text.dropFirst(6)) {
                    try? await socket.close(code: WebSocketCloseCode(rawValue: code), reason: "bye")
                    continue
                }
                try? await socket.send(message)
            }
            record.closeCodes.withLock { $0.append(socket.closeCode) }
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
        try await body(MiddlewareChain(middleware: proxy, next: PathHandler()), record)
        server.requestShutdown()
        try await group.waitForAll()
    }
}

private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
}

@Suite(.timeLimit(.minutes(1)))
struct H3ProxyWebSocketTests {
    @Test func extendedConnectEchoesThroughTheProxy() async throws {
        try await withUpstreamEcho { chain, record in
            try await withH3Server(handler: chain) { client, _ in
                let ws = try await H3WebSocketClient.connect(client, path: "/ws")
                await ws.readHeaders()
                #expect(ws.status == "200")
                #expect(ws.header("sec-websocket-accept") == nil)
                #expect(ws.header("upgrade") == nil)

                try await ws.send(wsFrame(.text, Array("héllo over h3 via proxy".utf8)))
                #expect(await ws.next()?.payload == Array("héllo over h3 via proxy".utf8))

                // A 1 MB message in 16 KB DATA frames.
                let big = (0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }
                let frames = wsFrame(.binary, big)
                let stream = ws.stream
                async let sent: Void = {
                    for start in stride(from: 0, to: frames.count, by: 16_000) {
                        let piece = Array(frames[start..<min(frames.count, start + 16_000)])
                        try await stream.send(ByteBuffer(bytes: H3Wire.data(piece)), endOfStream: false)
                    }
                }()
                #expect(await ws.next()?.payload == big)
                try await sent

                // A client close reaches the upstream, whose close ends the stream.
                try await ws.send(wsClose(1000))
                #expect(await ws.next()?.closeCode == 1000)
                try await ws.send([], fin: true)
                #expect(await ws.readsFIN())
                try await eventually { record.closeCodes.withLock { $0.count } == 1 }
                #expect(record.closeCodes.withLock { $0 } == [.normalClosure])
            }
        }
    }

    @Test func upstreamCloseEndsTheStream() async throws {
        try await withUpstreamEcho { chain, record in
            try await withH3Server(handler: chain) { client, _ in
                let ws = try await H3WebSocketClient.connect(client, path: "/ws")
                try await ws.send(wsFrame(.text, Array("close:4002".utf8)))
                #expect(await ws.next()?.closeCode == 4002)
                try await ws.send(wsClose(4002), fin: true)
                #expect(await ws.readsFIN())
                try await eventually { record.closeCodes.withLock { $0.count } == 1 }
                #expect(record.closeCodes.withLock { $0 } == [WebSocketCloseCode(rawValue: 4002)])
            }
        }
    }
}
