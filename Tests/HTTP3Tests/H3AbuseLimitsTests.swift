import HTTP3
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0104: every abuse limit has its response, over the in-memory multiplexed transport.
@Suite(.timeLimit(.minutes(1)))
struct H3AbuseLimitsTests {
    static let excessiveLoad = HTTP3Error.excessiveLoad.rawValue

    static func configuration(_ limits: H3AbuseLimits) -> H3Configuration {
        H3Configuration(abuseLimits: limits)
    }

    /// A handler that waits until it is cancelled.
    static let waitingHandler = ClosureHandler { _ in
        try await Task.sleep(for: .seconds(60))
        return HTTPResponse(status: .ok)
    }

    // MARK: Rapid reset

    @Test func rapidResetBeyondTheLimitClosesWithExcessiveLoad() async throws {
        let configuration = Self.configuration(H3AbuseLimits(maxAbortedRequestsPerWindow: 10))
        let tracker = H3ConnectionTracker()
        try await withH3Server(handler: Self.waitingHandler, configuration: configuration, tracker: tracker) { client, _ in
            let h3 = H3TestClient(transport: client)
            for _ in 0..<10 {
                let stream = try await h3.openRequest(H3Wire.headers(H3Wire.request()))
                await stream.reset(applicationError: HTTP3Error.requestCancelled.rawValue)
                await stream.stopSending(applicationError: HTTP3Error.requestCancelled.rawValue)
            }
            // Ten resets are within the limit.
            try await waitUntil { tracker.liveRequestStreams == 0 }
            #expect(!client.isClosed)
            let stream = try await h3.openRequest(H3Wire.headers(H3Wire.request()))
            await stream.reset(applicationError: HTTP3Error.requestCancelled.rawValue)
            await stream.stopSending(applicationError: HTTP3Error.requestCancelled.rawValue)
            #expect(await serverCloseCode(client) == Self.excessiveLoad)
        }
    }

