import Foundation
import HTTP1
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing
@testable import WebSockets

/// A parsed HTTP/1.1 response head, for tests.
struct ResponseHead {
    var status: Int
    var fields: [(String, String)]

    func header(_ name: String) -> String? {
        fields.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    init?(_ text: String) {
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        self.status = status
        fields = lines.dropFirst().compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
    }
}

/// Runs the HTTP/1.1 runner with `middleware` in front of a 404 handler over an in-memory
/// pair, sends `request`, and hands the test the client side after the response head.
func withServer(
    _ middleware: WebSocketUpgrade,
    request: String,
    trailing: [UInt8] = [],
    serverConfiguration: InMemoryTransport.Configuration = .init(),
    shutdown: ShutdownSignal = ShutdownSignal(),
    _ body: @Sendable (InMemoryTransport, ResponseHead, ByteBuffer) async throws -> Void
) async throws {
    let (client, server) = InMemoryTransport.makePair(server: serverConfiguration)
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            await HTTP1().run(server, handler: MiddlewareChain(middleware: middleware, next: NotFoundHandler()),
                              context: ConnectionContext(info: server.info, shutdown: shutdown))
        }
        var request = ByteBuffer(bytes: Array(request.utf8) + trailing)
        try await client.send(request, endOfStream: false)
        request.clear()
        // Read the response head.
        var input = ByteBuffer()
        var headEnd: Int?
        while headEnd == nil {
            let n = try await client.receive(into: &input, maxLength: 4096)
            if n == 0 { break }
            let bytes = input.bytes
            headEnd = (0..<max(0, bytes.count - 3)).first {
                bytes[$0] == 13 && bytes[$0 + 1] == 10 && bytes[$0 + 2] == 13 && bytes[$0 + 3] == 10
            }
        }
        guard let end = headEnd else {
            Issue.record("no response head")
            await client.close(.normal)
            return
        }
        let headText = String(decoding: input.bytes[..<end], as: UTF8.self)
        input.moveReaderIndex(forwardBy: end + 4)
        guard let head = ResponseHead(headText) else {
            Issue.record("bad response head \(headText)")
            await client.close(.normal)
            return
        }
        try await body(client, head, input)
        await client.close(.normal)
        try await group.waitForAll()
    }
}

func handshake(path: String = "/ws", key: String = "dGhlIHNhbXBsZSBub25jZQ==", extra: String = "",
               method: String = "GET", version: String? = "13") -> String {
    var text = "\(method) \(path) HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n"
    text += "Sec-WebSocket-Key: \(key)\r\n"
    if let version { text += "Sec-WebSocket-Version: \(version)\r\n" }
    return text + extra + "\r\n"
}

let echo = WebSocketUpgrade(path: "/ws") { socket, _ in
    for await message in socket.messages { try await socket.send(message) }
}

