import HTTP3
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0102: every HTTP/3 limit and timeout produces its documented response or error code.
@Suite(.timeLimit(.minutes(1)))
struct H3LimitsTests {
    // MARK: Concurrent request streams (MAX_STREAMS)

    @Test func streamCreditIsReplenishedAsHandlersFinish() async throws {
        let gates = Gates()
        let configuration = H3Configuration(maxConcurrentRequestStreams: 2)
        let transport = InMemoryMultiplexedTransport.Configuration(maxStreamsBidirectional: 2)
        try await withH3Server(handler: gates.handler, configuration: configuration, serverTransport: transport) { client, server in
            let h3 = H3TestClient(transport: client)
            let a = try await h3.openRequest(H3Wire.headers(H3Wire.request(path: "/a")))
            let b = try await h3.openRequest(H3Wire.headers(H3Wire.request(path: "/b")))
            await gates.started("/a").wait()
            await gates.started("/b").wait()
            #expect(server.maxStreamsBidirectional == 2)

            // A third request cannot even open its stream until a handler finishes.
            async let third = h3.send(H3Wire.request(path: "/c"))
            try await waitUntil { client.blockedOpenCount == 1 }
            gates.release("/c")
            gates.release("/a")
            #expect(await H3TestResponse.read(a).status == "200")
            #expect(try await third.status == "200")
            #expect(server.maxStreamsBidirectional >= 3)
            gates.release("/b")
            #expect(await H3TestResponse.read(b).status == "200")
        }
    }

    @Test func initialStreamCreditFollowsTheConcurrencyLimit() async throws {
        let configuration = H3Configuration(maxConcurrentRequestStreams: 7)
        let transport = InMemoryMultiplexedTransport.Configuration(maxStreamsBidirectional: 1)
        try await withH3Server(handler: PathHandler(), configuration: configuration, serverTransport: transport) { _, server in
            try await waitUntil { server.maxStreamsBidirectional == 7 }
        }
    }

    @Test func streamsBeyondTheConcurrencyLimitAreRejected() async throws {
        let gates = Gates()
        // The transport grants more credit than the limit (as a QUIC listener configured with
        // a larger initial MAX_STREAMS would).
        let configuration = H3Configuration(maxConcurrentRequestStreams: 1)
        try await withH3Server(handler: gates.handler, configuration: configuration) { client, _ in
            let h3 = H3TestClient(transport: client)
            let a = try await h3.openRequest(H3Wire.headers(H3Wire.request(path: "/a")))
            await gates.started("/a").wait()
            let rejected = try await h3.send(H3Wire.request(path: "/b"))
            #expect(rejected.resetCode == HTTP3Error.requestRejected.rawValue)
            gates.release("/a")
            #expect(await H3TestResponse.read(a).status == "200")
            // The slot is free again once the server has closed the first stream.
            gates.release("/c")
            var again = try await h3.send(H3Wire.request(path: "/c"))
            while again.resetCode == HTTP3Error.requestRejected.rawValue {
                try await Task.sleep(for: .milliseconds(5))
                again = try await h3.send(H3Wire.request(path: "/c"))
            }
            #expect(again.status == "200")
        }
    }

    // MARK: Field section size

