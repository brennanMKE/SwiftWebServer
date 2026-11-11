import Foundation
import HTTP3
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0101: request streams mapped to `HTTPHandler`, over the in-memory multiplexed transport.
@Suite(.timeLimit(.minutes(1)))
struct H3RequestStreamTests {
    static let frameOrderCases: [(String, [UInt8])] = {
        var cases: [(String, [UInt8])] = []
        cases.append(("DATA before HEADERS", H3Wire.data([1]) + H3Wire.headers(H3Wire.request())))
        cases.append(("HEADERS after trailers", H3Wire.headers(H3Wire.request()) + H3Wire.headers([("a", "b")]) + H3Wire.headers([("c", "d")])))
        cases.append(("DATA after trailers", H3Wire.headers(H3Wire.request()) + H3Wire.headers([("a", "b")]) + H3Wire.data([1])))
        cases.append(("SETTINGS on a request stream", H3Wire.headers(H3Wire.request()) + H3Wire.settings()))
        cases.append(("GOAWAY on a request stream", H3Wire.frame(.goaway, [0])))
        cases.append(("HTTP/2 PRIORITY frame", H3Wire.frame(H3FrameType(rawValue: 0x02), [0])))
        cases.append(("PUSH_PROMISE from a client", H3Wire.headers(H3Wire.request()) + H3Wire.frame(.pushPromise, [0, 0, 0])))
        return cases
    }()

    static let malformedCases: [(String, [(String, String)])] = {
        var cases: [(String, [(String, String)])] = []
        cases.append(("missing :path", [(":method", "GET"), (":scheme", "https"), (":authority", "a")]))
        cases.append(("missing :method", [(":scheme", "https"), (":authority", "a"), (":path", "/")]))
        cases.append(("missing :scheme", [(":method", "GET"), (":authority", "a"), (":path", "/")]))
        cases.append(("missing :authority and host", [(":method", "GET"), (":scheme", "https"), (":path", "/")]))
        cases.append(("empty :path", H3Wire.request(path: "")))
        cases.append(("uppercase name", H3Wire.request(extra: [("X-Upper", "1")])))
        cases.append(("connection field", H3Wire.request(extra: [("connection", "keep-alive")])))
        cases.append(("transfer-encoding field", H3Wire.request(extra: [("transfer-encoding", "chunked")])))
        cases.append(("te other than trailers", H3Wire.request(extra: [("te", "gzip")])))
        cases.append(("pseudo-header after regular field", [("accept", "*/*")] + H3Wire.request()))
        cases.append(("unknown pseudo-header", H3Wire.request(extra: [(":foo", "bar")])))
        cases.append(("duplicate :path", H3Wire.request(extra: [(":path", "/again")])))
        cases.append((":status in a request", [(":status", "200")] + H3Wire.request()))
        cases.append(("invalid content-length", H3Wire.request(extra: [("content-length", "abc")])))
        return cases
    }()

    // MARK: Round trips

    @Test func getRoundTrip() async throws {
        let response = try await withH3Server(handler: PathHandler()) { client, _ in
            try await H3TestClient(transport: client).send(H3Wire.request(path: "/index.html?x=1"))
        }
        #expect(response.finished)
        #expect(response.status == "200")
        #expect(response.headers.first?.name == ":status")
        #expect(response.header("content-type") == "text/plain")
        #expect(response.header("content-length") == "\("hello /index.html?x=1".utf8.count)")
        #expect(response.bodyString == "hello /index.html?x=1")
    }

    @Test func requestFieldsReachTheHandler() async throws {
        let seen = Mutex<[String]>([])
        let handler = ClosureHandler { request in
            seen.withLock {
                $0 = [
                    "\(request.method)", request.string(of: request.scheme), request.string(of: request.authority),
                    request.string(of: request.path), request.headers.firstValueString(for: .userAgent) ?? "-",
                    request.headers.firstValueString(for: .accept) ?? "-", "\(request.headers.count)",
                ]
            }
            return HTTPResponse(status: .noContent)
        }
        let response = try await withH3Server(handler: handler) { client, _ in
            try await H3TestClient(transport: client).send(H3Wire.request(
                method: "PUT", path: "/a/b", authority: "example.com:8443",
                extra: [("user-agent", "test/1"), ("accept", "*/*"), ("x-custom", "v")]))
        }
        #expect(response.status == "204")
        #expect(response.body.isEmpty && response.dataFrames == 0)
        #expect(seen.withLock { $0 } == ["PUT", "https", "example.com:8443", "/a/b", "test/1", "*/*", "3"])
    }

