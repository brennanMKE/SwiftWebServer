import Foundation
import HTTP1
import HTTPCore
import HTTPServer
import HTTPTestSupport
import NetworkTransport
import Synchronization
import Testing
@testable import WebSockets

/// permessage-deflate (#0110) against `URLSessionWebSocketTask`, which offers the extension
/// (a bare `permessage-deflate` on macOS 27, and it then compresses every message it sends).
@Suite struct URLSessionDeflateTests {
    final class Record: Sendable {
        struct State: Sendable {
            var offers: [String] = []
            var agreed: [PerMessageDeflate.Parameters?] = []
            var compressedReceived: [Int] = []
            var closeCodes: [WebSocketCloseCode?] = []
            var failures: [WebSocketCloseCode?] = []
        }
        let state = Mutex(State())
        var snapshot: State { state.withLock { $0 } }
    }

    func withServer(
        maxMessageSize: Int = 16 << 20,
        _ body: @Sendable (UInt16, Record) async throws -> Void
    ) async throws {
        let record = Record()
        let listener = try TCPListener(configuration: TCPListener.Configuration(
            host: "127.0.0.1", port: 0, tcp: TCPConfiguration(allowLocalEndpointReuse: false)))
        let configuration = WebSocketConfiguration(maxMessageSize: maxMessageSize,
                                                   compression: PerMessageDeflate.Configuration())
        let server = Server(configuration: ServerConfiguration(drainTimeout: .milliseconds(200)),
                            listeners: [listener], protocols: [HTTP1()]) {
            WebSocketUpgrade(path: "/ws", configuration: configuration, origin: { request in
                record.state.withLock {
                    $0.offers.append(request.headers.firstValueString(for: .secWebSocketExtensions) ?? "")
                }
                return true
            }) { socket, _ in
                for await message in socket.messages { try await socket.send(message) }
                record.state.withLock {
                    $0.agreed.append(socket.compression)
                    $0.compressedReceived.append(socket.compressedMessagesReceived)
                    $0.closeCodes.append(socket.closeCode)
                    $0.failures.append(socket.failureCode)
                }
            }
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
    func compressedTextAndBinaryEcho() async throws {
        try await withServer { port, record in
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
            task.maximumMessageSize = 8 << 20
            task.resume()

            var messages: [String] = []
            for i in 0..<50 {
                messages.append(#"{"id":\#(i),"type":"quote","symbol":"AAPL","bid":231.4\#(i % 10),"ask":231.5\#(i % 10),"venue":"XNAS"}"#)
            }
            for text in messages {
                try await task.send(.string(text))
                guard case .string(let echoed) = try await task.receive() else { Issue.record("not text"); return }
                #expect(echoed == text)
            }
            let large = String(repeating: "lorem ipsum dolor sit amet ", count: 40_000)   // ~1 MiB
            try await task.send(.string(large))
            guard case .string(let largeEcho) = try await task.receive() else { Issue.record("not text"); return }
            #expect(largeEcho == large)
            let binary = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 / 100) })
            try await task.send(.data(binary))
            guard case .data(let binaryEcho) = try await task.receive() else { Issue.record("not binary"); return }
            #expect(binaryEcho == binary)

            task.cancel(with: .normalClosure, reason: nil)
            try await waitUntil { record.snapshot.closeCodes.count == 1 }
            let state = record.snapshot
            #expect(state.offers.first?.contains("permessage-deflate") == true, "offered: \(state.offers)")
            #expect(state.agreed.first??.serverMaxWindowBits == 15)
            // URLSession compresses what it sends once the extension is agreed.
            #expect((state.compressedReceived.first ?? 0) > 0, "compressed messages: \(state.compressedReceived)")
            #expect(state.closeCodes == [.normalClosure])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func messageInflatingPastTheLimitClosesWith1009() async throws {
        try await withServer(maxMessageSize: 64 * 1024) { port, record in
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
            task.resume()
            try await task.send(.string("warm up, still well under the limit of the server"))
            _ = try await task.receive()
            // 1 MiB of one repeated byte compresses to about 1 KiB on the wire, under every
            // frame limit; only the inflated size is over.
            try await task.send(.data(Data(repeating: 0x41, count: 1 << 20)))
            let failed: Bool
            do { _ = try await task.receive(); failed = false } catch { failed = true }
            #expect(failed)
            try await waitUntil { task.closeCode != .invalid }
            #expect(task.closeCode == .messageTooBig)
            try await waitUntil { record.snapshot.failures.count == 1 }
            #expect(record.snapshot.failures == [.messageTooBig])
        }
    }
}