    @Test func oversizedFieldSectionWithValidPseudoHeadersIs431AndTheBodyIsDrained() async throws {
        let configuration = H3Configuration(maxFieldSectionSize: 256)
        let response = try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            try await H3TestClient(transport: client).send(
                H3Wire.request(method: "POST", extra: [("x-big", String(repeating: "a", count: 400))]),
                body: Array(repeating: 1, count: 100))
        }
        #expect(response.status == "431")
        #expect(response.finished)
    }

    @Test func oversizedFieldSectionBeforeValidPseudoHeadersIsMessageError() async throws {
        let configuration = H3Configuration(maxFieldSectionSize: 256)
        let (response, open) = try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            let h3 = H3TestClient(transport: client)
            let response = try await h3.send(H3Wire.request(path: "/" + String(repeating: "p", count: 400)))
            return (response, !client.isClosed)
        }
        #expect(response.resetCode == HTTP3Error.messageError.rawValue)
        #expect(open)
    }

    @Test func encodedHeadersFrameOverTheLimitIsExcessiveLoad() async throws {
        let configuration = H3Configuration(maxEncodedFieldSectionLength: 128)
        let code = try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            _ = try await H3TestClient(transport: client).openRequest(
                H3Wire.headers(H3Wire.request(extra: [("x-big", String(repeating: "a", count: 200))])))
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.excessiveLoad.rawValue)
    }

    @Test func responseHeadOverThePeersFieldSectionLimitBecomes500() async throws {
        let handler = ClosureHandler { _ in
            var headers = HTTPFields()
            headers.append(name: "x-big", value: String(repeating: "v", count: 300))
            return HTTPResponse(status: .ok, headers: headers, body: .bytes(ByteBuffer("body")))
        }
        try await withH3Server(handler: handler) { client, _ in
            let h3 = H3TestClient(transport: client)
            try await h3.openControlStream([0x00] + H3Wire.settings(H3Settings(
                qpackMaxTableCapacity: 0, maxFieldSectionSize: 200, qpackBlockedStreams: 0)))
            // The control stream is read concurrently: retry until our SETTINGS applied.
            var response = try await h3.send()
            var tries = 0
            while response.status == "200" && tries < 100 {
                try await Task.sleep(for: .milliseconds(10))
                response = try await h3.send()
                tries += 1
            }
            #expect(response.status == "500")
            #expect(response.header("x-big") == nil)
            #expect(response.body.isEmpty)
            #expect(response.finished)
        }
    }

    // MARK: Request body size

    @Test func declaredBodyOverTheLimitIs413WithoutCallingTheHandler() async throws {
        let called = Flag()
        let handler = ClosureHandler { _ in
            called.set()
            return HTTPResponse(status: .ok)
        }
        let configuration = H3Configuration(maxRequestBodySize: 10)
        let response = try await withH3Server(handler: handler, configuration: configuration) { client, _ in
            try await H3TestClient(transport: client).send(
                H3Wire.request(method: "POST", extra: [("content-length", "20")]), body: Array(repeating: 7, count: 20))
        }
        #expect(response.status == "413")
        #expect(!called.isSet)
    }

    @Test func undeclaredBodyGrowingPastTheLimitIs413() async throws {
        let failure = Mutex<(any Error)?>(nil)
        let handler = ClosureHandler { request in
            do {
                _ = try await request.body.collect(upTo: 1 << 20)
            } catch {
                failure.withLock { $0 = error }
                throw error
            }
            return HTTPResponse(status: .ok)
        }
        let configuration = H3Configuration(maxRequestBodySize: 10)
        let response = try await withH3Server(handler: handler, configuration: configuration) { client, _ in
            let h3 = H3TestClient(transport: client)
            let stream = try await h3.openRequest(
                H3Wire.headers(H3Wire.request(method: "POST")) + H3Wire.data(Array(repeating: 1, count: 8))
                    + H3Wire.data(Array(repeating: 2, count: 8)), fin: false)
            let response = await H3TestResponse.read(stream)
            // The rest of the body is refused.
            try await waitUntil { stream.receivedStopSendingCode != nil }
            #expect(stream.receivedStopSendingCode == HTTP3Error.noError.rawValue)
            return response
        }
        #expect(response.status == "413")
        #expect(failure.withLock { ($0 as? HTTPRequestBodyError) } == .tooLarge)
    }

    // MARK: Unread request body

    @Test func unreadBodyBeyondTheDrainSizeIsStoppedWithNoError() async throws {
        let configuration = H3Configuration(maxUnreadBodySize: 10, timeouts: H3Timeouts(unreadBody: nil))
        try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            let stream = try await H3TestClient(transport: client).openRequest(
                H3Wire.headers(H3Wire.request(method: "POST")) + H3Wire.data(Array(repeating: 1, count: 100)), fin: false)
            let response = await H3TestResponse.read(stream)
            #expect(response.status == "200")
            #expect(response.finished)
            try await waitUntil { stream.receivedStopSendingCode != nil }
            #expect(stream.receivedStopSendingCode == HTTP3Error.noError.rawValue)
        }
    }

    @Test func smallUnreadBodyIsDrainedToFin() async throws {
        let configuration = H3Configuration(timeouts: H3Timeouts(unreadBody: nil))
        try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            let stream = try await H3TestClient(transport: client).openRequest(
                H3Wire.headers(H3Wire.request(method: "POST")) + H3Wire.data([1, 2, 3]), fin: false)
            #expect(await H3TestResponse.read(stream).status == "200")
            try await stream.send(ByteBuffer(bytes: H3Wire.data([4, 5])), endOfStream: true)
            try await Task.sleep(for: .milliseconds(50))
            #expect(stream.receivedStopSendingCode == nil)
        }
    }

    // MARK: Timeouts

    @Test func requestWithoutHeadersIsRejectedAfterTheHeaderTimeout() async throws {
        let configuration = H3Configuration(timeouts: H3Timeouts(header: .milliseconds(100)))
        let (response, open) = try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            let h3 = H3TestClient(transport: client)
            // Half a HEADERS frame, then nothing.
            let stream = try await h3.openRequest(Array(H3Wire.headers(H3Wire.request()).prefix(3)), fin: false)
            let response = await H3TestResponse.read(stream)
            return (response, !client.isClosed)
        }
        #expect(response.resetCode == HTTP3Error.requestRejected.rawValue)
        #expect(open)
    }

    @Test func stalledBodyIsAnswered408() async throws {
        let configuration = H3Configuration(timeouts: H3Timeouts(body: .milliseconds(100)))
        try await withH3Server(handler: EchoHandler(), configuration: configuration) { client, _ in
            let stream = try await H3TestClient(transport: client).openRequest(
                H3Wire.headers(H3Wire.request(method: "POST", extra: [("content-length", "10")])) + H3Wire.data([1, 2, 3, 4, 5]),
                fin: false)
            let response = await H3TestResponse.read(stream)
            #expect(response.status == "408")
            #expect(response.finished)
            try await waitUntil { stream.receivedStopSendingCode != nil }
            #expect(stream.receivedStopSendingCode == HTTP3Error.noError.rawValue)
        }
    }

    @Test func slowHandlerIsNotLimitedByTheBodyTimeout() async throws {
        let handler = ClosureHandler { _ in
            try await Task.sleep(for: .milliseconds(300))
            return HTTPResponse(status: .ok, body: .bytes(ByteBuffer("late")))
        }
        let configuration = H3Configuration(timeouts: H3Timeouts(header: .milliseconds(100), body: .milliseconds(100)))
        let response = try await withH3Server(handler: handler, configuration: configuration) { client, _ in
            try await H3TestClient(transport: client).send()
        }
        #expect(response.bodyString == "late")
    }

    @Test func unreadBodyIsStoppedAfterTheUnreadBodyTimeout() async throws {
        let configuration = H3Configuration(timeouts: H3Timeouts(unreadBody: .milliseconds(100)))
        try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            let stream = try await H3TestClient(transport: client).openRequest(
                H3Wire.headers(H3Wire.request(method: "POST")) + H3Wire.data([1]), fin: false)
            let response = await H3TestResponse.read(stream)
            #expect(response.status == "200")
            #expect(response.finished)
            try await waitUntil { stream.receivedStopSendingCode != nil }
            #expect(stream.receivedStopSendingCode == HTTP3Error.noError.rawValue)
        }
    }

    @Test func idleConnectionSendsGoawayAndClosesWithNoError() async throws {
        let configuration = H3Configuration(timeouts: H3Timeouts(idle: .milliseconds(200)))
        try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            var inbound = client.inboundStreams.makeAsyncIterator()
            var control = H3ControlReader(stream: try #require(try await inbound.next()))
            let h3 = H3TestClient(transport: client)
            #expect(try await h3.send().status == "200")   // stream 0
            #expect(try await control.nextGoaway() == 4)
            #expect(await serverCloseCode(client) == HTTP3Error.noError.rawValue)
        }
    }

    @Test func openRequestKeepsTheConnectionFromIdling() async throws {
        let started = Flag()
        let release = Flag()
        let handler = ClosureHandler { _ in
            started.set()
            await release.wait()
            return HTTPResponse(status: .ok)
        }
        let configuration = H3Configuration(timeouts: H3Timeouts(idle: .milliseconds(100)))
        try await withH3Server(handler: handler, configuration: configuration) { client, _ in
            let stream = try await H3TestClient(transport: client).openRequest(H3Wire.headers(H3Wire.request()))
            await started.wait()
            try await Task.sleep(for: .milliseconds(400))
            #expect(!client.isClosed)
            release.set()
            #expect(await H3TestResponse.read(stream).status == "200")
            #expect(await serverCloseCode(client) == HTTP3Error.noError.rawValue)
        }
    }
}

