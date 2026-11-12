import HTTP3
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0102: GOAWAY and graceful shutdown over the in-memory multiplexed transport.
@Suite(.timeLimit(.minutes(1)))
struct H3ShutdownTests {
    @Test func goawayLetsTheInFlightRequestFinishAndRejectsNewStreams() async throws {
        let shutdown = ShutdownSignal()
        let started = Flag()
        let release = Flag()
        let handler = ClosureHandler { request in
            guard request.string(of: request.path) == "/slow" else {
                return HTTPResponse(status: .ok, body: .bytes(ByteBuffer("fast")))
            }
            started.set()
            await release.wait()
            return HTTPResponse(status: .ok, body: .bytes(ByteBuffer("slow done")))
        }
        let calls = Mutex(0)
        let counting = ClosureHandler { request in
            calls.withLock { $0 += 1 }
            return try await handler.handle(request, context: RequestContext(connection: ConnectionInfo()))
        }
        try await withH3Server(handler: counting, shutdown: shutdown) { client, _ in
            var inbound = client.inboundStreams.makeAsyncIterator()
            var control = H3ControlReader(stream: try #require(try await inbound.next()))
            let h3 = H3TestClient(transport: client)
            #expect(try await h3.send(H3Wire.request(path: "/first")).status == "200")   // stream 0
            let slow = try await h3.openRequest(H3Wire.headers(H3Wire.request(path: "/slow")))   // stream 4
            await started.wait()

            shutdown.trigger()
            // The next unprocessed client bidirectional stream ID.
            #expect(try await control.nextGoaway() == 8)

            let late = try await h3.send(H3Wire.request(path: "/late"))   // stream 8
            #expect(late.resetCode == HTTP3Error.requestRejected.rawValue)
            #expect(late.status == nil)
            #expect(!client.isClosed)

            release.set()
            let response = await H3TestResponse.read(slow)
            #expect(response.status == "200")
            #expect(response.bodyString == "slow done")
            #expect(response.finished)
            #expect(await serverCloseCode(client) == HTTP3Error.noError.rawValue)
        }
        // The rejected request never reached the handler.
        #expect(calls.withLock { $0 } == 2)
    }

    /// #0104: the race behind the flaky failure of the test above. A stream reaches the server
    /// when the client opens it, so the server can reject it after GOAWAY (RESET_STREAM +
    /// STOP_SENDING) before the client's HEADERS send runs; that send then throws
    /// `connectionReset`. `H3TestClient.send` treats it as the rejection it is.
    @Test func streamRejectedBeforeItsHeadersAreSentStillReportsTheResetCode() async throws {
        let shutdown = ShutdownSignal()
        try await withH3Server(handler: PathHandler(), shutdown: shutdown) { client, _ in
            var inbound = client.inboundStreams.makeAsyncIterator()
            var control = H3ControlReader(stream: try #require(try await inbound.next()))
            shutdown.trigger()
            #expect(try await control.nextGoaway() == 0)
            let stream = try await client.openBidirectionalStream()
            try await waitUntil { stream.receivedStopSendingCode != nil }
            await #expect(throws: TransportError.connectionReset) {
                try await stream.send(ByteBuffer(bytes: H3Wire.headers(H3Wire.request())), endOfStream: true)
            }
            #expect(await H3TestResponse.read(stream).resetCode == HTTP3Error.requestRejected.rawValue)
            #expect(try await H3TestClient(transport: client).send().resetCode == HTTP3Error.requestRejected.rawValue)
        }
    }

    @Test func goawayIDFollowsTheLastRequestAndTheCloseFollowsTheLinger() async throws {
        let shutdown = ShutdownSignal()
        let configuration = H3Configuration(timeouts: H3Timeouts(closeLinger: .milliseconds(100)))
        try await withH3Server(handler: PathHandler(), configuration: configuration, shutdown: shutdown) { client, _ in
            var inbound = client.inboundStreams.makeAsyncIterator()
            var control = H3ControlReader(stream: try #require(try await inbound.next()))
            let h3 = H3TestClient(transport: client)
            for _ in 0..<3 { #expect(try await h3.send().status == "200") }   // streams 0, 4, 8
            let clock = ContinuousClock()
            let start = clock.now
            shutdown.trigger()
            #expect(try await control.nextGoaway() == 12)
            #expect(await serverCloseCode(client) == HTTP3Error.noError.rawValue)
            // Nothing was in flight: CONNECTION_CLOSE follows the GOAWAY after the linger.
            let elapsed = start.duration(to: clock.now)
            #expect(elapsed >= .milliseconds(100) && elapsed < .seconds(5))
        }
    }

    @Test func goawayBeforeAnyRequestCarriesZero() async throws {
        let shutdown = ShutdownSignal()
        try await withH3Server(handler: PathHandler(), shutdown: shutdown) { client, _ in
            var inbound = client.inboundStreams.makeAsyncIterator()
            var control = H3ControlReader(stream: try #require(try await inbound.next()))
            shutdown.trigger()
            #expect(try await control.nextGoaway() == 0)
            #expect(await serverCloseCode(client) == HTTP3Error.noError.rawValue)
        }
    }

    @Test func provisionalGoawayThenFinalGoaway() async throws {
        let shutdown = ShutdownSignal()
        let configuration = H3Configuration(timeouts: H3Timeouts(goawayGrace: .seconds(1)))
        try await withH3Server(handler: PathHandler(), configuration: configuration, shutdown: shutdown) { client, _ in
            var inbound = client.inboundStreams.makeAsyncIterator()
            var control = H3ControlReader(stream: try #require(try await inbound.next()))
            let h3 = H3TestClient(transport: client)
            shutdown.trigger()
            #expect(try await control.nextGoaway() == H3Connection.maxClientBidirectionalStreamID)
            // Between the two, new requests are still served.
            #expect(try await h3.send(H3Wire.request(path: "/between")).bodyString == "hello /between")   // stream 0
            #expect(try await control.nextGoaway() == 4)
            #expect(await serverCloseCode(client) == HTTP3Error.noError.rawValue)
        }
    }

    @Test func drainTimeoutClosesWithInFlightRequests() async throws {
        let shutdown = ShutdownSignal()
        let started = Flag()
        let cancelled = Flag()
        let handler = ClosureHandler { _ in
            started.set()
            do {
                try await Task.sleep(for: .seconds(50))
            } catch {
                cancelled.set()
                throw error
            }
            return HTTPResponse(status: .ok)
        }
        let configuration = H3Configuration(timeouts: H3Timeouts(drain: .milliseconds(200)))
        try await withH3Server(handler: handler, configuration: configuration, shutdown: shutdown) { client, _ in
            let stream = try await H3TestClient(transport: client).openRequest(H3Wire.headers(H3Wire.request()))
            await started.wait()
            shutdown.trigger()
            #expect(await serverCloseCode(client) == HTTP3Error.noError.rawValue)
            let response = await H3TestResponse.read(stream)
            #expect(!response.finished)
            await cancelled.wait()
        }
    }

    @Test func peerGoawayIDsMustNotIncrease() async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            try await H3TestClient(transport: client).openControlStream(
                [0x00] + H3Wire.settings() + H3Wire.frame(.goaway, H3Wire.varint(4)) + H3Wire.frame(.goaway, H3Wire.varint(8)))
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.idError.rawValue)
    }

    @Test func peerGoawayWithDecreasingIDsIsAccepted() async throws {
        try await withH3Server(handler: PathHandler()) { client, _ in
            let h3 = H3TestClient(transport: client)
            try await h3.openControlStream(
                [0x00] + H3Wire.settings() + H3Wire.frame(.goaway, H3Wire.varint(8)) + H3Wire.frame(.goaway, H3Wire.varint(8))
                    + H3Wire.frame(.goaway, H3Wire.varint(4)))
            #expect(try await h3.send().status == "200")
            #expect(!client.isClosed)
        }
    }
}

/// #0102: the shutdown, admission and credit rules of the pure connection state machine.
struct H3ConnectionShutdownStateTests {
    @Test func finalGoawayCarriesTheNextUnprocessedStreamIDAndRejectsAtOrAboveIt() {
        var connection = H3Connection()
        #expect(connection.handle(.requestStream(streamID: 0)) == .serveRequest)
        #expect(connection.handle(.requestStream(streamID: 4)) == .serveRequest)
        #expect(connection.handle(.beginShutdown(final: true)) == .sendGoaway(id: 8))
        #expect(connection.isDraining && !connection.isDrained)
        // A second final GOAWAY is not sent.
        #expect(connection.handle(.beginShutdown(final: true)) == .none)
        #expect(connection.handle(.requestStream(streamID: 8)) == .rejectRequest(code: 0x10b))
        #expect(connection.handle(.requestStream(streamID: 12)) == .rejectRequest(code: 0x10b))
        #expect(connection.handle(.requestStreamClosed(served: false)) == .none)
        #expect(connection.handle(.requestStreamClosed(served: true)) == .none)
        #expect(connection.handle(.requestStreamClosed(served: true)) == .drained)
        #expect(connection.isDrained)
    }

    @Test func provisionalGoawayIsTheLargestIDAndTheFinalOneIsSmaller() {
        var connection = H3Connection()
        #expect(connection.handle(.beginShutdown(final: false)) == .sendGoaway(id: (1 << 62) - 4))
        #expect(connection.handle(.beginShutdown(final: false)) == .none)
        // Below the provisional ID, requests are still served.
        #expect(connection.handle(.requestStream(streamID: 0)) == .serveRequest)
        #expect(connection.handle(.requestStreamClosed(served: true)) == .none)   // not drained before the final GOAWAY
        #expect(connection.handle(.beginShutdown(final: true)) == .sendGoaway(id: 4))
        #expect(connection.goawayID == 4)
        #expect(connection.isDrained)
        #expect(connection.handle(.beginShutdown(final: false)) == .none)
    }

    @Test func goawayIDIsZeroWithoutRequests() {
        var connection = H3Connection()
        #expect(connection.handle(.beginShutdown(final: true)) == .sendGoaway(id: 0))
        #expect(connection.isDrained)
        #expect(connection.handle(.requestStream(streamID: 0)) == .rejectRequest(code: 0x10b))
    }

    @Test func concurrencyLimitAndStreamCredit() {
        var connection = H3Connection(configuration: H3Configuration(maxConcurrentRequestStreams: 2))
        #expect(connection.initialStreamCredit == 2)
        #expect(connection.handle(.requestStream(streamID: 0)) == .serveRequest)
        #expect(connection.handle(.requestStream(streamID: 4)) == .serveRequest)
        #expect(connection.handle(.requestStream(streamID: 8)) == .rejectRequest(code: 0x10b))
        #expect(connection.activeRequestStreams == 2)
        // Each closed stream (served or rejected) returns one stream of credit.
        #expect(connection.handle(.requestStreamClosed(served: false)) == .grantStreamCredit(bidirectional: 3))
        #expect(connection.handle(.requestStreamClosed(served: true)) == .grantStreamCredit(bidirectional: 4))
        #expect(connection.activeRequestStreams == 1)
        #expect(connection.handle(.requestStream(streamID: 12)) == .serveRequest)
    }

    @Test func noGoawayOrCreditAfterAConnectionError() {
        var connection = H3Connection()
        _ = connection.handle(.requestStream(streamID: 0))
        #expect(connection.handle(.connectionError(code: 0x101)) == .closeConnection(code: 0x101))
        #expect(connection.handle(.beginShutdown(final: true)) == .none)
        #expect(connection.handle(.requestStreamClosed(served: true)) == .none)
        #expect(connection.activeRequestStreams == 0)
    }
}

// MARK: - Support

/// Reads the server's control stream as a client and reports its GOAWAY frames.
struct H3ControlReader {
    let stream: MuxStream
    var buffer = ByteBuffer()
    var parser = H3FrameParser(configuration: .init(streamKind: .control, role: .client))
    var typeRead = false

    init(stream: MuxStream) {
        self.stream = stream
    }

    /// The next GOAWAY's ID, or `nil` when the stream ends.
    mutating func nextGoaway() async throws -> UInt64? {
        while true {
            if !typeRead && buffer.readableBytes > 0 {
                buffer.moveReaderIndex(forwardBy: 1)   // the stream type (0x00)
                typeRead = true
            }
            while buffer.readableBytes > 0 {
                let bytes = buffer
                var parser = self.parser
                let output = try bytes.withUnsafeReadableBytes { (input) throws(HTTP3Error) in try parser.parse(input) }
                self.parser = parser
                buffer.moveReaderIndex(forwardBy: output.consumed)
                if case .goaway(let id) = output.event { return id }
            }
            buffer.clear()
            guard try await stream.receive(into: &buffer, maxLength: 4096) > 0 else { return nil }
        }
    }
}