/// The handshake through the HTTP/1.1 runner over an in-memory pair (`101`, replay, error
/// statuses, Origin and subprotocol hooks).
@Suite struct WebSocketUpgradeTests {
    @Test(.timeLimit(.minutes(1)))
    func handshakeAnswers101AndEchoes() async throws {
        try await withServer(echo, request: handshake()) { client, head, leftover in
            #expect(head.status == 101)
            #expect(head.header("Upgrade")?.lowercased() == "websocket")
            #expect(head.header("Connection")?.lowercased() == "upgrade")
            #expect(head.header("Sec-WebSocket-Accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
            #expect(head.header("Sec-WebSocket-Protocol") == nil)
            #expect(head.header("Content-Length") == nil)

            var reader = FrameReader(client, prefix: leftover)
            try await client.send(ByteBuffer(bytes: clientFrame(.text, "héllo")), endOfStream: false)
            #expect(try await reader.next() == ServerFrame(opcode: .text, fin: true, payload: Array("héllo".utf8)))
            try await client.send(ByteBuffer(bytes: clientFrame(.close, closePayload(1000))), endOfStream: false)
            #expect(try await reader.next()?.closeCode == 1000)
            #expect(try await reader.readsEndOfStream())
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func framesSentWithTheHandshakeAreReplayed() async throws {
        // The client pipelines a frame right behind the request: the tunnel replays it.
        try await withServer(echo, request: handshake(), trailing: clientFrame(.text, "early")) { client, head, leftover in
            #expect(head.status == 101)
            var reader = FrameReader(client, prefix: leftover)
            let frame = try await reader.next()
            #expect(frame?.payload == Array("early".utf8))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        (handshake(version: "8"), 426, "13"),
        (handshake(version: nil), 426, "13"),
        (handshake(key: "short"), 400, nil),
        (handshake(key: "dGhlIHNhbXBsZSBub25j"), 400, nil),                    // 15 bytes
        (handshake(key: "dGhlIHNhbXBsZSBub25jZQ==", extra: "Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\n"), 400, nil),
        (handshake(method: "POST"), 400, nil),
        ("GET /ws HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n", 426, nil),
        ("GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: keep-alive\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n", 400, nil),
    ] as [(String, Int, String?)])
    func malformedHandshakes(request: String, status: Int, version: String?) async throws {
        try await withServer(echo, request: request) { _, head, _ in
            #expect(head.status == status)
            #expect(head.header("Sec-WebSocket-Version") == version)
            if status == 426 { #expect(head.header("Upgrade") == "websocket") }
        }
    }

    /// #0117: `Upgrade` is ignored on HTTP/1.0 (RFC 9110 §7.8): `400` on the component's
    /// path, the next handler otherwise, never `101`.
    @Test(.timeLimit(.minutes(1)))
    func http10HandshakeIsRejected() async throws {
        let http10 = handshake().replacingOccurrences(of: "HTTP/1.1", with: "HTTP/1.0")
        try await withServer(echo, request: http10) { _, head, _ in
            #expect(head.status == 400)
            #expect(head.header("Sec-WebSocket-Accept") == nil)
        }
        let any = WebSocketUpgrade { _, _ in }
        try await withServer(any, request: http10) { _, head, _ in
            #expect(head.status == 404)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func otherPathsGoToTheNextHandler() async throws {
        try await withServer(echo, request: handshake(path: "/other")) { _, head, _ in
            #expect(head.status == 404)
        }
        // With no path, only upgrade requests are taken.
        let any = WebSocketUpgrade { _, _ in }
        try await withServer(any, request: "GET /page HTTP/1.1\r\nHost: x\r\n\r\n") { _, head, _ in
            #expect(head.status == 404)
        }
        try await withServer(any, request: handshake(path: "/anything")) { _, head, _ in
            #expect(head.status == 101)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func originHookRejectsWith403() async throws {
        let seen = Mutex<String?>(nil)
        let guarded = WebSocketUpgrade(path: "/ws", origin: { request in
            seen.withLock { $0 = request.origin }
            return request.origin == "https://good.example"
        }) { _, _ in }
        try await withServer(guarded, request: handshake(extra: "Origin: https://evil.example\r\n")) { _, head, _ in
            #expect(head.status == 403)
        }
        #expect(seen.withLock { $0 } == "https://evil.example")
        try await withServer(guarded, request: handshake(extra: "Origin: https://good.example\r\n")) { _, head, _ in
            #expect(head.status == 101)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func subprotocolNegotiation() async throws {
        let chosen = Mutex<String?>(nil)
        let middleware = WebSocketUpgrade(path: "/ws", subprotocol: { request in
            #expect(request.offeredSubprotocols == ["chat.v2", "chat.v1", "json"])
            return request.offeredSubprotocols.first { $0.hasPrefix("chat.v1") }
        }) { socket, request in
            chosen.withLock { $0 = socket.subprotocol }
            #expect(request.path == "/ws")
        }
        let offer = "Sec-WebSocket-Protocol: chat.v2, chat.v1\r\nSec-WebSocket-Protocol: json\r\n"
        try await withServer(middleware, request: handshake(extra: offer)) { client, head, leftover in
            #expect(head.status == 101)
            #expect(head.header("Sec-WebSocket-Protocol") == "chat.v1")
            var reader = FrameReader(client, prefix: leftover)
            // The handler returns at once: the server closes with 1000.
            #expect(try await reader.next()?.closeCode == 1000)
            try await client.send(ByteBuffer(bytes: clientFrame(.close, closePayload(1000))), endOfStream: false)
        }
        #expect(chosen.withLock { $0 } == "chat.v1")

        // A pick the client did not offer is ignored.
        let rogue = WebSocketUpgrade(path: "/ws", subprotocol: { _ in "nope" }) { _, _ in }
        try await withServer(rogue, request: handshake(extra: "Sec-WebSocket-Protocol: chat\r\n")) { _, head, _ in
            #expect(head.status == 101)
            #expect(head.header("Sec-WebSocket-Protocol") == nil)
        }
    }
}