    @Test func hostFieldStandsInForAuthority() async throws {
        let response = try await withH3Server(handler: PathHandler()) { client, _ in
            try await H3TestClient(transport: client).send(
                [(":method", "GET"), (":scheme", "https"), (":path", "/h"), ("host", "localhost")])
        }
        #expect(response.status == "200")
    }

    @Test func headResponseHasNoContent() async throws {
        let response = try await withH3Server(handler: PathHandler()) { client, _ in
            try await H3TestClient(transport: client).send(H3Wire.request(method: "HEAD", path: "/x"))
        }
        #expect(response.status == "200")
        #expect(response.header("content-length") == "8")
        #expect(response.dataFrames == 0 && response.finished)
    }

    @Test func requestBodyIsEchoed() async throws {
        let response = try await withH3Server(handler: EchoHandler()) { client, _ in
            let h3 = H3TestClient(transport: client)
            let bytes = H3Wire.headers(H3Wire.request(method: "POST", extra: [("content-length", "11")]))
                + H3Wire.data(Array("hello ".utf8)) + H3Wire.frame(.reserved(2), [7]) + H3Wire.data(Array("world".utf8))
            return await H3TestResponse.read(try await h3.openRequest(bytes))
        }
        #expect(response.status == "200")
        #expect(response.bodyString == "hello world")
    }

    @Test func largeRequestBodyIsEchoedWithBackpressure() async throws {
        let payload = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let response = try await withH3Server(handler: EchoHandler()) { client, _ in
            let stream = try await client.openBidirectionalStream()
            return try await withThrowingTaskGroup(of: H3TestResponse?.self) { group in
                group.addTask {
                    try await stream.send(ByteBuffer(bytes: H3Wire.headers(H3Wire.request(method: "POST"))), endOfStream: false)
                    var offset = 0
                    while offset < payload.count {
                        let end = min(offset + 16 * 1024, payload.count)
                        try await stream.send(ByteBuffer(bytes: H3Wire.data(Array(payload[offset..<end]))), endOfStream: end == payload.count)
                        offset = end
                    }
                    return nil
                }
                group.addTask { await H3TestResponse.read(stream) }
                var result: H3TestResponse?
                for try await value in group where value != nil { result = value }
                return try #require(result)
            }
        }
        #expect(response.status == "200")
        #expect(response.body == payload)
    }

    @Test func trailersAreExposedOnTheBody() async throws {
        let handler = ClosureHandler { request in
            let body = try await request.body.collect(upTo: 1024)
            var headers = HTTPFields()
            let trailers = request.body.trailers
            let checksum = trailers.flatMap { trailers in trailers.firstValue(named: "x-checksum").map { trailers.string(of: $0) } }
            headers.append(name: "x-trailer", value: checksum ?? "none")
            return HTTPResponse(status: .ok, headers: headers, body: .bytes(body))
        }
        let response = try await withH3Server(handler: handler) { client, _ in
            let bytes = H3Wire.headers(H3Wire.request(method: "POST")) + H3Wire.data([1, 2, 3])
                + H3Wire.headers([("x-checksum", "6")])
            return await H3TestResponse.read(try await H3TestClient(transport: client).openRequest(bytes))
        }
        #expect(response.status == "200")
        #expect(response.body == [1, 2, 3])
        #expect(response.header("x-trailer") == "6")
    }

    @Test func bodyKeptAfterTheHandlerReturnsIsExpired() async throws {
        let kept = Mutex<HTTPRequestBody?>(nil)
        let handler = ClosureHandler { request in
            kept.withLock { $0 = request.body }
            return HTTPResponse(status: .ok)
        }
        let response = try await withH3Server(handler: handler) { client, _ in
            try await H3TestClient(transport: client).send(H3Wire.request(method: "POST"), body: [1])
        }
        #expect(response.status == "200")
        let body = try #require(kept.withLock { $0 })
        await #expect(throws: HTTPRequestBodyError.expired) { _ = try await body.collect(upTo: 10) }
    }