/// #0102: the error-mapping table.
struct H3FailureTableTests {
    static let table: [(H3Failure, H3Failure.Signal)] = [
        (.malformedRequest, .resetStream(code: 0x10e)),
        (.incompleteRequest, .resetStream(code: 0x10d)),
        (.unservableFieldSection, .resetStream(code: 0x10e)),
        (.rejectedAfterGoaway, .resetStream(code: 0x10b)),
        (.rejectedOverConcurrencyLimit, .resetStream(code: 0x10b)),
        (.headerTimeout, .resetStream(code: 0x10b)),
        (.bodyTimeout, .resetStream(code: 0x10c)),
        (.requestCancelled, .resetStream(code: 0x10c)),
        (.sendTimeout, .resetStream(code: 0x10c)),
        (.responseFailed, .resetSending(code: 0x102)),
        (.unreadBodyAbandoned, .stopSending(code: 0x100)),
        (.unknownStreamType, .stopSending(code: 0x103)),
        (.protocolViolation(.frameUnexpected), .closeConnection(code: 0x105)),
        (.protocolViolation(.idError), .closeConnection(code: 0x108)),
        (.qpackFailure(code: 0x200), .closeConnection(code: 0x200)),
        (.localStreamFailure, .closeConnection(code: 0x102)),
        (.excessiveLoad(.abortedRequests), .closeConnection(code: 0x107)),
        (.excessiveLoad(.qpackInstructions), .closeConnection(code: 0x107)),
        (.gracefulShutdown, .closeConnection(code: 0x100)),
        (.idleTimeout, .closeConnection(code: 0x100)),
        (.drainTimeout, .closeConnection(code: 0x100)),
    ]

