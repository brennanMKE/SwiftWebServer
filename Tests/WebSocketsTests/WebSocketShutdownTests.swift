import Foundation
import HTTP1
import HTTPCore
import HTTPServer
import HTTPTestSupport
import NetworkTransport
import Synchronization
import Testing
@testable import WebSockets

/// #0116: a draining server closes open WebSockets with 1001 Going Away instead of letting
/// the drain deadline cut them off.
@Suite struct WebSocketShutdownTests {
    @Test(.timeLimit(.minutes(1)))
    func shutdownSendsGoingAwayOverHTTP1() async throws {
        let shutdown = ShutdownSignal()
        let ended = Mutex<WebSocketCloseCode?>(nil)
        let middleware = WebSocketUpgrade(path: "/ws") { socket, _ in
            for await message in socket.messages { try await socket.send(message) }
            ended.withLock { $0 = socket.closeCode }
        }
        try await withServer(middleware, request: handshake(), shutdown: shutdown) { client, head, leftover in
            #expect(head.status == 101)
            var reader = FrameReader(client, prefix: leftover)
            try await client.send(ByteBuffer(bytes: clientFrame(.text, "before")), endOfStream: false)
            #expect(try await reader.next()?.payload == Array("before".utf8))

            shutdown.trigger()
            let close = try await reader.next()
            #expect(close?.opcode == .close)
            #expect(close?.closeCode == 1001)
            // The client answers; the server ends the connection.
            try await client.send(ByteBuffer(bytes: clientFrame(.close, closePayload(1001))), endOfStream: false)
            #expect(try await reader.readsEndOfStream())
        }
        #expect(ended.withLock { $0 } == .goingAway)
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionWithoutShutdownSignalIgnoresIt() async throws {
        // `WebSocket.run` without a signal behaves as before: no Close until the handler ends.
        let (client, server) = InMemoryTransport.makePair()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await WebSocket.run(over: server) { socket in
                    for await message in socket.messages { try await socket.send(message) }
                }
            }
            var reader = FrameReader(client)
            try await client.send(ByteBuffer(bytes: clientFrame(.text, "x")), endOfStream: false)
            #expect(try await reader.next()?.payload == Array("x".utf8))
            try await client.send(ByteBuffer(bytes: clientFrame(.close, closePayload(1000))), endOfStream: true)
            #expect(try await reader.next()?.closeCode == 1000)
            #expect(try await reader.readsEndOfStream())
            try await group.waitForAll()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func urlSessionSeesGoingAwayAndTheServerStopsBeforeItsDeadline() async throws {
        let listener = try TCPListener(configuration: TCPListener.Configuration(
            host: "127.0.0.1", port: 0, tcp: TCPConfiguration(allowLocalEndpointReuse: false)))
        let serverCode = Mutex<WebSocketCloseCode?>(nil)
        // A long drain deadline: only the 1001 handshake can end the connection quickly.
        let server = Server(configuration: ServerConfiguration(drainTimeout: .seconds(20)),
                            listeners: [listener], protocols: [HTTP1()]) {
            WebSocketUpgrade(path: "/ws") { socket, _ in
                for await message in socket.messages { try await socket.send(message) }
                serverCode.withLock { $0 = socket.closeCode }
            }
            NotFoundHandler()
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.run() }
            defer { server.requestShutdown() }
            guard let port = try await server.waitUntilRunning().first?.port else {
                Issue.record("no address"); return
            }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
            task.resume()
            try await task.send(.string("hi"))
            _ = try await task.receive()

            let start = ContinuousClock.now
            async let pending = task.receive()
            server.requestShutdown()
            let failed: Bool
            do { _ = try await pending; failed = false } catch { failed = true }
            #expect(failed)
            try await group.waitForAll()
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .seconds(10), "server took \(elapsed) to drain")
            #expect(task.closeCode == .goingAway)
        }
        #expect(serverCode.withLock { $0 } == .goingAway)
    }
}