    @Test func streamsEndedWithoutARequestCountAsResets() async throws {
        let configuration = Self.configuration(H3AbuseLimits(maxAbortedRequestsPerWindow: 5))
        let code = try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            let h3 = H3TestClient(transport: client)
            for _ in 0..<6 {
                // FIN without HEADERS: H3_REQUEST_INCOMPLETE each time.
                let stream = try await h3.openRequest([], fin: true)
                _ = await H3TestResponse.read(stream)
            }
            return await serverCloseCode(client)
        }
        #expect(code == Self.excessiveLoad)
    }

    @Test func monitorCountsPerWindowAndStartsOver() {
        var monitor = H3AbuseMonitor(limits: H3AbuseLimits(window: .seconds(10), maxAbortedRequestsPerWindow: 3))
        let start = ContinuousClock.now
        let first = monitor.record(.abortedRequests, amount: 2, now: start)
        let second = monitor.record(.abortedRequests, now: start.advanced(by: .seconds(9)))
        let third = monitor.record(.abortedRequests, now: start.advanced(by: .seconds(9)))
        #expect(first && second && !third)
        // A new window.
        let fresh = monitor.record(.abortedRequests, amount: 3, now: start.advanced(by: .seconds(10)))
        #expect(fresh)
        #expect(monitor.count(.abortedRequests) == 3)
        // Other kinds are separate, and a disabled limit never trips.
        let other = monitor.record(.controlFrames, amount: 999, now: start)
        #expect(other)
        var disabled = H3AbuseMonitor(limits: .disabled)
        let unlimited = disabled.record(.abortedRequests, amount: 1_000_000, now: start)
        #expect(unlimited)
    }

    // MARK: Reserved and unknown unidirectional streams

    @Test func ignoredUniStreamsBeyondTheLimitCloseWithExcessiveLoad() async throws {
        let configuration = Self.configuration(H3AbuseLimits(maxIgnoredUniStreamsPerWindow: 3))
        try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            let h3 = H3TestClient(transport: client)
            var streams: [MuxStream] = []
            for n in 0..<3 {
                streams.append(try await h3.openUniStream(H3Wire.varint(0x21 + 0x1f * UInt64(n)) + [1, 2, 3]))
            }
            for stream in streams {
                try await waitUntil { stream.receivedStopSendingCode != nil }
                #expect(stream.receivedStopSendingCode == HTTP3Error.streamCreationError.rawValue)
            }
            #expect(!client.isClosed)
            try await h3.openUniStream(H3Wire.varint(0x3f))   // an unknown type
            #expect(await serverCloseCode(client) == Self.excessiveLoad)
        }
    }

    // MARK: QPACK instruction floods

    @Test(arguments: [UInt8(0x02), 0x03])
    func qpackInstructionFloodClosesWithExcessiveLoad(streamType: UInt8) async throws {
        let configuration = Self.configuration(H3AbuseLimits(maxQPACKInstructionsPerWindow: 100))
        try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            let h3 = H3TestClient(transport: client)
            // Encoder: Set Dynamic Table Capacity 0 (0x20). Decoder: Stream Cancellation of
            // stream 0 (0x40). Both are legal, and free to repeat without the limit.
            let instruction: UInt8 = streamType == 0x02 ? 0x20 : 0x40
            let stream = try await h3.openUniStream([streamType] + Array(repeating: instruction, count: 100))
            #expect(try await h3.send().status == "200")
            #expect(!client.isClosed)
            try await stream.send(ByteBuffer(bytes: [instruction]), endOfStream: false)
            #expect(await serverCloseCode(client) == Self.excessiveLoad)
        }
    }

    // MARK: Frame floods and oversized unknown frames

    /// A reserved (GREASE) frame with `length` payload bytes.
    static func grease(_ length: Int = 0) -> [UInt8] {
        H3Wire.frame(.reserved(1), Array(repeating: 0xaa, count: length))
    }

    @Test func controlFrameFloodClosesWithExcessiveLoad() async throws {
        let configuration = Self.configuration(H3AbuseLimits(maxControlFramesPerWindow: 20))
        try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            let h3 = H3TestClient(transport: client)
            // SETTINGS + 19 frames: at the limit.
            let control = try await h3.openControlStream(
                [0x00] + H3Wire.settings() + Array((0..<19).map { _ in Self.grease() }.joined()))
            #expect(try await h3.send().status == "200")
            #expect(!client.isClosed)
            // MAX_PUSH_ID frames count as well.
            try await control.send(ByteBuffer(bytes: H3Wire.frame(.maxPushID, H3Wire.varint(1))), endOfStream: false)
            #expect(await serverCloseCode(client) == Self.excessiveLoad)
        }
    }

    @Test func unknownFrameFloodOnRequestStreamsClosesWithExcessiveLoad() async throws {
        let configuration = Self.configuration(H3AbuseLimits(maxUnknownRequestFramesPerWindow: 10))
        try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            let h3 = H3TestClient(transport: client)
            // Ten across two requests are fine.
            let five = Array((0..<5).map { _ in Self.grease(3) }.joined())
            for _ in 0..<2 {
                let stream = try await h3.openRequest(five + H3Wire.headers(H3Wire.request()))
                #expect(await H3TestResponse.read(stream).status == "200")
            }
            #expect(!client.isClosed)
            _ = try await h3.openRequest(H3Wire.headers(H3Wire.request()) + Self.grease(), fin: false)
            #expect(await serverCloseCode(client) == Self.excessiveLoad)
        }
    }

    @Test(arguments: [false, true])
    func oversizedUnknownFrameClosesWithExcessiveLoad(onControlStream: Bool) async throws {
        let configuration = Self.configuration(H3AbuseLimits(maxUnknownFrameLength: 100))
        try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            let h3 = H3TestClient(transport: client)
            let control = try await h3.openControlStream([0x00] + H3Wire.settings() + Self.grease(100))
            let request = try await h3.openRequest(Self.grease(100) + H3Wire.headers(H3Wire.request()))
            #expect(await H3TestResponse.read(request).status == "200")
            #expect(!client.isClosed)
            // Only the frame header is sent: the declared length alone is refused, so nothing
            // is read (or buffered) for it.
            var header = H3Wire.varint(H3FrameType.reserved(2).rawValue) + H3Wire.varint(101)
            if onControlStream {
                try await control.send(ByteBuffer(bytes: header), endOfStream: false)
            } else {
                header = H3Wire.headers(H3Wire.request()) + header
                _ = try await h3.openRequest(header, fin: false)
            }
            #expect(await serverCloseCode(client) == Self.excessiveLoad)
        }
    }

    @Test func parserCountsSkippedFramesAndRefusesOversizedOnes() throws {
        var parser = H3FrameParser(configuration: .init(maxUnknownFrameLength: 4))
        let bytes = Self.grease(4) + Self.grease(0) + H3Wire.data([1])
        let output = try bytes.withUnsafeBytes { (input) throws(HTTP3Error) in try parser.parse(input) }
        #expect(output.event == .dataHeader(length: 1))
        #expect(parser.skippedFrameCount == 2)
        var strict = H3FrameParser(configuration: .init(maxUnknownFrameLength: 4))
        let header = H3Wire.varint(H3FrameType.reserved(3).rawValue) + H3Wire.varint(5)
        let result: Result<H3FrameParser.Output, HTTP3Error> = header.withUnsafeBytes { input in
            do throws(HTTP3Error) {
                return .success(try strict.parse(input))
            } catch {
                return .failure(error)
            }
        }
        #expect(result == .failure(.excessiveLoad))
    }

    // MARK: Slow readers

    @Test func slowReaderHoldsBoundedBytesAndItsStreamsAreReset() async throws {
        let chunk = ByteBuffer(bytes: Array(repeating: 0x5a, count: 16 * 1024))
        let writersEnded = Mutex(0)
        let handler = ClosureHandler { request in
            guard request.string(of: request.path) == "/big" else {
                return HTTPResponse(status: .ok, body: .bytes(ByteBuffer("small")))
            }
            return HTTPResponse(status: .ok, body: .stream(length: nil) { writer in
                defer { writersEnded.withLock { $0 += 1 } }
                for _ in 0..<1024 { try await writer.write(chunk) }   // 16 MiB
            })
        }
        let budget = 40 * 1024
        let configuration = H3Configuration(
            timeouts: H3Timeouts(send: .milliseconds(300)),
            abuseLimits: H3AbuseLimits(maxConnectionSendBuffer: budget))
        // What one stream can queue toward the client: the client's receive buffer (its
        // flow-control window in this model).
        let streamBound = InMemoryTransport.Configuration().bufferBound
        let tracker = H3ConnectionTracker()
        try await withH3Server(handler: handler, configuration: configuration, tracker: tracker) { client, _ in
            let h3 = H3TestClient(transport: client)
            // Three downloads that are never read.
            var downloads: [MuxStream] = []
            for _ in 0..<3 {
                downloads.append(try await h3.openRequest(H3Wire.headers(H3Wire.request(path: "/big"))))
            }
            for download in downloads {
                try await waitUntil { download.receivedResetCode != nil }
                #expect(download.receivedResetCode == HTTP3Error.requestCancelled.rawValue)
                // Per stream: no more than the stream's own buffer was ever queued.
                #expect(download.inboundHighWaterMark <= streamBound)
            }
            try await waitUntil { writersEnded.withLock { $0 } == 3 }
            // The connection itself is fine.
            #expect(try await h3.send(H3Wire.request(path: "/small")).bodyString == "small")
            #expect(!client.isClosed)
        }
        // Per connection: what stalled sends held never went past the budget.
        #expect(tracker.sendBufferHighWater > 0)
        #expect(tracker.sendBufferHighWater <= budget)
    }

    // MARK: Idle connections

    @Test func tooManyIdleConnectionsShutDownTheLongestIdle() async throws {
        let configuration = Self.configuration(H3AbuseLimits(maxIdleConnections: 2))
        let http3 = HTTP3(configuration: configuration)
        let shutdown = ShutdownSignal()
        let pairs = (0..<3).map { _ in InMemoryMultiplexedTransport.makePair() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, (_, server)) in pairs.enumerated() {
                group.addTask {
                    await http3.run(server, handler: PathHandler(), context: ConnectionContext(info: server.info, shutdown: shutdown))
                }
                // Start them in order, so the first is the longest idle.
                try await waitUntil { http3.tracker.liveConnections == index + 1 }
            }
            // The third idle connection pushed the first one out: GOAWAY, then H3_NO_ERROR.
            let first = pairs[0].0
            var inbound = first.inboundStreams.makeAsyncIterator()
            var control = H3ControlReader(stream: try #require(try await inbound.next()))
            #expect(try await control.nextGoaway() == 0)
            #expect(await serverCloseCode(first) == HTTP3Error.noError.rawValue)
            #expect(http3.tracker.evictedConnections == 1)
            // A busy connection is not idle; the others still serve.
            for (client, _) in pairs.dropFirst() {
                #expect(!client.isClosed)
                #expect(try await H3TestClient(transport: client).send().status == "200")
            }
            for (client, _) in pairs { await client.close(applicationError: HTTP3Error.noError.rawValue) }
            try await group.waitForAll()
        }
        #expect(http3.tracker.liveConnections == 0)
    }
}
