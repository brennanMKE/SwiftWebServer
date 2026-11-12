import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing
@testable import WebSockets

/// The session over an in-memory pair, without HTTP: the client side is driven by hand.
@Suite struct WebSocketSessionTests {
    final class Box<Value: Sendable>: Sendable {
        let value: Mutex<Value>
        init(_ value: Value) { self.value = Mutex(value) }
        var current: Value { value.withLock { $0 } }
        func set(_ newValue: Value) { value.withLock { $0 = newValue } }
    }

    /// Runs a session with `handler` on the server side of a pair and `client` on the other.
    func session(
        configuration: WebSocketConfiguration = WebSocketConfiguration(closeTimeout: .seconds(5)),
        serverTransport: InMemoryTransport.Configuration = .init(),
        handler: @escaping @Sendable (WebSocket) async throws -> Void,
        client: @Sendable (InMemoryTransport, InMemoryTransport) async throws -> Void
    ) async throws {
        let (clientSide, serverSide) = InMemoryTransport.makePair(server: serverTransport)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await WebSocket.run(over: serverSide, configuration: configuration, handler: handler)
            }
            try await client(clientSide, serverSide)
            try await group.waitForAll()
        }
        #expect(serverSide.isClosed)
    }

    func send(_ transport: InMemoryTransport, _ bytes: [UInt8]) async throws {
        try await transport.send(ByteBuffer(bytes: bytes), endOfStream: false)
    }

    @Test(.timeLimit(.minutes(1)))
    func echoAndClientInitiatedClose() async throws {
        let code = Box<WebSocketCloseCode?>(nil)
        try await session(handler: { socket in
            for await message in socket.messages { try await socket.send(message) }
            code.set(socket.closeCode)
        }) { client, _ in
            var reader = FrameReader(client)
            try await send(client, clientFrame(.text, "one") + clientFrame(.binary, [0, 1, 2]))
            #expect(try await reader.next() == ServerFrame(opcode: .text, fin: true, payload: Array("one".utf8)))
            #expect(try await reader.next() == ServerFrame(opcode: .binary, fin: true, payload: [0, 1, 2]))
            try await send(client, clientFrame(.close, closePayload(4001, Array("done".utf8))))
            // Echoed code, then the server closes the stream first.
            #expect(try await reader.next()?.closeCode == 4001)
            #expect(try await reader.readsEndOfStream())
            await client.close(.normal)
        }
        #expect(code.current == WebSocketCloseCode(rawValue: 4001))
    }

    @Test(.timeLimit(.minutes(1)))
    func serverInitiatedClose() async throws {
        let code = Box<WebSocketCloseCode?>(nil)
        let messagesAfterClose = Box(0)
        try await session(handler: { socket in
            try await socket.close(code: .goingAway, reason: "maintenance")
            // Sending after close fails.
            await #expect(throws: WebSocketError.closed) { try await socket.send(text: "late") }
            for await _ in socket.messages { messagesAfterClose.value.withLock { $0 += 1 } }
            code.set(socket.closeCode)
        }) { client, _ in
            var reader = FrameReader(client)
            let close = try await reader.next()
            #expect(close?.closeCode == 1001)
            #expect(close?.payload.dropFirst(2).elementsEqual("maintenance".utf8) == true)
            // A message that crossed the server's Close is dropped.
            try await send(client, clientFrame(.text, "crossing") + clientFrame(.close, closePayload(1001)))
            #expect(try await reader.readsEndOfStream())
            await client.close(.normal)
        }
        #expect(code.current == .goingAway)
        #expect(messagesAfterClose.current == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func closeTimesOutWhenThePeerNeverAnswers() async throws {
        let start = ContinuousClock.now
        try await session(configuration: WebSocketConfiguration(closeTimeout: .milliseconds(200)), handler: { socket in
            try await socket.close(code: .normalClosure)
            for await _ in socket.messages {}
            #expect(socket.closeCode == .abnormalClosure)
        }) { client, server in
            var reader = FrameReader(client)
            #expect(try await reader.next()?.closeCode == 1000)
            // Never answer; the server gives up after the timeout.
            while !server.isClosed { try await Task.sleep(for: .milliseconds(10)) }
            await client.close(.normal)
        }
        #expect(ContinuousClock.now - start >= .milliseconds(200))
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        ([0x81, 0x01, 0x41], 1002),                            // unmasked
        (clientFrame(.text, [0xC0, 0x80]), 1007),              // overlong
        (clientFrame(.continuation, [1]), 1002),               // no message to continue
        (clientFrame(.binary, Array(repeating: 0, count: 2000)), 1009),
        (clientFrame(.close, [3]), 1002),
        (clientFrame(.close, closePayload(1005)), 1002),
    ] as [([UInt8], UInt16)])
    func violationsCloseWithTheirCode(bytes: [UInt8], code: UInt16) async throws {
        let failure = Box<WebSocketCloseCode?>(nil)
        try await session(configuration: WebSocketConfiguration(maxFrameSize: 1000), handler: { socket in
            for await _ in socket.messages {}
            failure.set(socket.failureCode)
        }) { client, _ in
            var reader = FrameReader(client)
            try await send(client, bytes)
            #expect(try await reader.next()?.closeCode == code)
            #expect(try await reader.readsEndOfStream())
            await client.close(.normal)
        }
        #expect(failure.current?.rawValue == code)
    }

    @Test(.timeLimit(.minutes(1)))
    func pingsInterleavedWithFragmentsGetPongs() async throws {
        try await session(handler: { socket in
            for await message in socket.messages { try await socket.send(message) }
        }) { client, _ in
            var reader = FrameReader(client)
            try await send(client, clientFrame(.text, "frag", fin: false) + clientFrame(.ping, Array("p1".utf8)))
            #expect(try await reader.next() == ServerFrame(opcode: .pong, fin: true, payload: Array("p1".utf8)))
            try await send(client, clientFrame(.continuation, "ment", fin: false) + clientFrame(.ping, []))
            #expect(try await reader.next() == ServerFrame(opcode: .pong, fin: true, payload: []))
            try await send(client, clientFrame(.continuation, "ed", fin: true))
            #expect(try await reader.next() == ServerFrame(opcode: .text, fin: true, payload: Array("fragmented".utf8)))
            try await send(client, clientFrame(.close, closePayload(1000)))
            #expect(try await reader.next()?.closeCode == 1000)
            await client.close(.normal)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func applicationPingWaitsForThePong() async throws {
        let ponged = Box(false)
        try await session(handler: { socket in
            try await socket.ping(ByteBuffer(bytes: [7, 7]))
            ponged.set(true)
            try await socket.send(text: "after pong")
        }) { client, _ in
            var reader = FrameReader(client)
            let ping = try await reader.next()
            #expect(ping == ServerFrame(opcode: .ping, fin: true, payload: [7, 7]))
            #expect(!ponged.current)
            // An unrelated pong does not answer it.
            try await send(client, clientFrame(.pong, [1]))
            try await Task.sleep(for: .milliseconds(20))
            #expect(!ponged.current)
            try await send(client, clientFrame(.pong, [7, 7]))
            #expect(try await reader.next()?.payload == Array("after pong".utf8))
            #expect(try await reader.next()?.closeCode == 1000)
            try await send(client, clientFrame(.close, closePayload(1000)))
            await client.close(.normal)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func pingFailsWhenTheConnectionCloses() async throws {
        try await session(handler: { socket in
            await #expect(throws: WebSocketError.closed) { try await socket.ping() }
        }) { client, _ in
            var reader = FrameReader(client)
            #expect(try await reader.next()?.opcode == .ping)
            try await send(client, clientFrame(.close, closePayload(1000)))
            #expect(try await reader.next()?.closeCode == 1000)
            await client.close(.normal)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func handlerErrorClosesWith1011() async throws {
        struct Boom: Error {}
        try await session(handler: { _ in throw Boom() }) { client, _ in
            var reader = FrameReader(client)
            #expect(try await reader.next()?.closeCode == 1011)
            try await send(client, clientFrame(.close, closePayload(1011)))
            #expect(try await reader.readsEndOfStream())
            await client.close(.normal)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidCloseArgumentsThrow() async throws {
        try await session(handler: { socket in
            await #expect(throws: WebSocketError.invalidCloseCode(.abnormalClosure)) {
                try await socket.close(code: .abnormalClosure)
            }
            await #expect(throws: WebSocketError.closeReasonTooLong) {
                try await socket.close(code: .normalClosure, reason: String(repeating: "x", count: 124))
            }
            await #expect(throws: WebSocketError.pingPayloadTooLong) {
                try await socket.ping(ByteBuffer(bytes: Array(repeating: 0, count: 126)))
            }
        }) { client, _ in
            var reader = FrameReader(client)
            #expect(try await reader.next()?.closeCode == 1000)
            try await send(client, clientFrame(.close, closePayload(1000)))
            await client.close(.normal)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func slowReaderStopsTransportReads() async throws {
        let gate = ShutdownSignal()
        let received = Box(0)
        let messageSize = 64 * 1024
        let count = 40
        let serverTransport = InMemoryTransport.Configuration(bufferCapacity: 64 * 1024, segmentSize: 16 * 1024,
                                                              capturesSentBytes: false)
        try await session(serverTransport: serverTransport, handler: { socket in
            await gate.wait()
            for await message in socket.messages {
                guard case .binary(let bytes) = message, bytes.readableBytes == messageSize else {
                    Issue.record("unexpected message"); continue
                }
                received.value.withLock { $0 += 1 }
                if received.current == count { break }
            }
        }) { client, server in
            let frame = clientFrame(.binary, Array(repeating: 0xAB, count: messageSize))
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for _ in 0..<count { try await client.send(ByteBuffer(bytes: frame), endOfStream: false) }
                }
                // The application reads nothing: the session holds at most one message plus
                // one receive, the pipe fills up, and the client's send suspends.
                let deadline = ContinuousClock.now + .seconds(10)
                while server.suspendedPeerSenders == 0 && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(server.suspendedPeerSenders > 0, "the client never blocked")
                try await Task.sleep(for: .milliseconds(50))
                #expect(received.current == 0)
                #expect(server.inboundHighWaterMark <= serverTransport.bufferBound)
                gate.trigger()
                try await group.waitForAll()
            }
            var reader = FrameReader(client)
            #expect(try await reader.next()?.closeCode == 1000)
            try await send(client, clientFrame(.close, closePayload(1000)))
            await client.close(.normal)
        }
        #expect(received.current == count)
    }
}
