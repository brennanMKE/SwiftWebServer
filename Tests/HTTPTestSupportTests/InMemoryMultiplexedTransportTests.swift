import Testing
import HTTPCore
import HTTPTestSupport

private typealias Mux = InMemoryMultiplexedTransport

/// Yields until `condition` holds (bounded by the time limit).
private func waitUntil(_ condition: () -> Bool) async {
    while !condition() { await Task.yield() }
}

private func bytes(_ count: Int, seed: UInt8 = 0) -> ByteBuffer {
    ByteBuffer(bytes: (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

/// Receives until end of stream, returning the bytes and the size of each receive.
private func receiveAll(
    _ stream: Mux.Stream, maxLength: Int = 64 * 1024
) async throws -> (ByteBuffer, [Int]) {
    var buffer = ByteBuffer()
    var sizes: [Int] = []
    while true {
        let n = try await stream.receive(into: &buffer, maxLength: maxLength)
        if n == 0 { return (buffer, sizes) }
        sizes.append(n)
    }
}

/// Takes the next inbound stream, failing the test if the sequence ended.
private func accept(_ transport: Mux) async throws -> Mux.Stream {
    var iterator = transport.inboundStreams.makeAsyncIterator()
    return try #require(try await iterator.next())
}

/// Echoes one stream: sends back what arrives, then FIN after the peer's FIN.
private func echo(_ stream: Mux.Stream) async throws {
    var buffer = ByteBuffer()
    while true {
        buffer.clear()
        let n = try await stream.receive(into: &buffer, maxLength: 1500)
        if n == 0 { break }
        try await stream.send(buffer, endOfStream: false)
    }
    try await stream.send(ByteBuffer(), endOfStream: true)
}

@Suite(.timeLimit(.minutes(1))) struct InMemoryMultiplexedTransportTests {
    // MARK: Stream IDs

    @Test(.timeLimit(.minutes(1))) func streamIDsFollowRFC9000() async throws {
        let (client, server) = Mux.makePair()
        var ids: [UInt64] = []
        for _ in 0..<3 { ids.append(try await client.openBidirectionalStream().streamID) }
        #expect(ids == [0, 4, 8])
        ids = []
        for _ in 0..<2 { ids.append(try await server.openBidirectionalStream().streamID) }
        #expect(ids == [1, 5])
        ids = []
        for _ in 0..<2 { ids.append(try await client.openUnidirectionalStream().streamID) }
        #expect(ids == [2, 6])
        ids = []
        for _ in 0..<3 { ids.append(try await server.openUnidirectionalStream().streamID) }
        #expect(ids == [3, 7, 11])

        let clientUni = client.openedStreams[3]
        #expect(clientUni.isUnidirectional && clientUni.isClientInitiated && clientUni.isLocallyInitiated)
        let serverBidi = server.openedStreams[0]
        #expect(!serverBidi.isUnidirectional && !serverBidi.isClientInitiated && serverBidi.isLocallyInitiated)

        // Each side sees the peer's streams, in the order they were opened, with the same IDs.
        var seenByServer: [UInt64] = []
        var iterator = server.inboundStreams.makeAsyncIterator()
        for _ in 0..<5 {
            let stream = try #require(try await iterator.next())
            #expect(!stream.isLocallyInitiated && stream.side == .server)
            seenByServer.append(stream.streamID)
        }
        #expect(seenByServer == [0, 4, 8, 2, 6])
        #expect(server.pendingInboundCount == 0)
        #expect(client.pendingInboundCount == 5)
        await client.close(applicationError: 0x100)
    }

    // MARK: Open / accept

    @Test(.timeLimit(.minutes(1))) func acceptWaitsForTheNextOpen() async throws {
        let (client, server) = Mux.makePair()
        try await withThrowingTaskGroup(of: UInt64.self) { group in
            group.addTask { try await accept(server).streamID }
            for _ in 0..<10 { await Task.yield() }
            #expect(server.pendingInboundCount == 0)
            let opened = try await client.openBidirectionalStream()
            #expect(try await group.next() == opened.streamID)
        }
        #expect(server.info.negotiatedALPN == "h3")
        #expect(server.info.isSecure)
        #expect(client.info.remoteAddress?.port == 443)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingAWaitingAcceptEndsIteration() async throws {
        let (_, server) = Mux.makePair()
        let acceptor = Task { () -> Mux.Stream? in
            var iterator = server.inboundStreams.makeAsyncIterator()
            return try await iterator.next()
        }
        for _ in 0..<10 { await Task.yield() }
        acceptor.cancel()
        #expect(try await acceptor.value == nil)
    }

    // MARK: Echo (mirrors the #0098 NW QUIC echo test)

    @Test(.timeLimit(.minutes(1))) func echoUniFINResetAndCloseLikeTheNWEchoTest() async throws {
        let (client, server) = Mux.makePair()
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Server: echo bidi streams, and answer with one server-opened uni stream.
            group.addTask {
                var iterator = server.inboundStreams.makeAsyncIterator()
                let request = try #require(try await iterator.next())
                try await echo(request)
                let uni = try await server.openUnidirectionalStream()
                try await uni.send(ByteBuffer("uni"), endOfStream: true)
                // Reset with a code observed by the peer.
                let resetMe = try #require(try await iterator.next())
                var buffer = ByteBuffer()
                _ = try await resetMe.receive(into: &buffer, maxLength: 64)
                await resetMe.reset(applicationError: 0x10c)
            }

            // Bidirectional echo with FIN in both directions.
            let stream = try await client.openBidirectionalStream()
            try await stream.send(ByteBuffer("echo\nhello "), endOfStream: false)
            try await stream.send(ByteBuffer("world"), endOfStream: true)
            let (echoed, _) = try await receiveAll(stream)
            #expect(echoed == ByteBuffer("echo\nhello world"))
            var empty = ByteBuffer()
            #expect(try await stream.receive(into: &empty, maxLength: 1) == 0)   // FIN is sticky

            // Server-opened uni stream: data then FIN; the receiving end cannot send.
            let uni = try await accept(client)
            #expect(uni.streamID == 3 && uni.isUnidirectional && !uni.canSend)
            let (uniBytes, _) = try await receiveAll(uni)
            #expect(uniBytes == ByteBuffer("uni"))
            await #expect(throws: TransportError.outputShutdown) {
                try await uni.send(ByteBuffer("x"), endOfStream: false)
            }

            // Reset: the peer's receive fails and its stream reads the code.
            let victim = try await client.openBidirectionalStream()
            try await victim.send(ByteBuffer("reset 10c\n"), endOfStream: false)
            var buffer = ByteBuffer()
            await #expect(throws: TransportError.connectionReset) {
                _ = try await victim.receive(into: &buffer, maxLength: 64)
            }
            #expect(victim.receivedResetCode == 0x10c)
            #expect(victim.receivedStopSendingCode == nil)
            try await group.waitForAll()
        }

        // Connection close with an application code.
        await server.close(applicationError: 0x101)
        #expect(server.closeApplicationError == 0x101)
        #expect(client.peerCloseApplicationError == 0x101)
        #expect(client.closeApplicationError == nil)
        var iterator = client.inboundStreams.makeAsyncIterator()
        #expect(try await iterator.next() == nil)
    }

    // MARK: FIN

    @Test(.timeLimit(.minutes(1))) func finHalfClosesOneDirectionOnly() async throws {
        let (client, server) = Mux.makePair()
        let stream = try await client.openBidirectionalStream()
        let peer = try await accept(server)
        try await stream.send(ByteBuffer("request"), endOfStream: true)
        let (request, _) = try await receiveAll(peer)
        #expect(request == ByteBuffer("request"))
        await #expect(throws: TransportError.outputShutdown) {
            try await stream.send(ByteBuffer("late"), endOfStream: false)
        }
        try await peer.send(ByteBuffer("response"), endOfStream: true)
        let (response, _) = try await receiveAll(stream)
        #expect(response == ByteBuffer("response"))
        #expect(stream.sentBytes == ByteBuffer("request"))
        #expect(peer.sentBytes == ByteBuffer("response"))
        #expect(stream.sentResetCode == nil && peer.receivedResetCode == nil)
    }

    @Test(.timeLimit(.minutes(1))) func localUniStreamReceivesEndOfStreamAtOnce() async throws {
        let (client, server) = Mux.makePair()
        let uni = try await client.openUnidirectionalStream()
        #expect(!uni.canReceive)
        var buffer = ByteBuffer()
        #expect(try await uni.receive(into: &buffer, maxLength: 8) == 0)
        try await uni.send(ByteBuffer("\u{0}settings"), endOfStream: false)
        let peer = try await accept(server)
        #expect(try await peer.receive(into: &buffer, maxLength: 64) == 9)
        #expect(buffer == ByteBuffer("\u{0}settings"))
    }

    // MARK: Reset and STOP_SENDING

    @Test(.timeLimit(.minutes(1))) func clientResetDiscardsUnreadBytesAndCarriesTheCode() async throws {
        let (client, server) = Mux.makePair()
        let stream = try await client.openBidirectionalStream()
        let peer = try await accept(server)
        try await stream.send(ByteBuffer("never read"), endOfStream: false)
        #expect(peer.inboundBufferedBytes == 10)
        await stream.reset(applicationError: 0x10c)
        #expect(peer.inboundBufferedBytes == 0)
        var buffer = ByteBuffer()
        await #expect(throws: TransportError.connectionReset) {
            _ = try await peer.receive(into: &buffer, maxLength: 64)
        }
        #expect(buffer.isEmpty)
        #expect(peer.receivedResetCode == 0x10c)
        #expect(stream.sentResetCode == 0x10c)
        await #expect(throws: TransportError.outputShutdown) {
            try await stream.send(ByteBuffer("x"), endOfStream: false)
        }
        // The other direction is unaffected by RESET_STREAM.
        try await peer.send(ByteBuffer("still open"), endOfStream: true)
        let (reply, _) = try await receiveAll(stream)
        #expect(reply == ByteBuffer("still open"))
    }

    @Test(.timeLimit(.minutes(1))) func serverResetFailsAPendingClientReceive() async throws {
        let (client, server) = Mux.makePair()
        let stream = try await client.openBidirectionalStream()
        let peer = try await accept(server)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var buffer = ByteBuffer()
                await #expect(throws: TransportError.connectionReset) {
                    _ = try await stream.receive(into: &buffer, maxLength: 64)
                }
            }
            for _ in 0..<10 { await Task.yield() }
            await peer.reset(applicationError: 0x10b)
            try await group.waitForAll()
        }
        #expect(stream.receivedResetCode == 0x10b)
        #expect(peer.sentResetCode == 0x10b)
    }

    @Test(.timeLimit(.minutes(1))) func stopSendingRefusesPeerSendsAndIsAnsweredWithReset() async throws {
        let (client, server) = Mux.makePair()
        let stream = try await client.openBidirectionalStream()
        let peer = try await accept(server)
        await peer.stopSending(applicationError: 0x10c)
        #expect(peer.sentStopSendingCode == 0x10c)
        await #expect(throws: TransportError.connectionReset) {
            try await stream.send(ByteBuffer("body"), endOfStream: false)
        }
        #expect(stream.receivedStopSendingCode == 0x10c)
        #expect(stream.sentResetCode == 0x10c)            // RFC 9000 §3.5 response
        var buffer = ByteBuffer()
        await #expect(throws: TransportError.connectionReset) {
            _ = try await peer.receive(into: &buffer, maxLength: 8)
        }
        #expect(peer.receivedResetCode == 0x10c)
        // The server's own direction still works.
        try await peer.send(ByteBuffer("early response"), endOfStream: true)
        let (response, _) = try await receiveAll(stream)
        #expect(response == ByteBuffer("early response"))
    }

    @Test(.timeLimit(.minutes(1))) func injectedPeerResetAndStopSending() async throws {
        let (client, server) = Mux.makePair()
        _ = try await client.openBidirectionalStream()
        let peer = try await accept(server)
        await peer.injectPeerReset(applicationError: 0x10c)
        var buffer = ByteBuffer()
        await #expect(throws: TransportError.connectionReset) {
            _ = try await peer.receive(into: &buffer, maxLength: 8)
        }
        #expect(peer.receivedResetCode == 0x10c)
        #expect(client.openedStreams[0].sentResetCode == 0x10c)

        await peer.injectPeerStopSending(applicationError: 0x10d)
        await #expect(throws: TransportError.connectionReset) {
            try await peer.send(ByteBuffer("x"), endOfStream: false)
        }
        #expect(peer.receivedStopSendingCode == 0x10d)
    }

    @Test(.timeLimit(.minutes(1))) func abortiveCloseResetsAndStopsWithCodeZero() async throws {
        let (client, server) = Mux.makePair()
        let stream = try await client.openBidirectionalStream()
        let peer = try await accept(server)
        await stream.close(.abort)
        #expect(stream.isClosed)
        #expect(peer.receivedResetCode == 0)
        #expect(peer.receivedStopSendingCode == 0)
        var buffer = ByteBuffer()
        await #expect(throws: TransportError.connectionReset) {
            _ = try await peer.receive(into: &buffer, maxLength: 8)
        }
        await #expect(throws: TransportError.connectionReset) {
            try await peer.send(ByteBuffer("x"), endOfStream: false)
        }
    }

    // MARK: Connection close

    @Test(.timeLimit(.minutes(1))) func connectionClosePropagatesToEveryStream() async throws {
        let (client, server) = Mux.makePair()
        var clientStreams: [Mux.Stream] = []
        var serverStreams: [Mux.Stream] = []
        for _ in 0..<3 { clientStreams.append(try await client.openBidirectionalStream()) }
        clientStreams.append(try await client.openUnidirectionalStream())
        for _ in 0..<4 { serverStreams.append(try await accept(server)) }
        try await clientStreams[0].send(ByteBuffer("buffered"), endOfStream: false)

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Pending receives on both sides, and a server waiting for the next stream.
            for stream in clientStreams where stream.canReceive {
                group.addTask {
                    var buffer = ByteBuffer()
                    await #expect(throws: TransportError.connectionReset) {
                        _ = try await stream.receive(into: &buffer, maxLength: 8)
                    }
                }
            }
            for stream in serverStreams.dropFirst() {
                group.addTask {
                    var buffer = ByteBuffer()
                    await #expect(throws: TransportError.closed) {
                        _ = try await stream.receive(into: &buffer, maxLength: 8)
                    }
                }
            }
            group.addTask {
                var iterator = server.inboundStreams.makeAsyncIterator()
                let next = try await iterator.next()
                #expect(next == nil)
            }
            for _ in 0..<20 { await Task.yield() }
            await server.close(applicationError: 0x100)
            try await group.waitForAll()
        }

        #expect(client.isClosed && server.isClosed)
        #expect(client.peerCloseApplicationError == 0x100)
        var buffer = ByteBuffer()
        await #expect(throws: TransportError.closed) {
            _ = try await serverStreams[0].receive(into: &buffer, maxLength: 8)   // buffered bytes are lost
        }
        await #expect(throws: TransportError.connectionReset) {
            try await clientStreams[3].send(ByteBuffer("x"), endOfStream: false)
        }
        await #expect(throws: TransportError.connectionReset) { _ = try await client.openBidirectionalStream() }
        await #expect(throws: TransportError.closed) { _ = try await server.openUnidirectionalStream() }
        var iterator = client.inboundStreams.makeAsyncIterator()
        #expect(try await iterator.next() == nil)

        // The first close wins.
        await client.close(applicationError: 0x102)
        #expect(server.closeApplicationError == 0x100)
        #expect(client.closeApplicationError == nil)
    }

    @Test(.timeLimit(.minutes(1))) func connectionFailureThrowsFromInboundStreams() async throws {
        let (client, server) = Mux.makePair()
        let stream = try await client.openBidirectionalStream()
        _ = try await accept(server)
        await client.fail(with: .timedOut)
        var iterator = server.inboundStreams.makeAsyncIterator()
        await #expect(throws: TransportError.timedOut) { _ = try await iterator.next() }
        await #expect(throws: TransportError.timedOut) { _ = try await server.openUnidirectionalStream() }
        var buffer = ByteBuffer()
        await #expect(throws: TransportError.connectionReset) {
            _ = try await stream.receive(into: &buffer, maxLength: 8)
        }
        #expect(client.closeApplicationError == nil && server.peerCloseApplicationError == nil)
    }

    // MARK: Stream limits (MAX_STREAMS)

    @Test(.timeLimit(.minutes(1))) func openBlocksAtTheStreamLimitUntilItIsRaised() async throws {
        let (client, server) = Mux.makePair(
            server: .init(maxStreamsBidirectional: 2, maxStreamsUnidirectional: 1))
        #expect(server.maxStreamsBidirectional == 2)
        let first = try await client.openBidirectionalStream()
        _ = try await client.openBidirectionalStream()
        _ = try await client.openUnidirectionalStream()
        // Credit is cumulative: finishing a stream does not replenish it (spike gotcha 5).
        try await first.send(ByteBuffer(), endOfStream: true)
        await first.close(.normal)

        try await withThrowingTaskGroup(of: UInt64.self) { group in
            group.addTask { try await client.openBidirectionalStream().streamID }
            group.addTask { try await client.openUnidirectionalStream().streamID }
            await waitUntil { client.blockedOpenCount == 2 }
            for _ in 0..<10 { await Task.yield() }
            #expect(client.blockedOpenCount == 2)

            server.raiseMaxStreams(bidirectional: 3)
            let bidi = try await group.next()
            #expect(bidi == 8)
            #expect(client.blockedOpenCount == 1)
            server.raiseMaxStreams(bidirectional: 1, unidirectional: 2)   // never lowers
            let uni = try await group.next()
            #expect(uni == 6)
        }
        #expect(server.maxStreamsBidirectional == 3 && server.maxStreamsUnidirectional == 2)
        #expect(client.blockedOpenCount == 0)
        // The other direction has its own credit.
        #expect(try await server.openBidirectionalStream().streamID == 1)
    }

    @Test(.timeLimit(.minutes(1))) func blockedOpenFailsOnCloseAndOnCancel() async throws {
        let (client, server) = Mux.makePair(server: .init(maxStreamsBidirectional: 0))
        let cancelled = Task { try await client.openBidirectionalStream() }
        await waitUntil { client.blockedOpenCount == 1 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        #expect(client.blockedOpenCount == 0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await #expect(throws: TransportError.connectionReset) {
                    _ = try await client.openBidirectionalStream()
                }
            }
            await waitUntil { client.blockedOpenCount == 1 }
            await server.close(applicationError: 0x100)
            try await group.waitForAll()
        }
    }

    // MARK: Concurrency and backpressure

    @Test(.timeLimit(.minutes(1))) func concurrentStreamsWithInterleavedData() async throws {
        let (client, server) = Mux.makePair()
        let count = 8
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { handlers in
                    for try await stream in server.inboundStreams {
                        handlers.addTask { try await echo(stream) }
                    }
                    try await handlers.waitForAll()
                }
            }
            var streams: [Mux.Stream] = []
            for _ in 0..<count { streams.append(try await client.openBidirectionalStream()) }
            // Round-robin small writes so every stream's bytes are interleaved with the others'.
            for round in 0..<20 {
                for (i, stream) in streams.enumerated() {
                    try await stream.send(bytes(7, seed: UInt8(i * 20 + round)), endOfStream: round == 19)
                }
            }
            try await withThrowingTaskGroup(of: (Int, ByteBuffer).self) { readers in
                for (i, stream) in streams.enumerated() {
                    readers.addTask { (i, try await receiveAll(stream).0) }
                }
                for try await (i, echoed) in readers {
                    var expected = ByteBuffer()
                    for round in 0..<20 { expected.append(bytes(7, seed: UInt8(i * 20 + round))) }
                    #expect(echoed == expected, "stream \(streams[i].streamID)")
                    #expect(streams[i].sentBytes == expected)
                }
            }
            await client.close(applicationError: 0x100)
            try await group.waitForAll()
        }
    }

    @Test(.timeLimit(.minutes(1))) func backpressureIsPerStream() async throws {
        let small = InMemoryTransport.Configuration(bufferCapacity: 16, segmentSize: 4)
        let (client, server) = Mux.makePair(server: .init(stream: small))
        let slow = try await client.openBidirectionalStream()
        let fast = try await client.openBidirectionalStream()
        let slowPeer = try await accept(server)
        let fastPeer = try await accept(server)
        let payload = bytes(64)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await slow.send(payload, endOfStream: true) }
            // Four 4-byte slots fill; the fifth segment's sender suspends.
            await waitUntil { slowPeer.suspendedPeerSenders == 1 }
            #expect(slow.sentBytes.readableBytes == 16)

            // A blocked stream does not block its neighbour.
            try await fast.send(ByteBuffer("ok"), endOfStream: true)
            #expect(try await receiveAll(fastPeer).0 == ByteBuffer("ok"))

            let (received, _) = try await receiveAll(slowPeer, maxLength: 3)
            #expect(received == payload)
            try await group.waitForAll()
        }
        #expect(slowPeer.inboundHighWaterMark <= small.bufferBound)
    }

    // MARK: Scripting hooks

    @Test(.timeLimit(.minutes(1))) func chunkedDeliveryAndDelays() async throws {
        let (client, server) = Mux.makePair(server: .init(stream: .init(receiveChunking: .bytewise)))
        let stream = try await client.openBidirectionalStream()
        let peer = try await accept(server)
        try await stream.play([
            .bytes(ByteBuffer("ab")), .delay(.milliseconds(20)), .bytes(ByteBuffer("c")), .endOfStream,
        ])
        let start = ContinuousClock.now
        let (received, sizes) = try await receiveAll(peer)
        #expect(received == ByteBuffer("abc"))
        #expect(sizes == [1, 1, 1])
        #expect(ContinuousClock.now - start >= .milliseconds(20))
    }

    @Test(.timeLimit(.minutes(1))) func scriptedInboundStreamsAndCapturedSends() async throws {
        let server = Mux.scripted([
            .init(streamID: 2, bytes: ByteBuffer(bytes: [0x00, 0x04, 0x00])),   // control stream, empty SETTINGS
            .init(streamID: 0, events: [.bytes(ByteBuffer("req")), .delay(.milliseconds(1)), .endOfStream]),
            .init(streamID: 4, events: [.bytes(ByteBuffer("half"))]),
        ])
        var accepted: [Mux.Stream] = []
        for try await stream in server.inboundStreams { accepted.append(stream) }
        #expect(accepted.map(\.streamID) == [2, 0, 4])

        let control = accepted[0]
        #expect(control.isUnidirectional && !control.canSend)
        #expect(try await receiveAll(control).0 == ByteBuffer(bytes: [0x00, 0x04, 0x00]))

        let request = accepted[1]
        #expect(try await receiveAll(request).0 == ByteBuffer("req"))
        try await request.send(ByteBuffer("resp"), endOfStream: true)
        #expect(request.sentBytes == ByteBuffer("resp"))

        // An injected reset fails the receive and carries the code.
        await accepted[2].injectPeerReset(applicationError: 0x10c)
        var buffer = ByteBuffer()
        await #expect(throws: TransportError.connectionReset) {
            _ = try await accepted[2].receive(into: &buffer, maxLength: 8)
        }
        #expect(accepted[2].receivedResetCode == 0x10c)

        // Locally opened streams never block and capture what the code under test sent.
        let uni = try await server.openUnidirectionalStream()
        #expect(uni.streamID == 3)
        try await uni.send(ByteBuffer(bytes: [0x00, 0x04, 0x00]), endOfStream: false)
        #expect(server.openedStreams.map(\.streamID) == [3])
        #expect(server.openedStreams[0].sentBytes == ByteBuffer(bytes: [0x00, 0x04, 0x00]))

        await uni.injectPeerStopSending(applicationError: 0x10c)
        await #expect(throws: TransportError.connectionReset) {
            try await uni.send(ByteBuffer("x"), endOfStream: false)
        }

        await server.close(applicationError: 0x100)
        #expect(server.closeApplicationError == 0x100)
    }

    @Test(.timeLimit(.minutes(1))) func scriptedInboundCanStayOpenUntilClose() async throws {
        let server = Mux.scripted([.init(streamID: 0, bytes: ByteBuffer("a"))], finishesInbound: false)
        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                var count = 0
                for try await _ in server.inboundStreams { count += 1 }
                return count
            }
            await waitUntil { server.pendingInboundCount == 0 }
            for _ in 0..<10 { await Task.yield() }
            await server.close(applicationError: 0x100)
            let count = try await group.next()
            #expect(count == 1)
        }
    }
}
