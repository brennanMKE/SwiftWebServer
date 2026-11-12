import HTTP3
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0104: a peer abort cancels the request's tasks, and a cancelled handler resets the stream
/// with `H3_REQUEST_CANCELLED`, over the in-memory multiplexed transport.
@Suite(.timeLimit(.minutes(1)))
struct H3CancellationTests {
    static let requestCancelled = HTTP3Error.requestCancelled.rawValue

    /// What a client does when it gives up on a request: RESET_STREAM and STOP_SENDING.
    static func abandon(_ stream: MuxStream) async {
        await stream.reset(applicationError: requestCancelled)
        await stream.stopSending(applicationError: requestCancelled)
    }

    @Test func peerResetCancelsAHandlerThatIsStillComputing() async throws {
        let started = Flag()
        let cancelled = Flag()
        let handler = ClosureHandler { request in
            guard request.string(of: request.path) == "/slow" else { return HTTPResponse(status: .ok) }
            started.set()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                #expect(error is CancellationError)
                cancelled.set()
                throw error
            }
            return HTTPResponse(status: .ok)
        }
        let tracker = H3ConnectionTracker()
        try await withH3Server(handler: handler, tracker: tracker) { client, _ in
            let h3 = H3TestClient(transport: client)
            // The request is complete (FIN), so the body reader has nothing left to read: only
            // the abort watcher can notice the reset.
            let stream = try await h3.openRequest(H3Wire.headers(H3Wire.request(path: "/slow")))
            await started.wait()
            await Self.abandon(stream)
            await cancelled.wait()
            try await waitUntil { tracker.liveRequestStreams == 0 && tracker.liveHandlers == 0 }
            #expect(stream.receivedResetCode == Self.requestCancelled)
            #expect(try await h3.send().status == "200")
            #expect(!client.isClosed)
        }
    }

    @Test func peerResetMidDownloadEndsTheWriterAndTheConnectionServesAnotherStream() async throws {
        let writerEnded = Flag()
        let chunk = ByteBuffer(bytes: Array(repeating: 0x42, count: 8 * 1024))
        let handler = ClosureHandler { request in
            guard request.string(of: request.path) == "/download" else {
                return HTTPResponse(status: .ok, body: .bytes(ByteBuffer("next")))
            }
            return HTTPResponse(status: .ok, body: .stream(length: nil) { writer in
                defer { writerEnded.set() }
                while true { try await writer.write(chunk) }
            })
        }
        let tracker = H3ConnectionTracker()
        try await withH3Server(handler: handler, tracker: tracker) { client, _ in
            let h3 = H3TestClient(transport: client)
            let download = try await h3.openRequest(H3Wire.headers(H3Wire.request(path: "/download")))
            let received = try await receive(64 * 1024, from: download)
            #expect(received.count >= 64 * 1024)
            await Self.abandon(download)
            await writerEnded.wait()
            try await waitUntil { tracker.liveRequestStreams == 0 && tracker.liveBodyChannels == 0 }
            #expect(try await h3.send(H3Wire.request(path: "/next")).bodyString == "next")
            #expect(!client.isClosed)
        }
    }

    @Test func peerResetDuringAnUploadFailsTheBodyReadAndEndsTheHandler() async throws {
        let failure = Mutex<(any Error)?>(nil)
        let firstChunk = Flag()
        let handler = ClosureHandler { request in
            do {
                for try await _ in request.body { firstChunk.set() }
            } catch {
                failure.withLock { $0 = error }
                throw error
            }
            return HTTPResponse(status: .ok)
        }
        let tracker = H3ConnectionTracker()
        try await withH3Server(handler: handler, tracker: tracker) { client, _ in
            let stream = try await H3TestClient(transport: client).openRequest(
                H3Wire.headers(H3Wire.request(method: "POST")) + H3Wire.data([1, 2, 3]), fin: false)
            await firstChunk.wait()
            await Self.abandon(stream)
            try await waitUntil { tracker.liveHandlers == 0 && tracker.liveRequestStreams == 0 }
            let error = failure.withLock { $0 }
            #expect(error is CancellationError || (error as? TransportError) == .connectionReset)
            #expect(!client.isClosed)
        }
    }

    @Test(arguments: [false, true])
    func handlerCancellationResetsWithRequestCancelled(afterHeadersOnly: Bool) async throws {
        let handler = ClosureHandler { _ in
            if afterHeadersOnly {
                // A handler whose own child work was cancelled.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await Task.sleep(for: .seconds(60)) }
                    group.cancelAll()
                    try await group.waitForAll()
                }
            }
            throw CancellationError()
        }
        let response = try await withH3Server(handler: handler) { client, _ in
            try await H3TestClient(transport: client).send()
        }
        #expect(response.resetCode == Self.requestCancelled)
        #expect(response.status == nil)
        #expect(!response.finished)
    }

    @Test func aThrowingBodyWriterResetsWithInternalError() async throws {
        let handler = ClosureHandler { _ in
            HTTPResponse(status: .ok, body: .stream(length: nil) { writer in
                try await writer.write(ByteBuffer("part"))
                throw TestError()
            })
        }
        let response = try await withH3Server(handler: handler) { client, _ in
            try await H3TestClient(transport: client).send()
        }
        #expect(response.resetCode == HTTP3Error.internalError.rawValue)
        #expect(!response.finished)
    }

    /// 1,000 requests abandoned by the client, half while the handler computes after the
    /// request ended and half while it reads an unfinished upload: every handler is cancelled,
    /// and no request stream task, handler or body channel (with its queue waiters) is left.
    @Test func thousandCancelledRequestsLeaveNothingBehind() async throws {
        let started = Mutex(0)
        let cancelled = Mutex(0)
        let handler = ClosureHandler { request in
            if request.string(of: request.path) == "/after" { return HTTPResponse(status: .ok) }
            started.withLock { $0 += 1 }
            do {
                if request.method == .post {
                    for try await _ in request.body {}
                }
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled.withLock { $0 += 1 }
                throw error
            }
            return HTTPResponse(status: .ok)
        }
        // The rapid-reset limit would (rightly) close this connection.
        let configuration = H3Configuration(abuseLimits: H3AbuseLimits(maxAbortedRequestsPerWindow: nil))
        let tracker = H3ConnectionTracker()
        let total = 1000
        let batch = 50
        try await withH3Server(handler: handler, configuration: configuration, tracker: tracker) { client, _ in
            let h3 = H3TestClient(transport: client)
            for round in 0..<(total / batch) {
                let upload = round % 2 == 1
                var streams: [MuxStream] = []
                for _ in 0..<batch {
                    let bytes = upload
                        ? H3Wire.headers(H3Wire.request(method: "POST")) + H3Wire.data([1, 2, 3])
                        : H3Wire.headers(H3Wire.request(path: "/compute"))
                    streams.append(try await h3.openRequest(bytes, fin: !upload))
                }
                let target = (round + 1) * batch
                try await waitUntil { started.withLock { $0 } == target }
                for stream in streams { await Self.abandon(stream) }
                try await waitUntil { cancelled.withLock { $0 } == target }
            }
            try await waitUntil {
                tracker.liveRequestStreams == 0 && tracker.liveHandlers == 0 && tracker.liveBodyChannels == 0
            }
            #expect(started.withLock { $0 } == total)
            #expect(cancelled.withLock { $0 } == total)
            #expect(try await h3.send(H3Wire.request(path: "/after")).status == "200")
            #expect(!client.isClosed)
        }
        #expect(tracker.liveConnections == 0)
        #expect(tracker.liveRequestStreams == 0)
        #expect(tracker.liveBodyChannels == 0)
    }
}