    @Test func malformedBodyIsReportedToTheHandler() async throws {
        let failure = Mutex<(any Error)?>(nil)
        let handler = ClosureHandler { request in
            do {
                _ = try await request.body.collect(upTo: 1024)
            } catch {
                failure.withLock { $0 = error }
                throw error
            }
            return HTTPResponse(status: .ok)
        }
        let response = try await withH3Server(handler: handler) { client, _ in
            try await H3TestClient(transport: client).send(
                H3Wire.request(method: "POST", extra: [("content-length", "2")]), body: [1, 2, 3])
        }
        #expect(response.resetCode == HTTP3Error.messageError.rawValue)
        #expect(failure.withLock { $0 as? HTTPRequestBodyError } == .malformed)
    }

    @Test func concurrentRequestsOnOneConnection() async throws {
        let responses = try await withH3Server(handler: PathHandler()) { client, _ in
            let h3 = H3TestClient(transport: client)
            return try await withThrowingTaskGroup(of: (Int, H3TestResponse).self) { group in
                for i in 0..<20 {
                    group.addTask { (i, try await h3.send(H3Wire.request(path: "/file\(i)"))) }
                }
                var all: [Int: H3TestResponse] = [:]
                for try await (i, response) in group { all[i] = response }
                return all
            }
        }
        #expect(responses.count == 20)
        for (i, response) in responses {
            #expect(response.status == "200")
            #expect(response.bodyString == "hello /file\(i)")
        }
    }

    // MARK: Response bodies

    @Test func streamedResponseIsSentAsDataFrames() async throws {
        let handler = ClosureHandler { _ in
            HTTPResponse(status: .ok, body: .stream(length: nil) { writer in
                for part in ["one ", "two ", "three"] { try await writer.write(ByteBuffer(bytes: Array(part.utf8))) }
            })
        }
        let response = try await withH3Server(handler: handler) { client, _ in
            try await H3TestClient(transport: client).send()
        }
        #expect(response.status == "200" && response.finished)
        #expect(response.header("content-length") == nil)
        #expect(response.dataFrames == 3)
        #expect(response.bodyString == "one two three")
    }

