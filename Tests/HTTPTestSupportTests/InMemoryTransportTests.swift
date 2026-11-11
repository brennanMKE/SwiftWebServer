import Foundation
import Testing
import HTTPCore
import HTTPTestSupport

/// Yields until `condition` holds (bounded by the suite's time limit).
private func waitUntil(_ condition: () -> Bool) async {
    while !condition() { await Task.yield() }
}

private func bytes(_ count: Int, seed: UInt8 = 0) -> ByteBuffer {
    ByteBuffer(bytes: (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

/// Receives until end of stream, returning the bytes and the size of each receive.
private func receiveAll(
    _ transport: InMemoryTransport, maxLength: Int = 64 * 1024
) async throws -> (ByteBuffer, [Int]) {
    var buffer = ByteBuffer()
    var sizes: [Int] = []
    while true {
        let n = try await transport.receive(into: &buffer, maxLength: maxLength)
        if n == 0 { return (buffer, sizes) }
        sizes.append(n)
    }
}

@Suite(.timeLimit(.minutes(1))) struct InMemoryTransportTests {
    // MARK: Round trip

    @Test func pairedEchoRoundTrip() async throws {
        let (client, server) = InMemoryTransport.makePair()
        let request = bytes(10_000)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // Echo server: send back whatever arrives, then half-close after the client's EOF.
                var buffer = ByteBuffer()
                while true {
                    buffer.clear()
                    let n = try await server.receive(into: &buffer, maxLength: 1500)
                    if n == 0 { break }
                    try await server.send(buffer, endOfStream: false)
                }
                try await server.send(ByteBuffer(), endOfStream: true)
            }
            group.addTask {
                try await client.send(request, endOfStream: true)
            }
            let (echoed, _) = try await receiveAll(client)
            #expect(echoed == request)
            try await group.waitForAll()
        }
        #expect(client.sentBytes == request)
        #expect(server.sentBytes == request)
        await client.close(.normal)
        await server.close(.normal)
    }

    @Test func infoIsReported() {
        let info = ConnectionInfo(
            remoteAddress: TransportAddress(host: "::1", port: 443), isSecure: true, negotiatedALPN: "h2")
        let transport = InMemoryTransport.scripted([], configuration: .init(info: info))
        #expect(transport.info == info)
        #expect(transport.info.remoteAddress?.description == "[::1]:443")
    }

    // MARK: Split patterns

    @Test(arguments: [
        InMemoryTransport.Chunking.unlimited,
        .bytewise,
        .fixed(2),
        .fixed(7),
        .pattern([1, 2, 3, 5, 8]),
        .pattern([13, 1]),
    ])
    func splitPatternDeliversEveryByteInOrder(_ chunking: InMemoryTransport.Chunking) async throws {
        let payload = bytes(1_000)
        let transport = InMemoryTransport.scripted(payload, configuration: .init(receiveChunking: chunking))
        let (received, sizes) = try await receiveAll(transport)
        #expect(received == payload)
        for (i, size) in sizes.enumerated() {
            switch chunking {
            case .unlimited: #expect(size == payload.readableBytes)
            case .fixed(let n): #expect(size <= n)
            case .pattern(let limits): #expect(size <= limits[i % limits.count])
            }
        }
        if chunking == .bytewise { #expect(sizes.count == payload.readableBytes) }
    }

    @Test func splitAtEveryOffset() async throws {
        let payload = bytes(64)
        for offset in 1..<payload.readableBytes {
            let transport = InMemoryTransport.scripted(
                payload, configuration: .init(receiveChunking: .pattern([offset, .max])))
            let (received, sizes) = try await receiveAll(transport)
            #expect(received == payload)
            #expect(sizes == [offset, payload.readableBytes - offset])
        }
    }

    @Test func maxLengthLimitsEachReceive() async throws {
        let transport = InMemoryTransport.scripted(bytes(100))
        let (received, sizes) = try await receiveAll(transport, maxLength: 30)
        #expect(received == bytes(100))
        #expect(sizes == [30, 30, 30, 10])
    }

    @Test func pairedSendsAreSegmented() async throws {
        let (client, server) = InMemoryTransport.makePair(server: .init(segmentSize: 100))
        async let sent: Void = client.send(bytes(250), endOfStream: true)
        let (received, sizes) = try await receiveAll(server)
        try await sent
        #expect(received == bytes(250))
        #expect(sizes == [100, 100, 50])
    }

    // MARK: EOF and half-close

    @Test func receiveReturnsZeroAtEndOfStreamAndStaysThere() async throws {
        let transport = InMemoryTransport.scripted(ByteBuffer("hello"))
        var buffer = ByteBuffer()
        #expect(try await transport.receive(into: &buffer, maxLength: 100) == 5)
        #expect(try await transport.receive(into: &buffer, maxLength: 100) == 0)
        #expect(try await transport.receive(into: &buffer, maxLength: 100) == 0)
        #expect(buffer == ByteBuffer("hello"))
    }

    @Test func exhaustedScriptIsEndOfStream() async throws {
        let transport = InMemoryTransport.scripted([.bytes(ByteBuffer("a"))])
        var buffer = ByteBuffer()
        #expect(try await transport.receive(into: &buffer, maxLength: 8) == 1)
        #expect(try await transport.receive(into: &buffer, maxLength: 8) == 0)
    }

    @Test func halfCloseKeepsTheOtherDirectionOpen() async throws {
        let (client, server) = InMemoryTransport.makePair()
        try await client.send(ByteBuffer("GET / HTTP/1.1\r\n\r\n"), endOfStream: true)
        let (request, _) = try await receiveAll(server)
        #expect(request == ByteBuffer("GET / HTTP/1.1\r\n\r\n"))
        // The server's direction is still open after the client's half-close.
        try await server.send(ByteBuffer("HTTP/1.1 200 OK\r\n\r\n"), endOfStream: true)
        let (response, _) = try await receiveAll(client)
        #expect(response == ByteBuffer("HTTP/1.1 200 OK\r\n\r\n"))
        await #expect(throws: TransportError.outputShutdown) {
            try await client.send(ByteBuffer("x"), endOfStream: false)
        }
    }

    @Test func gracefulCloseDeliversAcceptedBytesThenEOF() async throws {
        let (client, server) = InMemoryTransport.makePair()
        try await client.send(ByteBuffer("bye"), endOfStream: false)
        await client.close(.normal)
        let (received, _) = try await receiveAll(server)
        #expect(received == ByteBuffer("bye"))
        // The client no longer reads, so the server's sends are refused.
        await #expect(throws: TransportError.connectionReset) {
            try await server.send(ByteBuffer("late"), endOfStream: false)
        }
    }

    @Test func sendAndReceiveAfterCloseThrowClosed() async throws {
        let (client, _) = InMemoryTransport.makePair()
        await client.close(.normal)
        await client.close(.normal)   // idempotent
        #expect(client.isClosed)
        await #expect(throws: TransportError.closed) {
            try await client.send(ByteBuffer("x"), endOfStream: false)
        }
        var buffer = ByteBuffer()
        await #expect(throws: TransportError.closed) {
            _ = try await client.receive(into: &buffer, maxLength: 1)
        }
    }

    @Test func closeFailsAnOutstandingReceive() async throws {
        let (client, _) = InMemoryTransport.makePair()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var buffer = ByteBuffer()
                await #expect(throws: TransportError.closed) {
                    _ = try await client.receive(into: &buffer, maxLength: 1)
                }
            }
            for _ in 0..<10 { await Task.yield() }
            await client.close(.normal)
            try await group.waitForAll()
        }
    }

    @Test func abortResetsThePeerAndDiscardsBufferedBytes() async throws {
        let (client, server) = InMemoryTransport.makePair()
        try await client.send(ByteBuffer("never read"), endOfStream: false)
        #expect(server.inboundBufferedBytes == 10)
        await client.close(.abort)
        #expect(server.inboundBufferedBytes == 0)
        var buffer = ByteBuffer()
        await #expect(throws: TransportError.connectionReset) {
            _ = try await server.receive(into: &buffer, maxLength: 100)
        }
        #expect(buffer.isEmpty)
    }

    // MARK: Backpressure

    @Test func senderSuspendsWhenReaderStops() async throws {
        let configuration = InMemoryTransport.Configuration(bufferCapacity: 16, segmentSize: 4)
        let (client, server) = InMemoryTransport.makePair(server: configuration)
        let payload = bytes(64)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await client.send(payload, endOfStream: true) }
            // Four 4-byte slots fill; the fifth segment's sender suspends.
            await waitUntil { server.suspendedPeerSenders == 1 }
            #expect(server.inboundBufferedBytes == 20)
            #expect(client.sentBytes.readableBytes == 16)   // only accepted bytes are captured
            // Reading releases the sender.
            let (received, _) = try await receiveAll(server, maxLength: 3)
            #expect(received == payload)
            try await group.waitForAll()
        }
        #expect(server.inboundHighWaterMark <= configuration.bufferBound)
        #expect(client.sentBytes == payload)
    }

    @Test func oneMebibyteTransferStaysWithinBufferBound() async throws {
        let configuration = InMemoryTransport.Configuration(
            bufferCapacity: 8 * 1024, segmentSize: 1024, receiveChunking: .pattern([1, 700, 4096, 3]),
            capturesSentBytes: false)
        let (client, server) = InMemoryTransport.makePair(
            client: .init(capturesSentBytes: false), server: configuration)
        let total = 1 << 20
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // The writer hands over 64 KiB at a time; the pipe accepts only what fits.
                var offset = 0
                while offset < total {
                    try await client.send(bytes(64 * 1024, seed: UInt8(truncatingIfNeeded: offset >> 16)),
                                          endOfStream: false)
                    offset += 64 * 1024
                }
                try await client.send(ByteBuffer(), endOfStream: true)
            }
            var received = 0
            var checksum: UInt64 = 0
            var buffer = ByteBuffer(capacity: 8 * 1024)
            while true {
                buffer.clear()
                let n = try await server.receive(into: &buffer, maxLength: 8 * 1024)
                if n == 0 { break }
                #expect(server.inboundBufferedBytes <= configuration.bufferBound)
                buffer.withUnsafeReadableBytes { for byte in $0 { checksum &+= UInt64(byte) } }
                received += n
            }
            try await group.waitForAll()
            #expect(received == total)
            var expected: UInt64 = 0
            for chunk in 0..<16 {
                bytes(64 * 1024, seed: UInt8(chunk)).withUnsafeReadableBytes {
                    for byte in $0 { expected &+= UInt64(byte) }
                }
            }
            #expect(checksum == expected)
        }
        #expect(server.inboundHighWaterMark > 0)
        #expect(server.inboundHighWaterMark <= configuration.bufferBound)
        #expect(configuration.bufferBound == 10 * 1024)
    }

    // MARK: Cancellation

    @Test func cancellingAPendingReceiveThrowsAndFreesTheSlot() async throws {
        let (client, server) = InMemoryTransport.makePair()
        let reader = Task {
            var buffer = ByteBuffer()
            return try await server.receive(into: &buffer, maxLength: 16)
        }
        for _ in 0..<10 { await Task.yield() }
        reader.cancel()
        await #expect(throws: CancellationError.self) { _ = try await reader.value }
        // No continuation was left behind: a new receive gets the next bytes.
        try await client.send(ByteBuffer("after"), endOfStream: false)
        var buffer = ByteBuffer()
        #expect(try await server.receive(into: &buffer, maxLength: 16) == 5)
        #expect(buffer == ByteBuffer("after"))
    }

    @Test func cancellingADelayedReceiveThrows() async throws {
        let transport = InMemoryTransport.scripted([.delay(.seconds(30)), .bytes(ByteBuffer("x"))])
        let reader = Task {
            var buffer = ByteBuffer()
            return try await transport.receive(into: &buffer, maxLength: 16)
        }
        for _ in 0..<10 { await Task.yield() }
        reader.cancel()
        await #expect(throws: CancellationError.self) { _ = try await reader.value }
    }

    @Test func cancellingASuspendedSendThrowsAndReleasesItsBytes() async throws {
        let (client, server) = InMemoryTransport.makePair(server: .init(bufferCapacity: 8, segmentSize: 8))
        try await client.send(bytes(8), endOfStream: false)   // fills the only slot
        let writer = Task { try await client.send(bytes(8, seed: 1), endOfStream: false) }
        await waitUntil { server.suspendedPeerSenders == 1 }
        writer.cancel()
        await #expect(throws: CancellationError.self) { try await writer.value }
        #expect(server.suspendedPeerSenders == 0)
        #expect(server.inboundBufferedBytes == 8)
        #expect(client.sentBytes == bytes(8))
        // The cancelled bytes were never delivered.
        await client.close(.normal)
        let (received, _) = try await receiveAll(server)
        #expect(received == bytes(8))
    }

    @Test func concurrentReceiveIsRejected() async throws {
        let (client, server) = InMemoryTransport.makePair()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var buffer = ByteBuffer()
                _ = try await server.receive(into: &buffer, maxLength: 4)
            }
            for _ in 0..<10 { await Task.yield() }
            var buffer = ByteBuffer()
            await #expect(throws: TransportError.receiveAlreadyPending) {
                _ = try await server.receive(into: &buffer, maxLength: 4)
            }
            try await client.send(ByteBuffer("ok"), endOfStream: false)
            try await group.waitForAll()
        }
    }

    // MARK: Error injection and delays

    @Test func scriptedErrorIsStickyAfterPrecedingBytes() async throws {
        let transport = InMemoryTransport.scripted([.bytes(ByteBuffer("partial")), .error(.timedOut)])
        var buffer = ByteBuffer()
        #expect(try await transport.receive(into: &buffer, maxLength: 100) == 7)
        await #expect(throws: TransportError.timedOut) {
            _ = try await transport.receive(into: &buffer, maxLength: 100)
        }
        await #expect(throws: TransportError.timedOut) {
            _ = try await transport.receive(into: &buffer, maxLength: 100)
        }
    }

    @Test func playedErrorReachesThePeerInOrder() async throws {
        let (client, server) = InMemoryTransport.makePair()
        try await client.play([.bytes(ByteBuffer("ab")), .error(.connectionReset)])
        var buffer = ByteBuffer()
        #expect(try await server.receive(into: &buffer, maxLength: 100) == 2)
        await #expect(throws: TransportError.connectionReset) {
            _ = try await server.receive(into: &buffer, maxLength: 100)
        }
    }

    @Test func failNextSendThrowsOnceWithoutSending() async throws {
        let transport = InMemoryTransport.scripted([])
        transport.failNextSend(with: .failed(code: 32))
        await #expect(throws: TransportError.failed(code: 32)) {
            try await transport.send(ByteBuffer("lost"), endOfStream: false)
        }
        try await transport.send(ByteBuffer("kept"), endOfStream: false)
        #expect(transport.sentBytes == ByteBuffer("kept"))
    }

    @Test func scriptedDelayPausesTheReceiver() async throws {
        let transport = InMemoryTransport.scripted([
            .bytes(ByteBuffer("a")), .delay(.milliseconds(50)), .bytes(ByteBuffer("b")), .endOfStream,
        ])
        var buffer = ByteBuffer()
        #expect(try await transport.receive(into: &buffer, maxLength: 8) == 1)
        let start = ContinuousClock.now
        #expect(try await transport.receive(into: &buffer, maxLength: 8) == 1)
        #expect(ContinuousClock.now - start >= .milliseconds(50))
        #expect(try await transport.receive(into: &buffer, maxLength: 8) == 0)
        #expect(buffer == ByteBuffer("ab"))
    }

    @Test func playedDelayAndEndOfStream() async throws {
        let (client, server) = InMemoryTransport.makePair()
        try await client.play([.bytes(ByteBuffer("x")), .delay(.milliseconds(1)), .endOfStream])
        let (received, _) = try await receiveAll(server)
        #expect(received == ByteBuffer("x"))
        await #expect(throws: TransportError.outputShutdown) {
            try await client.play([.bytes(ByteBuffer("y"))])
        }
    }

    // MARK: sendFile default

    @Test func defaultSendFileStreamsATempFileRegionThroughThePair() async throws {
        let contents = bytes(200_003)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InMemoryTransportTests-\(UInt64.random(in: 0 ... .max)).bin")
        try contents.makeData().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try OwnedFileDescriptor.openForReading(path: url.path)
        #expect(try file.size() == 200_003)
        let region = FileRegion(file: file, offset: 7, length: 150_000)
        let (client, server) = InMemoryTransport.makePair(
            client: .init(bufferCapacity: 16 * 1024, segmentSize: 4 * 1024))
        async let sent: Void = {
            try await server.sendFile(region)
            try await server.send(ByteBuffer(), endOfStream: true)
        }()
        let (received, _) = try await receiveAll(client)
        try await sent
        var expected = ByteBuffer()
        expected.append(ByteView(offset: 7, length: 150_000), from: contents)
        #expect(received == expected)
        #expect(client.inboundHighWaterMark <= (16 + 8) * 1024)

        // The whole file, captured by a scripted endpoint.
        let sink = InMemoryTransport.scripted([])
        try await sink.sendFile(try FileRegion.entireFile(file))
        #expect(sink.sentBytes == contents)
    }
}
