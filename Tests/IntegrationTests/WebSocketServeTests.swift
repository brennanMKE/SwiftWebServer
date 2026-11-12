import Foundation
import HTTPTestSupport
import Testing

/// `sws-bench serve --websocket-echo PATH` (#0108, #0109): a `URLSessionWebSocketTask` echo
/// against the child process, while plain HTTP keeps working on other paths.
@Suite struct WebSocketServeTests {
    @Test(.timeLimit(.minutes(1)))
    func websocketEchoFlag() async throws {
        let serve = try ChildProcess.launch(["serve", "--port", "0", "--drain-timeout", "0.5", "--websocket-echo", "/echo"])
        defer { serve.kill() }
        let port = try await serve.listeningPort()

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/echo")!)
        task.resume()
        try await task.send(.string("echo me"))
        guard case .string(let text) = try await task.receive() else { Issue.record("not text"); return }
        #expect(text == "echo me")
        let bytes = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0) })
        try await task.send(.data(bytes))
        guard case .data(let echoed) = try await task.receive() else { Issue.record("not binary"); return }
        #expect(echoed == bytes)
        task.cancel(with: .normalClosure, reason: nil)

        // Other paths still get the hello handler.
        let (body, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self) == "Hello, World!\n")

        serve.signal(SIGTERM)
        #expect(try await serve.waitForExit(timeout: .seconds(5)) == 0, "stderr: \(serve.stderr)")
    }

    @Test(.timeLimit(.minutes(1)))
    func websocketEchoNeedsAPath() async throws {
        let serve = try ChildProcess.launch(["serve", "--port", "0", "--websocket-echo", "echo"])
        defer { serve.kill() }
        #expect(try await serve.waitForExit(timeout: .seconds(10)) == 2)
        #expect(serve.stderr.contains("--websocket-echo"))
    }
}
