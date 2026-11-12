import Foundation
import HTTPCore
import HTTPTestSupport
import Network
import NetworkTransport
import Synchronization
import Testing

/// Socket tests for the TCP adapters: Network.framework (#0078) and BSD sockets (#0113). Every
/// shared test runs against both. Every listener binds 127.0.0.1 port 0, and every test has a
/// time limit (AGENTS.md). Run through `scripts/guarded.sh`.
@Suite struct TCPTransportTests {
    @Test(.timeLimit(.minutes(1)), arguments: TCPKind.allCases)
    func listenerBindsLoopbackOnPortZeroAndReportsPort(_ kind: TCPKind) async throws {
        switch kind {
        case .nw: try await Self.listenerBindsLoopbackOnPortZeroAndReportsPort(TCPListener.self)
        case .bsd: try await Self.listenerBindsLoopbackOnPortZeroAndReportsPort(BSDSocketListener.self)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: TCPKind.allCases)
    func echoRoundTripWithNWConnectionClient(_ kind: TCPKind) async throws {
        switch kind {
        case .nw: try await Self.echoRoundTripWithNWConnectionClient(TCPListener.self)
        case .bsd: try await Self.echoRoundTripWithNWConnectionClient(BSDSocketListener.self)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: TCPKind.allCases)
    func echoRoundTripBetweenTwoTransports(_ kind: TCPKind) async throws {
        switch kind {
        case .nw: try await Self.echoRoundTripBetweenTwoTransports(TCPListener.self)
        case .bsd: try await Self.echoRoundTripBetweenTwoTransports(BSDSocketListener.self)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: TCPKind.allCases)
    func peerEndOfStreamReturnsZeroAndIsSticky(_ kind: TCPKind) async throws {
        switch kind {
        case .nw: try await Self.peerEndOfStreamReturnsZeroAndIsSticky(TCPListener.self)
        case .bsd: try await Self.peerEndOfStreamReturnsZeroAndIsSticky(BSDSocketListener.self)
        }
    }

    /// 100 MiB from a client to a server that does not read for a while: the client's sends
    /// stall instead of the bytes piling up in memory (no eager receive pump), then the server
    /// reads everything after the client's graceful close.
    @Test(.timeLimit(.minutes(1)), arguments: TCPKind.allCases)
    func largeTransferAppliesBackpressure(_ kind: TCPKind) async throws {
        switch kind {
        case .nw: try await Self.largeTransferAppliesBackpressure(TCPListener.self)
        case .bsd: try await Self.largeTransferAppliesBackpressure(BSDSocketListener.self)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: TCPKind.allCases)
    func abortiveCloseResetsThePeer(_ kind: TCPKind) async throws {
        switch kind {
        case .nw: try await Self.abortiveCloseResetsThePeer(TCPListener.self)
        case .bsd: try await Self.abortiveCloseResetsThePeer(BSDSocketListener.self)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: TCPKind.allCases)
    func cancellingAPendingReceiveThrowsAndClosesTheConnection(_ kind: TCPKind) async throws {
        switch kind {
        case .nw: try await Self.cancellingAPendingReceiveThrowsAndClosesTheConnection(TCPListener.self)
        case .bsd: try await Self.cancellingAPendingReceiveThrowsAndClosesTheConnection(BSDSocketListener.self)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: TCPKind.allCases)
    func secondConcurrentReceiveIsRejected(_ kind: TCPKind) async throws {
        switch kind {
        case .nw: try await Self.secondConcurrentReceiveIsRejected(TCPListener.self)
        case .bsd: try await Self.secondConcurrentReceiveIsRejected(BSDSocketListener.self)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: TCPKind.allCases)
    func closeFailsAReceiveInProgress(_ kind: TCPKind) async throws {
        switch kind {
        case .nw: try await Self.closeFailsAReceiveInProgress(TCPListener.self)
        case .bsd: try await Self.closeFailsAReceiveInProgress(BSDSocketListener.self)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: TCPKind.allCases)
    func twoListenersInOneProcess(_ kind: TCPKind) async throws {
        switch kind {
        case .nw: try await Self.twoListenersInOneProcess(TCPListener.self)
        case .bsd: try await Self.twoListenersInOneProcess(BSDSocketListener.self)
        }
    }

    /// The state handler is installed before `start`, so a connection that never becomes
    /// ready reports its failure instead of hanging (#0010).
    @Test(.timeLimit(.minutes(1)), arguments: TCPKind.allCases)
    func connectionThatFailsBeforeReadyReportsTheFailure(_ kind: TCPKind) async throws {
        switch kind {
        case .nw: try await Self.connectionThatFailsBeforeReadyReportsTheFailure(TCPListener.self)
        case .bsd: try await Self.connectionThatFailsBeforeReadyReportsTheFailure(BSDSocketListener.self)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: TCPKind.allCases)
    func closingTheListenerEndsTheConnectionSequence(_ kind: TCPKind) async throws {
        switch kind {
        case .nw: try await Self.closingTheListenerEndsTheConnectionSequence(TCPListener.self)
        case .bsd: try await Self.closingTheListenerEndsTheConnectionSequence(BSDSocketListener.self)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: TCPKind.allCases)
    func cancellingAcceptThrowsCancellation(_ kind: TCPKind) async throws {
        switch kind {
        case .nw: try await Self.cancellingAcceptThrowsCancellation(TCPListener.self)
        case .bsd: try await Self.cancellingAcceptThrowsCancellation(BSDSocketListener.self)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: TCPKind.allCases)
    func servesCurl(_ kind: TCPKind) async throws {
        switch kind {
        case .nw: try await Self.servesCurl(TCPListener.self)
        case .bsd: try await Self.servesCurl(BSDSocketListener.self)
        }
    }

    // MARK: Adapter-specific

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

    /// The BSD listener accepts only when asked: connections the kernel completed wait in the
    /// listen backlog (the bound), and nothing is taken until `next()` is called.
    @Test(.timeLimit(.minutes(1)))
    func bsdListenerAcceptsOnlyOnDemand() async throws {
        let listener = try await BSDSocketListener.makeStarted(limit: 8)
        var clients: [RawClient] = []
        for _ in 0..<3 {
            let client = RawClient(port: listener.port)
            try await client.start()   // the kernel completes the handshake from the backlog
            clients.append(client)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(listener.acceptedConnectionCount == 0)

        var iterator = listener.connections.makeAsyncIterator()
        var servers: [BSDSocketTransport] = []
        for (index, client) in clients.enumerated() {
            let server = try #require(try await iterator.next())
            #expect(listener.acceptedConnectionCount == index + 1)
            #expect(server.info.localAddress == listener.localAddress)
            #expect(server.info.remoteAddress?.host == "127.0.0.1")
            servers.append(server)
            try await client.send([UInt8(index)])
        }
        // Each server reads exactly its client's byte (accept order is completion order).
        var got: Set<UInt8> = []
        for server in servers { got.formUnion(try await receive(server, exactly: 1).bytes) }
        #expect(got == [0, 1, 2])

        for client in clients { client.cancel() }
        for server in servers { await server.close(.normal) }
        await listener.close()
        #expect(try await iterator.next() == nil)
    }

    // MARK: Shared bodies (run against both adapters)

    static func listenerBindsLoopbackOnPortZeroAndReportsPort<L: TestTCPListener>(_: L.Type) async throws {
        let listener = try await L.makeStarted(limit: 64)
        #expect(listener.port != 0)
        #expect(listener.localAddress == TransportAddress(host: "127.0.0.1", port: listener.port))
        await listener.close()
        await listener.close()   // idempotent
    }

    static func echoRoundTripWithNWConnectionClient<L: TestTCPListener>(_: L.Type) async throws {
        let listener = try await L.makeStarted(limit: 64)
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

    /// `sendFile` of an offset region (8 MiB, so the socket buffer fills and the sender waits
    /// for writability): the peer gets exactly the region's bytes. BSD sockets use
    /// `sendfile(2)` (#0084); Network.framework the bounded read loop. A region past the end of
    /// the file throws `unexpectedEndOfFile`.
    @Test(.timeLimit(.minutes(1)), arguments: TCPKind.allCases)
    func sendFileSendsTheRegion(_ kind: TCPKind) async throws {
        switch kind {
        case .nw: try await Self.sendFileSendsTheRegion(TCPListener.self)
        case .bsd: try await Self.sendFileSendsTheRegion(BSDSocketListener.self)
        }
    }

    static func sendFileSendsTheRegion<L: TestTCPListener>(_: L.Type) async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "sws-sendfile-\(UInt64.random(in: 0...UInt64.max)).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let size = 8 * 1024 * 1024
        let content = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 13) }
        try Data(content).write(to: url)
        let file = try OwnedFileDescriptor.openForReading(path: url.path)

        let listener = try await L.makeStarted(limit: 64)
        async let accepted = accept(listener)
        let client = try await L.Transport.testConnect(port: listener.port)
        let server = try await accepted
        let offset = 12_345
        let length = size - offset - 999
        async let received = receive(client, exactly: length)
        try await server.sendFile(FileRegion(file: file, offset: Int64(offset), length: Int64(length)))
        let bytes = try await received
        #expect(bytes.readableBytes == length)
        #expect(bytes.withUnsafeReadableBytes { Array($0) } == Array(content[offset..<(offset + length)]))

        await #expect(throws: TransportError.unexpectedEndOfFile) {
            try await server.sendFile(FileRegion(file: file, offset: Int64(size - 10), length: 20))
        }
        await client.close(.abort)
        await server.close(.normal)
        await listener.close()
    }

    static func echoRoundTripBetweenTwoTransports<L: TestTCPListener>(_: L.Type) async throws {
        let listener = try await L.makeStarted(limit: 64)
        async let accepted = accept(listener)
        let client = try await L.Transport.testConnect(port: listener.port)
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

    static func peerEndOfStreamReturnsZeroAndIsSticky<L: TestTCPListener>(_: L.Type) async throws {
        let listener = try await L.makeStarted(limit: 64)
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

    static func largeTransferAppliesBackpressure<L: TestTCPListener>(_: L.Type) async throws {
        let listener = try await L.makeStarted(limit: 64)
        async let accepted = accept(listener)
        let client = try await L.Transport.testConnect(port: listener.port)
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
            print("\(L.self) backpressure: \(stalled) bytes accepted before the reader started")

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

    static func abortiveCloseResetsThePeer<L: TestTCPListener>(_: L.Type) async throws {
        let listener = try await L.makeStarted(limit: 64)
        async let accepted = accept(listener)
        let client = try await L.Transport.testConnect(port: listener.port)
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

    static func cancellingAPendingReceiveThrowsAndClosesTheConnection<L: TestTCPListener>(_: L.Type) async throws {
        let listener = try await L.makeStarted(limit: 64)
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

    static func secondConcurrentReceiveIsRejected<L: TestTCPListener>(_: L.Type) async throws {
        let listener = try await L.makeStarted(limit: 64)
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

    static func closeFailsAReceiveInProgress<L: TestTCPListener>(_: L.Type) async throws {
        let listener = try await L.makeStarted(limit: 64)
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

    static func twoListenersInOneProcess<L: TestTCPListener>(_: L.Type) async throws {
        let first = try await L.makeStarted(limit: 64)
        let second = try await L.makeStarted(limit: 64)
        #expect(first.port != second.port)

        for listener in [first, second] {
            async let accepted = accept(listener)
            let client = try await L.Transport.testConnect(port: listener.port)
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

    static func connectionThatFailsBeforeReadyReportsTheFailure<L: TestTCPListener>(_: L.Type) async throws {
        let listener = try await L.makeStarted(limit: 64)
        let port = listener.port
        await listener.close()
        await #expect(throws: TransportError.self) {
            _ = try await L.Transport.testConnect(port: port)
        }
    }

    static func closingTheListenerEndsTheConnectionSequence<L: TestTCPListener>(_: L.Type) async throws {
        let listener = try await L.makeStarted(limit: 64)
        try await withThrowingTaskGroup(of: L.Transport?.self) { group in
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

    static func cancellingAcceptThrowsCancellation<L: TestTCPListener>(_: L.Type) async throws {
        let listener = try await L.makeStarted(limit: 64)
        let task = Task {
            var iterator = listener.connections.makeAsyncIterator()
            return try await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        await listener.close()
    }

    static func servesCurl<L: TestTCPListener>(_: L.Type) async throws {
        let curl = URL(fileURLWithPath: "/usr/bin/curl")
        try #require(FileManager.default.isExecutableFile(atPath: curl.path))
        let listener = try await L.makeStarted(limit: 64)

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

/// Runs `executable` and returns its standard output. A hard deadline and the test's time
/// limit (cancellation) SIGKILL it (#0114).
private func runProcess(_ executable: URL, _ arguments: [String]) async throws -> String {
    try await ChildProcess.run(executable, arguments, timeout: .seconds(30)).stdout
}
