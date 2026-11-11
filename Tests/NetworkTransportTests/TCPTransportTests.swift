import Foundation
import HTTPCore
import Network
import NetworkTransport
import Synchronization
import Testing

/// Socket tests for the TCP adapter (#0078). Every listener binds 127.0.0.1 port 0, and every
/// test has a time limit (AGENTS.md). Run through `scripts/guarded.sh`.
@Suite struct TCPTransportTests {
    @Test(.timeLimit(.minutes(1)))
    func listenerBindsLoopbackOnPortZeroAndReportsPort() async throws {
        let listener = try await makeListener()
        #expect(listener.port != 0)
        #expect(listener.localAddress == TransportAddress(host: "127.0.0.1", port: listener.port))
        await listener.close()
        await listener.close()   // idempotent
    }

    @Test(.timeLimit(.minutes(1)))
    func echoRoundTripWithNWConnectionClient() async throws {
        let listener = try await makeListener()
        let client = RawClient(port: listener.port)
        try await client.start()
        let server = try await accept(listener)

        try await client.send(Array("hello".utf8))
        let received = try await receive(server, exactly: 5)
        #expect(received.bytes == Array("hello".utf8))
        try await server.send(received, endOfStream: false)
        #expect(await client.receive(exactly: 5) == Array("hello".utf8))

        // ConnectionInfo carries both addresses.
        #expect(server.info.localAddress == TransportAddress(host: "127.0.0.1", port: listener.port))
        #expect(server.info.remoteAddress?.host == "127.0.0.1")
        #expect(server.info.remoteAddress?.port != 0)
        #expect(server.info.isSecure == false)

        client.cancel()
        await server.close(.normal)
        await listener.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func echoRoundTripBetweenTwoTransports() async throws {
        let listener = try await makeListener()
        async let accepted = accept(listener)
        let client = try await TCPTransport.connect(host: "127.0.0.1", port: listener.port)
        let server = try await accepted
        #expect(client.info.remoteAddress == server.info.localAddress)
        #expect(client.info.localAddress == server.info.remoteAddress)

        for round in 0..<100 {
            var message = ByteBuffer()
            message.append(decimal: round)
            try await client.send(message, endOfStream: false)
            let echoed = try await receive(server, exactly: message.readableBytes)
            try await server.send(echoed, endOfStream: false)
            #expect(try await receive(client, exactly: message.readableBytes) == message)
        }
        await client.close(.normal)
        #expect(try await receive(server, exactly: 1).readableBytes == 0)   // FIN reached the server
        await server.close(.normal)
        await listener.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func peerEndOfStreamReturnsZeroAndIsSticky() async throws {
        let listener = try await makeListener()
        let client = RawClient(port: listener.port)
        try await client.start()
        let server = try await accept(listener)

        try await client.send(Array("abc".utf8), final: true)
        #expect(try await receive(server, exactly: 3).bytes == Array("abc".utf8))
        var buffer = ByteBuffer()
        #expect(try await server.receive(into: &buffer, maxLength: 16) == 0)
        #expect(try await server.receive(into: &buffer, maxLength: 16) == 0)

        // Half-close: the server can still answer, then finish its side.
        try await server.send(ByteBuffer("ok"), endOfStream: true)
        await #expect(throws: TransportError.outputShutdown) {
            try await server.send(ByteBuffer("x"), endOfStream: false)
        }
        var got: [UInt8] = []
        var complete = false
        while !complete {
            let (bytes, isComplete, error) = await client.receive()
            got += bytes
            complete = isComplete || error != nil
        }
        #expect(got == Array("ok".utf8))

        client.cancel()
        await server.close(.normal)
        await listener.close()
    }

    /// 100 MiB from a client to a server that does not read for a while: the client's sends
    /// stall instead of the bytes piling up in memory (no eager receive pump), then the server
    /// reads everything after the client's graceful close.
    @Test(.timeLimit(.minutes(1)))
    func largeTransferAppliesBackpressure() async throws {
        let listener = try await makeListener()
        async let accepted = accept(listener)
        let client = try await TCPTransport.connect(host: "127.0.0.1", port: listener.port)
        let server = try await accepted

        let total = 100 * 1024 * 1024
        let chunkSize = 64 * 1024
        var chunk = ByteBuffer(capacity: chunkSize)
        for i in 0..<chunkSize { chunk.append(UInt8(truncatingIfNeeded: i &* 31)) }
        let payload = chunk
        let acceptedBytes = Counter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var sent = 0
                while sent < total {
                    try await client.send(payload, endOfStream: false)
                    sent += chunkSize
                    acceptedBytes.value.store(sent, ordering: .relaxed)
                }
                await client.close(.normal)
            }

            // The server reads nothing: the sender must stall well short of 100 MiB.
            try await Task.sleep(for: .milliseconds(500))
            let first = acceptedBytes.value.load(ordering: .relaxed)
            try await Task.sleep(for: .milliseconds(300))
            let stalled = acceptedBytes.value.load(ordering: .relaxed)
            #expect(stalled == first, "sender kept making progress while nobody read")
            #expect(stalled < 32 * 1024 * 1024, "accepted \(stalled) bytes with no reader")
            print("TCPTransport backpressure: \(stalled) bytes accepted before the reader started")

            var buffer = ByteBuffer(capacity: 256 * 1024)
            var received = 0
            var checksum: UInt64 = 0
            while true {
                buffer.clear()
                let n = try await server.receive(into: &buffer, maxLength: 256 * 1024)
                if n == 0 { break }
                #expect(n <= 256 * 1024)
                buffer.withUnsafeReadableBytes { raw in
                    for byte in raw { checksum = checksum &* 31 &+ UInt64(byte) }
                }
                received += n
            }
            #expect(received == total)
            var expected: UInt64 = 0
            for _ in 0..<(total / chunkSize) {
                chunk.withUnsafeReadableBytes { raw in
                    for byte in raw { expected = expected &* 31 &+ UInt64(byte) }
                }
            }
            #expect(checksum == expected)
            try await group.waitForAll()
        }
        await server.close(.normal)
        await listener.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func abortiveCloseResetsThePeer() async throws {
        let listener = try await makeListener()
        async let accepted = accept(listener)
        let client = try await TCPTransport.connect(host: "127.0.0.1", port: listener.port)
        let server = try await accepted

        try await server.send(ByteBuffer("unsent?"), endOfStream: false)
        await server.close(.abort)
        await #expect(throws: TransportError.closed) {
            try await server.send(ByteBuffer("x"), endOfStream: false)
        }
        await #expect(throws: TransportError.closed) {
            var buffer = ByteBuffer()
            _ = try await server.receive(into: &buffer, maxLength: 1)
        }

        // The peer sees a reset, never a clean end of stream.
        var buffer = ByteBuffer()
        var outcome: Result<Int, any Error> = .success(1)
        while case .success(let n) = outcome, n > 0 {
            do { outcome = .success(try await client.receive(into: &buffer, maxLength: 1024)) }
            catch { outcome = .failure(error) }
        }
        guard case .failure(let error) = outcome else {
            Issue.record("abort looked like a graceful close")
            return
        }
        #expect(error as? TransportError == .connectionReset)
        await client.close(.normal)
        await listener.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingAPendingReceiveThrowsAndClosesTheConnection() async throws {
        let listener = try await makeListener()
        let client = RawClient(port: listener.port)
        try await client.start()
        let server = try await accept(listener)

        let task = Task {
            var buffer = ByteBuffer()
            return try await server.receive(into: &buffer, maxLength: 1024)
        }
        try await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: clock.now) < .seconds(1))

        // The connection is gone: later calls fail and the peer sees the close.
        await #expect(throws: TransportError.closed) {
            var buffer = ByteBuffer()
            _ = try await server.receive(into: &buffer, maxLength: 1)
        }
        let (_, isComplete, error) = await client.receive()
        #expect(isComplete || error != nil)

        await server.close(.normal)   // still safe after the cancellation
        client.cancel()
        await listener.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func secondConcurrentReceiveIsRejected() async throws {
        let listener = try await makeListener()
        let client = RawClient(port: listener.port)
        try await client.start()
        let server = try await accept(listener)

        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                var buffer = ByteBuffer()
                return try await server.receive(into: &buffer, maxLength: 8)
            }
            try await Task.sleep(for: .milliseconds(50))
            await #expect(throws: TransportError.receiveAlreadyPending) {
                var buffer = ByteBuffer()
                _ = try await server.receive(into: &buffer, maxLength: 8)
            }
            try await client.send([1, 2, 3])
            #expect(try await group.next() == 3)
        }
        client.cancel()
        await server.close(.normal)
        await listener.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func closeFailsAReceiveInProgress() async throws {
        let listener = try await makeListener()
        let client = RawClient(port: listener.port)
        try await client.start()
        let server = try await accept(listener)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await #expect(throws: TransportError.closed) {
                    var buffer = ByteBuffer()
                    _ = try await server.receive(into: &buffer, maxLength: 8)
                }
            }
            try await Task.sleep(for: .milliseconds(50))
            await server.close(.normal)
            try await group.waitForAll()
        }
        client.cancel()
        await listener.close()
    }

    /// Accepted connections beyond `pendingConnectionLimit` are cancelled, not buffered.
    @Test(.timeLimit(.minutes(1)))
    func listenerBoundsItsPendingAcceptQueue() async throws {
        let listener = try await makeListener(limit: 2)
        var clients: [RawClient] = []
        for _ in 0..<5 {
            let client = RawClient(port: listener.port)
            try await client.start()
            clients.append(client)
        }
        #expect(try await eventually { listener.rejectedConnectionCount == 3 })
        #expect(try await eventually { listener.pendingConnectionCount == 2 })

        // The two admitted connections work; the three rejected ones are closed.
        var iterator = listener.connections.makeAsyncIterator()
        var servers: [TCPTransport] = []
        for _ in 0..<2 {
            let server = try #require(try await iterator.next())
            try await server.send(ByteBuffer("x"), endOfStream: false)
            servers.append(server)
        }
        #expect(listener.pendingConnectionCount == 0)
        var served = 0
        var closed = 0
        for client in clients {
            let (bytes, isComplete, error) = await client.receive()
            if bytes == Array("x".utf8) { served += 1 } else if isComplete || error != nil { closed += 1 }
        }
        #expect(served == 2)
        #expect(closed == 3)

        // Once the queue has room, new connections are admitted again.
        let late = RawClient(port: listener.port)
        try await late.start()
        let lateServer = try #require(try await iterator.next())
        try await late.send([7])
        #expect(try await receive(lateServer, exactly: 1).bytes == [7])
        #expect(listener.rejectedConnectionCount == 3)

        for client in clients + [late] { client.cancel() }
        for server in servers + [lateServer] { await server.close(.normal) }
        await listener.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func twoListenersInOneProcess() async throws {
        let first = try await makeListener()
        let second = try await makeListener()
        #expect(first.port != second.port)

        for listener in [first, second] {
            async let accepted = accept(listener)
            let client = try await TCPTransport.connect(host: "127.0.0.1", port: listener.port)
            let server = try await accepted
            var message = ByteBuffer()
            message.append(decimal: listener.port)
            try await client.send(message, endOfStream: true)
            let got = try await receive(server, exactly: message.readableBytes)
            #expect(got == message)
            #expect(server.info.localAddress?.port == listener.port)
            await client.close(.normal)
            await server.close(.normal)
        }
        await first.close()
        await second.close()
    }

    /// The state handler is installed before `start`, so a connection that never becomes
    /// ready reports its failure instead of hanging (#0010).
    @Test(.timeLimit(.minutes(1)))
    func connectionThatFailsBeforeReadyReportsTheFailure() async throws {
        let listener = try await makeListener()
        let port = listener.port
        await listener.close()
        await #expect(throws: TransportError.self) {
            _ = try await TCPTransport.connect(host: "127.0.0.1", port: port)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func closingTheListenerEndsTheConnectionSequence() async throws {
        let listener = try await makeListener()
        try await withThrowingTaskGroup(of: TCPTransport?.self) { group in
            group.addTask {
                var iterator = listener.connections.makeAsyncIterator()
                return try await iterator.next()
            }
            try await Task.sleep(for: .milliseconds(50))
            await listener.close()
            let next = try await group.next()
            #expect(next != nil && next! == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingAcceptThrowsCancellation() async throws {
        let listener = try await makeListener()
        let task = Task {
            var iterator = listener.connections.makeAsyncIterator()
            return try await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        await listener.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func servesCurl() async throws {
        let curl = URL(fileURLWithPath: "/usr/bin/curl")
        try #require(FileManager.default.isExecutableFile(atPath: curl.path))
        let listener = try await makeListener()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let server = try await accept(listener)
                var request = ByteBuffer()
                // Read until the end of the request head.
                while !request.bytes.suffix(4).elementsEqual(Array("\r\n\r\n".utf8)) {
                    let n = try await server.receive(into: &request, maxLength: 4096)
                    if n == 0 { break }
                }
                #expect(request.bytes.starts(with: Array("GET /hello HTTP/1.1\r\n".utf8)))
                let response = ByteBuffer(
                    "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nhello\n")
                try await server.send(response, endOfStream: true)
                await server.close(.normal)
            }
            let output = try await runProcess(curl, ["-s", "--max-time", "10", "http://127.0.0.1:\(listener.port)/hello"])
            #expect(output == "hello\n")
            try await group.waitForAll()
        }
        await listener.close()
    }
}

final class Counter: Sendable {
    let value = Atomic<Int>(0)
}

/// Runs `executable` and returns its standard output.
private func runProcess(_ executable: URL, _ arguments: [String]) async throws -> String {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
        process.terminationHandler = { _ in continuation.resume() }
        do { try process.run() } catch { continuation.resume(throwing: error) }
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
}
