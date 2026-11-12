import Foundation
import HTTP1
import HTTPCore
import HTTPServer
import HTTPTestSupport
import NetworkTransport
import Synchronization
import Testing
import WebSockets

/// RFC 6455 against Apple's client: `URLSessionWebSocketTask` talking to a real server on
/// 127.0.0.1 port 0 (HTTP/1.1, `101`, then the WebSocket session over the TCP connection).
@Suite struct URLSessionWebSocketTests {
    /// What the server saw, for checks after a connection ends.
    final class Record: Sendable {
        struct State: Sendable {
            var closeCodes: [WebSocketCloseCode?] = []
            var closeReasons: [String] = []
            var finished = 0
        }
        let state = Mutex(State())
        var snapshot: State { state.withLock { $0 } }
    }

    /// Echoes every message. A text message `close:CODE` makes the server close with CODE.
    static func echoServer(_ record: Record) -> WebSocketUpgrade {
        WebSocketUpgrade(path: "/ws") { socket, _ in
            for await message in socket.messages {
                if case .text(let text) = message, text.hasPrefix("close:"), let code = UInt16(text.dropFirst(6)) {
                    try await socket.close(code: WebSocketCloseCode(rawValue: code), reason: "server says bye")
                    continue
                }
                try await socket.send(message)
            }
            record.state.withLock {
                $0.closeCodes.append(socket.closeCode)
                $0.closeReasons.append(socket.closeReason)
                $0.finished += 1
            }
        }
    }

    /// Runs a server with the echo component and calls `body` with its port.
    func withEchoServer(_ body: @Sendable (UInt16, Record) async throws -> Void) async throws {
        let record = Record()
        let listener = try TCPListener(configuration: TCPListener.Configuration(
            host: "127.0.0.1", port: 0, tcp: TCPConfiguration(allowLocalEndpointReuse: false)))
        let server = Server(configuration: ServerConfiguration(drainTimeout: .milliseconds(200)),
                            listeners: [listener], protocols: [HTTP1()]) {
            Self.echoServer(record)
            NotFoundHandler()
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.run() }
            defer { server.requestShutdown() }
            guard let port = try await server.waitUntilRunning().first?.port else {
                Issue.record("no address"); return
            }
            try await body(port, record)
            server.requestShutdown()
            try await group.waitForAll()
        }
    }

    func makeTask(port: UInt16) -> (URLSession, URLSessionWebSocketTask) {
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
        return (session, task)
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met in time"); return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func textBinaryAndLargeEcho() async throws {
        try await withEchoServer { port, record in
            let (session, task) = makeTask(port: port)
            defer { session.invalidateAndCancel() }

            try await task.send(.string("hello, wörld 👋"))
            guard case .string(let text) = try await task.receive() else { Issue.record("not text"); return }
            #expect(text == "hello, wörld 👋")

            let binary = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 * 7) })
            try await task.send(.data(binary))
            guard case .data(let echoed) = try await task.receive() else { Issue.record("not binary"); return }
            #expect(echoed == binary)

            // 1 MiB, which URLSession sends in several frames' worth of TCP segments.
            let large = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
            try await task.send(.data(large))
            guard case .data(let largeEcho) = try await task.receive() else { Issue.record("not binary"); return }
            #expect(largeEcho == large)

            let largeText = String(repeating: "ünïcødé ", count: 100_000)
            try await task.send(.string(largeText))
            guard case .string(let largeTextEcho) = try await task.receive() else { Issue.record("not text"); return }
            #expect(largeTextEcho == largeText)

            task.cancel(with: .normalClosure, reason: nil)
            try await waitUntil { record.snapshot.finished == 1 }
            #expect(record.snapshot.closeCodes == [.normalClosure])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func pingIsAnswered() async throws {
        try await withEchoServer { port, _ in
            let (session, task) = makeTask(port: port)
            defer { session.invalidateAndCancel() }
            // URLSessionWebSocketTask reads frames (pongs included) only while a receive is
            // outstanding, so one waits for the echo of the message sent after the pings.
            async let echo = task.receive()
            for _ in 0..<3 {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    task.sendPing { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
            // Still usable after the pings.
            try await task.send(.string("after pings"))
            guard case .string(let text) = try await echo else { Issue.record("not text"); return }
            #expect(text == "after pings")
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func clientInitiatedCloseIsSeenByTheServer() async throws {
        try await withEchoServer { port, record in
            let (session, task) = makeTask(port: port)
            defer { session.invalidateAndCancel() }
            try await task.send(.string("hi"))
            _ = try await task.receive()
            task.cancel(with: .goingAway, reason: Data("client leaving".utf8))
            try await waitUntil { record.snapshot.finished == 1 }
            #expect(record.snapshot.closeCodes == [.goingAway])
            #expect(record.snapshot.closeReasons == ["client leaving"])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func serverInitiatedCloseIsSeenByTheClient() async throws {
        try await withEchoServer { port, record in
            let (session, task) = makeTask(port: port)
            defer { session.invalidateAndCancel() }
            try await task.send(.string("close:1008"))
            // The next receive fails once the server's Close arrives.
            await #expect(throws: (any Error).self) { _ = try await task.receive() }
            try await waitUntil { task.closeCode != .invalid }
            #expect(task.closeCode == .policyViolation)
            #expect(task.closeReason.map { String(decoding: $0, as: UTF8.self) } == "server says bye")
            // The client echoed the Close; the server saw the handshake finish.
            try await waitUntil { record.snapshot.finished == 1 }
            #expect(record.snapshot.closeCodes == [.policyViolation])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func curlSeesTheRFCAcceptValue() async throws {
        try await withEchoServer { port, _ in
            let output = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"), [
                "-sv", "--http1.1", "--max-time", "2",
                "-H", "Upgrade: websocket", "-H", "Connection: Upgrade",
                "-H", "Sec-WebSocket-Version: 13", "-H", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
                "http://127.0.0.1:\(port)/ws",
            ], timeout: .seconds(20), mergeStandardError: true)
            #expect(output.stdout.contains("< HTTP/1.1 101 Switching Protocols"), "\(output.stdout)")
            #expect(output.stdout.lowercased().contains("< sec-websocket-accept: s3pplmbitxaq9kygzzhzrbk+xoo="), "\(output.stdout)")
            #expect(output.stdout.contains("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
        }
    }
}