    @Test func everyFailureHasItsSignalAndScope() {
        for (failure, signal) in Self.table {
            #expect(failure.signal == signal, "\(failure)")
            let isConnection: Bool
            switch failure {
            case .protocolViolation, .qpackFailure, .localStreamFailure, .excessiveLoad, .gracefulShutdown, .idleTimeout, .drainTimeout:
                isConnection = true
            default:
                isConnection = false
            }
            #expect(failure.signal.isConnectionError == isConnection, "\(failure)")
        }
    }

    @Test func stateMachineErrorsMapIntoTheTable() {
        #expect(H3Failure(streamError: .requestIncomplete) == .incompleteRequest)
        #expect(H3Failure(streamError: .messageError) == .malformedRequest)
        #expect(H3Failure(connectionErrorCode: 0x106) == .protocolViolation(.frameError))
        #expect(H3Failure(connectionErrorCode: 0x201) == .qpackFailure(code: 0x201))
        // The connection state machine rejects streams with the table's codes.
        #expect(H3Failure.rejectedAfterGoaway.signal.code == HTTP3Error.requestRejected.rawValue)
    }
}

// MARK: - Support

/// Polls `condition` every 5 ms (the test's time limit bounds it).
func waitUntil(_ condition: () -> Bool) async throws {
    while !condition() { try await Task.sleep(for: .milliseconds(5)) }
}

/// A handler whose requests wait at a per-path gate.
final class Gates: Sendable {
    private let flags = Mutex<[String: (started: Flag, release: Flag)]>([:])

    private func entry(_ path: String) -> (started: Flag, release: Flag) {
        flags.withLock { flags in
            if let entry = flags[path] { return entry }
            let entry = (Flag(), Flag())
            flags[path] = entry
            return entry
        }
    }

    func started(_ path: String) -> Flag { entry(path).started }
    func release(_ path: String) { entry(path).release.set() }

    var handler: ClosureHandler {
        ClosureHandler { request in
            let entry = self.entry(request.string(of: request.path))
            entry.started.set()
            await entry.release.wait()
            return HTTPResponse(status: .ok)
        }
    }
}