    @Test func fileResponseIsReadInChunks() async throws {
        let path = NSTemporaryDirectory() + "h3-file-\(UInt64.random(in: 0...UInt64.max)).bin"
        let contents = (0..<(200 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        #expect(FileManager.default.createFile(atPath: path, contents: Data(contents)))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let handler = ClosureHandler { _ in
            let file = try OwnedFileDescriptor.openForReading(path: path)
            return HTTPResponse(status: .ok, body: .file(try FileRegion.entireFile(file)))
        }
        let response = try await withH3Server(handler: handler) { client, _ in
            try await H3TestClient(transport: client).send()
        }
        #expect(response.status == "200" && response.finished)
        #expect(response.header("content-length") == "\(contents.count)")
        #expect(response.dataFrames == 1)
        #expect(response.body == contents)
    }

    @Test func connectionSpecificResponseFieldsAreDroppedAndNamesLowercased() async throws {
        let handler = ClosureHandler { _ in
            var headers = HTTPFields()
            headers.append(.connection, "close")
            headers.append(.transferEncoding, "chunked")
            headers.append(name: "X-Mixed-Case", value: "yes")
            return HTTPResponse(status: .ok, headers: headers, body: .bytes(ByteBuffer("ok")))
        }
        let response = try await withH3Server(handler: handler) { client, _ in
            try await H3TestClient(transport: client).send()
        }
        #expect(response.headers.map(\.name) == [":status", "x-mixed-case", "content-length"])
        #expect(response.bodyString == "ok")
    }

    // MARK: Frame-order violations (connection errors)

    @Test(arguments: H3RequestStreamTests.frameOrderCases)
    func frameOrderViolationsAreFrameUnexpected(name: String, bytes: [UInt8]) async throws {
        let code = try await withH3Server(handler: EchoHandler()) { client, _ in
            _ = try await H3TestClient(transport: client).openRequest(bytes)
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.frameUnexpected.rawValue, "\(name)")
    }

    @Test func streamEndingInsideAFrameIsFrameError() async throws {
        let code = try await withH3Server(handler: EchoHandler()) { client, _ in
            let truncated = H3Wire.headers(H3Wire.request(method: "POST")) + [0x00, 0x05, 1, 2]
            _ = try await H3TestClient(transport: client).openRequest(truncated)
            return await serverCloseCode(client)
        }
        #expect(code == HTTP3Error.frameError.rawValue)
    }

    @Test func dynamicTableReferenceIsDecompressionFailed() async throws {
        let code = try await withH3Server(handler: PathHandler()) { client, _ in
            // Required Insert Count 1: nothing was ever inserted into our zero-capacity table.
            _ = try await H3TestClient(transport: client).openRequest(H3Wire.frame(.headers, [0x01, 0x00, 0x80]))
            return await serverCloseCode(client)
        }
        #expect(code == 0x0200)
    }

    // MARK: Malformed requests (stream errors)

    @Test(arguments: H3RequestStreamTests.malformedCases)
    func malformedRequestsResetTheStreamWithMessageError(name: String, fields: [(String, String)]) async throws {
        let (malformed, followUp) = try await withH3Server(handler: PathHandler()) { client, _ in
            let h3 = H3TestClient(transport: client)
            return (try await h3.send(fields), try await h3.send())
        }
        #expect(malformed.resetCode == HTTP3Error.messageError.rawValue, "\(name)")
        #expect(malformed.status == nil, "\(name)")
        // A stream error leaves the connection usable.
        #expect(followUp.status == "200", "\(name)")
    }

    @Test(arguments: [
        ("more DATA than content-length", 3, [1, 2, 3, 4] as [UInt8]),
        ("less DATA than content-length", 5, [1, 2, 3] as [UInt8]),
    ])
    func contentLengthMismatchIsMessageError(name: String, declared: Int, body: [UInt8]) async throws {
        let response = try await withH3Server(handler: EchoHandler()) { client, _ in
            try await H3TestClient(transport: client).send(
                H3Wire.request(method: "POST", extra: [("content-length", "\(declared)")]), body: body)
        }
        #expect(response.resetCode == HTTP3Error.messageError.rawValue, "\(name)")
    }

    @Test func pseudoHeaderInTrailersIsMessageError() async throws {
        let response = try await withH3Server(handler: EchoHandler()) { client, _ in
            let bytes = H3Wire.headers(H3Wire.request(method: "POST")) + H3Wire.data([1]) + H3Wire.headers([(":path", "/")])
            return await H3TestResponse.read(try await H3TestClient(transport: client).openRequest(bytes))
        }
        #expect(response.resetCode == HTTP3Error.messageError.rawValue)
    }

    @Test func streamEndingBeforeHeadersIsRequestIncomplete() async throws {
        let response = try await withH3Server(handler: PathHandler()) { client, _ in
            await H3TestResponse.read(try await H3TestClient(transport: client).openRequest(H3Wire.frame(.reserved(1), [])))
        }
        #expect(response.resetCode == HTTP3Error.requestIncomplete.rawValue)
    }

    @Test func oversizedFieldSectionIsAnswered431() async throws {
        let configuration = H3Configuration(maxFieldSectionSize: 256)
        let response = try await withH3Server(handler: PathHandler(), configuration: configuration) { client, _ in
            try await H3TestClient(transport: client).send(
                H3Wire.request(extra: [("x-big", String(repeating: "a", count: 400))]))
        }
        #expect(response.status == "431")
    }

    // MARK: Cancellation and handler errors

    @Test func peerResetCancelsTheHandler() async throws {
        let started = Flag()
        let cancelled = Flag()
        let handler = ClosureHandler { request in
            guard request.string(of: request.path) == "/slow" else {
                return HTTPResponse(status: .ok, body: .bytes(ByteBuffer("fast")))
            }
            started.set()
            do {
                try await Task.sleep(for: .seconds(50))
            } catch {
                cancelled.set()
                throw error
            }
            return HTTPResponse(status: .ok)
        }
        let followUp = try await withH3Server(handler: handler) { client, _ in
            let h3 = H3TestClient(transport: client)
            let stream = try await h3.openRequest(H3Wire.headers(H3Wire.request(path: "/slow")), fin: false)
            await started.wait()
            await stream.reset(applicationError: HTTP3Error.requestCancelled.rawValue)
            await cancelled.wait()
            return try await h3.send()
        }
        #expect(cancelled.isSet)
        #expect(followUp.bodyString == "fast")
    }

    @Test func peerResetWhileHandlerReadsBodyCancelsIt() async throws {
        let failure = Mutex<String?>(nil)
        let started = Flag()
        let handler = ClosureHandler { request in
            started.set()
            do {
                _ = try await request.body.collect(upTo: 1 << 20)
                failure.withLock { $0 = "completed" }
            } catch {
                failure.withLock { $0 = "\(type(of: error))" }
                throw error
            }
            return HTTPResponse(status: .ok)
        }
        try await withH3Server(handler: handler) { client, _ in
            let h3 = H3TestClient(transport: client)
            let stream = try await h3.openRequest(H3Wire.headers(H3Wire.request(method: "POST")) + H3Wire.data([1]), fin: false)
            // Reset only once the server has the head (a reset discards unread bytes).
            await started.wait()
            await stream.reset(applicationError: HTTP3Error.requestCancelled.rawValue)
            while failure.withLock({ $0 }) == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(failure.withLock { $0 } != "completed")
    }

    @Test func handlerThrowingBeforeTheHeadGets500() async throws {
        let response = try await withH3Server(handler: ClosureHandler { _ in throw TestError() }) { client, _ in
            try await H3TestClient(transport: client).send()
        }
        #expect(response.status == "500")
        #expect(response.finished)
    }

    @Test func bodyWriterThrowingAfterTheHeadResetsWithInternalError() async throws {
        let handler = ClosureHandler { _ in
            HTTPResponse(status: .ok, body: .stream(length: nil) { writer in
                try await writer.write(ByteBuffer("partial"))
                throw TestError()
            })
        }
        let response = try await withH3Server(handler: handler) { client, _ in
            try await H3TestClient(transport: client).send()
        }
        #expect(response.resetCode == HTTP3Error.internalError.rawValue)
        #expect(!response.finished)
    }
}

/// #0101: the pure request-stream state machine.
struct H3RequestStreamStateTests {
    @Test func headersDataTrailersFin() {
        var stream = H3RequestStream()
        #expect(stream.handle(.headers) == .decodeRequestHead)
        #expect(stream.handle(.requestHead(contentLength: 5)) == .none)
        #expect(stream.handle(.dataFrame(length: 2)) == .deliverData)
        #expect(stream.handle(.dataFrame(length: 3)) == .deliverData)
        #expect(stream.handle(.headers) == .decodeTrailers)
        #expect(stream.handle(.endOfStream) == .finishBody)
        #expect(stream.state == .finished)
    }

    @Test func outOfOrderFrames() {
        var stream = H3RequestStream()
        #expect(stream.handle(.dataFrame(length: 1)) == .connectionError(.frameUnexpected))
        #expect(stream.handle(.headers) == .none)   // failed: ignored

        stream = H3RequestStream()
        _ = stream.handle(.headers)
        _ = stream.handle(.requestHead(contentLength: nil))
        _ = stream.handle(.headers)
        #expect(stream.handle(.dataFrame(length: 1)) == .connectionError(.frameUnexpected))

        stream = H3RequestStream()
        _ = stream.handle(.headers)
        _ = stream.handle(.requestHead(contentLength: nil))
        _ = stream.handle(.headers)
        #expect(stream.handle(.headers) == .connectionError(.frameUnexpected))
    }

    @Test func contentLengthAndIncompleteRequests() {
        var stream = H3RequestStream()
        #expect(stream.handle(.endOfStream) == .streamError(.requestIncomplete))

        stream = H3RequestStream()
        _ = stream.handle(.headers)
        _ = stream.handle(.requestHead(contentLength: 3))
        #expect(stream.handle(.dataFrame(length: 4)) == .streamError(.messageError))

        stream = H3RequestStream()
        _ = stream.handle(.headers)
        _ = stream.handle(.requestHead(contentLength: 3))
        #expect(stream.handle(.dataFrame(length: 2)) == .deliverData)
        #expect(stream.handle(.endOfStream) == .streamError(.messageError))

        stream = H3RequestStream()
        _ = stream.handle(.headers)
        _ = stream.handle(.requestHead(contentLength: nil))
        #expect(stream.handle(.dataFrame(length: .max)) == .deliverData)
        #expect(stream.handle(.dataFrame(length: 1)) == .streamError(.messageError))
    }
}
