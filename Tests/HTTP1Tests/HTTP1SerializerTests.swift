import Synchronization
import Testing
import HTTPCore
import HTTP1

/// A clock the test sets by hand.
final class SerializerTestClock: WallClock {
    let seconds: Atomic<Int64>

    init(_ seconds: Int64) {
        self.seconds = Atomic(seconds)
    }

    func set(_ value: Int64) {
        seconds.store(value, ordering: .relaxed)
    }

    func secondsSinceEpoch() -> Int64 {
        seconds.load(ordering: .relaxed)
    }
}

private let dateLine = "date: Sun, 06 Nov 1994 08:49:37 GMT\r\n"

private func makeSerializer(_ seconds: Int64 = 784_111_777) -> HTTP1Serializer<SerializerTestClock> {
    HTTP1Serializer(clock: SerializerTestClock(seconds))
}

private func text(_ buffer: ByteBuffer) -> String {
    buffer.withReadableSpan { ASCII.string(from: $0) }
}

private func serialize(
    _ response: HTTPResponse, method: HTTPMethod = .get, persistence: HTTP1ResponseContext.Persistence = .keepAlive
) -> (String, HTTP1BodyFraming) {
    var serializer = makeSerializer()
    var buffer = ByteBuffer()
    let framing = serializer.write(response, into: &buffer,
                                   context: HTTP1ResponseContext(requestMethod: method, persistence: persistence))
    return (text(buffer), framing)
}

private func fields(_ pairs: [(String, String)]) -> HTTPFields {
    var fields = HTTPFields()
    for (name, value) in pairs { fields.append(name: name, value: value) }
    return fields
}

private let noopWriter: @Sendable (any HTTPBodyWriter) async throws -> Void = { _ in }

@Suite struct HTTP1SerializerTests {
    // MARK: Typical responses

    @Test func okWithBody() {
        let response = HTTPResponse(status: .ok, headers: fields([("Content-Type", "text/plain")]),
                                    body: .bytes(ByteBuffer("hello")))
        let (bytes, framing) = serialize(response)
        #expect(bytes == "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n" + dateLine
                + "content-length: 5\r\nconnection: keep-alive\r\n\r\nhello")
        #expect(framing == .complete)
    }

    @Test func okEmptyBodyStatesZeroLength() {
        let (bytes, framing) = serialize(HTTPResponse())
        #expect(bytes == "HTTP/1.1 200 OK\r\n" + dateLine + "content-length: 0\r\nconnection: keep-alive\r\n\r\n")
        #expect(framing == .complete)
    }

    @Test func notFoundWithClose() {
        let response = HTTPResponse(status: .notFound, headers: fields([("content-type", "text/html")]),
                                    body: .bytes(ByteBuffer("<h1>Not Found</h1>")))
        let (bytes, _) = serialize(response, persistence: .close)
        #expect(bytes == "HTTP/1.1 404 Not Found\r\ncontent-type: text/html\r\n" + dateLine
                + "content-length: 18\r\nconnection: close\r\n\r\n<h1>Not Found</h1>")
    }

    @Test func unregisteredStatusIsRenderedDigitByDigit() {
        let (bytes, _) = serialize(HTTPResponse(status: HTTPStatus(code: 299)))
        #expect(bytes.hasPrefix("HTTP/1.1 299 \r\n"))
        let (custom, _) = serialize(HTTPResponse(status: HTTPStatus(code: 200, reasonPhrase: "Fine")))
        #expect(custom.hasPrefix("HTTP/1.1 200 Fine\r\n"))
    }

    @Test func fiveHeaderResponse() {
        var headers = HTTPFields()
        headers.append(.contentType, "text/html; charset=utf-8")
        headers.append(.cacheControl, "no-cache")
        headers.append(.server, "sws")
        headers.append(.vary, "accept-encoding")
        headers.append(.etag, "\"abc\"")
        let (bytes, _) = serialize(HTTPResponse(headers: headers, body: .bytes(ByteBuffer("<p>hi</p>"))))
        #expect(bytes == """
            HTTP/1.1 200 OK\r
            content-type: text/html; charset=utf-8\r
            cache-control: no-cache\r
            server: sws\r
            vary: accept-encoding\r
            etag: "abc"\r
            date: Sun, 06 Nov 1994 08:49:37 GMT\r
            content-length: 9\r
            connection: keep-alive\r
            \r
            <p>hi</p>
            """)
    }

    // MARK: Header order

    @Test func headerOrderAndDuplicatesArePreserved() {
        let headers = fields([
            ("Set-Cookie", "a=1"),
            ("X-Custom", "one"),
            ("Content-Type", "text/plain"),
            ("set-cookie", "b=2"),
            ("x-custom", "two"),
            ("Cache-Control", "no-store"),
        ])
        let (bytes, _) = serialize(HTTPResponse(headers: headers))
        #expect(bytes == "HTTP/1.1 200 OK\r\nset-cookie: a=1\r\nX-Custom: one\r\ncontent-type: text/plain\r\n"
                + "set-cookie: b=2\r\nx-custom: two\r\ncache-control: no-store\r\n" + dateLine
                + "content-length: 0\r\nconnection: keep-alive\r\n\r\n")
    }

    @Test func suppliedDateIsKept() {
        let headers = fields([("Date", "Mon, 07 Nov 1994 00:00:00 GMT")])
        let (bytes, _) = serialize(HTTPResponse(headers: headers))
        #expect(bytes == "HTTP/1.1 200 OK\r\ndate: Mon, 07 Nov 1994 00:00:00 GMT\r\n"
                + "content-length: 0\r\nconnection: keep-alive\r\n\r\n")
    }

    @Test func framingAndConnectionFieldsAreOwnedByTheSerializer() {
        let headers = fields([
            ("Connection", "keep-alive"),
            ("Content-Length", "5"),
            ("Transfer-Encoding", "identity"),
            ("X-A", "1"),
        ])
        let (bytes, _) = serialize(HTTPResponse(headers: headers, body: .bytes(ByteBuffer("hello"))), persistence: .close)
        #expect(bytes == "HTTP/1.1 200 OK\r\nX-A: 1\r\n" + dateLine
                + "content-length: 5\r\nconnection: close\r\n\r\nhello")
    }

    // MARK: Body rules

    @Test func noContentHasNoFramingOrBody() {
        let (bytes, framing) = serialize(HTTPResponse(status: .noContent, body: .bytes(ByteBuffer("ignored"))))
        #expect(bytes == "HTTP/1.1 204 No Content\r\n" + dateLine + "connection: keep-alive\r\n\r\n")
        #expect(framing == .complete)
        let (stream, streamFraming) = serialize(HTTPResponse(status: .noContent, body: .stream(length: nil, writer: noopWriter)))
        #expect(stream == bytes)
        #expect(streamFraming == .complete)
    }

    @Test func notModifiedWithoutBodyHasNoContentLength() {
        let headers = fields([("ETag", "\"v1\"")])
        let (bytes, framing) = serialize(HTTPResponse(status: .notModified, headers: headers))
        #expect(bytes == "HTTP/1.1 304 Not Modified\r\netag: \"v1\"\r\n" + dateLine + "connection: keep-alive\r\n\r\n")
        #expect(framing == .complete)
    }

    @Test func notModifiedKeepsTheHandlersContentLength() {
        // RFC 9110 §8.6: a 304 may state the length a 200 would have had.
        let headers = fields([("ETag", "\"v1\""), ("Content-Length", "1234")])
        let (bytes, _) = serialize(HTTPResponse(status: .notModified, headers: headers))
        #expect(bytes == "HTTP/1.1 304 Not Modified\r\netag: \"v1\"\r\ncontent-length: 1234\r\n" + dateLine
                + "connection: keep-alive\r\n\r\n")
    }

    @Test func notModifiedWithBodyStatesLengthButSendsNothing() {
        let (bytes, framing) = serialize(HTTPResponse(status: .notModified, body: .bytes(ByteBuffer("hello"))))
        #expect(bytes == "HTTP/1.1 304 Not Modified\r\n" + dateLine + "content-length: 5\r\nconnection: keep-alive\r\n\r\n")
        #expect(framing == .complete)
    }

    @Test func headStatesTheGetLengthWithoutContent() {
        let (bytes, framing) = serialize(HTTPResponse(body: .bytes(ByteBuffer("hello"))), method: .head)
        #expect(bytes == "HTTP/1.1 200 OK\r\n" + dateLine + "content-length: 5\r\nconnection: keep-alive\r\n\r\n")
        #expect(framing == .complete)

        let (stream, streamFraming) = serialize(HTTPResponse(body: .stream(length: 42, writer: noopWriter)), method: .head)
        #expect(stream == "HTTP/1.1 200 OK\r\n" + dateLine + "content-length: 42\r\nconnection: keep-alive\r\n\r\n")
        #expect(streamFraming == .complete)
    }

    @Test func headWithEmptyOrChunkedBodyStatesNoLength() {
        let expected = "HTTP/1.1 200 OK\r\n" + dateLine + "connection: keep-alive\r\n\r\n"
        let (empty, _) = serialize(HTTPResponse(), method: .head)
        #expect(empty == expected)
        let (chunked, framing) = serialize(HTTPResponse(body: .stream(length: nil, writer: noopWriter)), method: .head)
        #expect(chunked == expected)
        #expect(framing == .complete)
        let (handlerLength, _) = serialize(HTTPResponse(headers: fields([("Content-Length", "99")])), method: .head)
        #expect(handlerLength == "HTTP/1.1 200 OK\r\ncontent-length: 99\r\n" + dateLine + "connection: keep-alive\r\n\r\n")
    }

    @Test func streamWithLengthLeavesTheBodyToTheRunner() {
        let (bytes, framing) = serialize(HTTPResponse(body: .stream(length: 42, writer: noopWriter)))
        #expect(bytes == "HTTP/1.1 200 OK\r\n" + dateLine + "content-length: 42\r\nconnection: keep-alive\r\n\r\n")
        #expect(framing == .contentLength(42))
    }

    @Test func fileBodyWritesOnlyTheHead() throws {
        let file = try OwnedFileDescriptor.openForReading(path: "/dev/null")
        let region = FileRegion(file: file, offset: 10, length: 1_000_000)
        let (bytes, framing) = serialize(HTTPResponse(headers: fields([("Content-Type", "image/png")]), body: .file(region)))
        #expect(bytes == "HTTP/1.1 200 OK\r\ncontent-type: image/png\r\n" + dateLine
                + "content-length: 1000000\r\nconnection: keep-alive\r\n\r\n")
        #expect(framing == .contentLength(1_000_000))
        let (head, headFraming) = serialize(HTTPResponse(body: .file(region)), method: .head)
        #expect(head == "HTTP/1.1 200 OK\r\n" + dateLine + "content-length: 1000000\r\nconnection: keep-alive\r\n\r\n")
        #expect(headFraming == .complete)
    }

    @Test func informationalResponsesCarryOnlyTheHandlersFields() {
        let (continueBytes, continueFraming) = serialize(HTTPResponse(status: .continue))
        #expect(continueBytes == "HTTP/1.1 100 Continue\r\n\r\n")
        #expect(continueFraming == .complete)

        let headers = fields([("Upgrade", "websocket"), ("Connection", "Upgrade"),
                              ("Sec-WebSocket-Accept", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")])
        let (upgrade, framing) = serialize(HTTPResponse(status: .switchingProtocols, headers: headers,
                                                        body: .tunnel({ _ in })))
        #expect(upgrade == "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n"
                + "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n")
        #expect(framing == .tunnel)

        let (hints, _) = serialize(HTTPResponse(status: .earlyHints, headers: fields([("Link", "</a.css>; rel=preload")])))
        #expect(hints == "HTTP/1.1 103 Early Hints\r\nlink: </a.css>; rel=preload\r\n\r\n")
    }

    @Test func tunnelAfterConnectHasNoFraming() {
        let (bytes, framing) = serialize(HTTPResponse(body: .tunnel({ _ in })), method: .connect)
        #expect(bytes == "HTTP/1.1 200 OK\r\n" + dateLine + "\r\n")
        #expect(framing == .tunnel)
    }

    // MARK: Chunked

    @Test func chunkedResponse() {
        var serializer = makeSerializer()
        var buffer = ByteBuffer()
        let framing = serializer.write(HTTPResponse(headers: fields([("Content-Type", "text/plain")]),
                                                    body: .stream(length: nil, writer: noopWriter)),
                                       into: &buffer, context: HTTP1ResponseContext())
        #expect(framing == .chunked)
        HTTP1ChunkedEncoder.appendChunk(ByteBuffer("hello"), into: &buffer)
        HTTP1ChunkedEncoder.appendChunk(ByteBuffer(), into: &buffer)   // no-op, must not end the body
        HTTP1ChunkedEncoder.appendChunk(ByteBuffer(bytes: [UInt8](repeating: 0x61, count: 300)), into: &buffer)
        HTTP1ChunkedEncoder.appendLastChunk(into: &buffer)
        #expect(text(buffer) == "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n" + dateLine
                + "transfer-encoding: chunked\r\nconnection: keep-alive\r\n\r\n"
                + "5\r\nhello\r\n"
                + "12c\r\n" + String(repeating: "a", count: 300) + "\r\n"
                + "0\r\n\r\n")
    }

    @Test func chunkHeaderAndEndAroundSeparateBytes() {
        var buffer = ByteBuffer()
        HTTP1ChunkedEncoder.appendChunkHeader(size: 0xABCDEF, into: &buffer)
        HTTP1ChunkedEncoder.appendChunkEnd(into: &buffer)
        HTTP1ChunkedEncoder.appendChunkHeader(size: 1, into: &buffer)
        #expect(text(buffer) == "abcdef\r\n\r\n1\r\n")
    }

    @Test func lastChunkWithTrailers() {
        var buffer = ByteBuffer()
        HTTP1ChunkedEncoder.appendLastChunk(trailers: fields([("Server-Timing", "db;dur=53"), ("X-Checksum", "abc")]),
                                            into: &buffer)
        #expect(text(buffer) == "0\r\nServer-Timing: db;dur=53\r\nX-Checksum: abc\r\n\r\n")
    }

    // MARK: Buffer reuse and date refresh

    @Test func pipelinedResponsesAppendToTheSameBuffer() {
        var serializer = makeSerializer()
        var buffer = ByteBuffer(capacity: 16)
        serializer.write(HTTPResponse(body: .bytes(ByteBuffer("a"))), into: &buffer, context: HTTP1ResponseContext())
        serializer.write(HTTPResponse(status: .noContent), into: &buffer, context: HTTP1ResponseContext(persistence: .close))
        #expect(text(buffer) == "HTTP/1.1 200 OK\r\n" + dateLine + "content-length: 1\r\nconnection: keep-alive\r\n\r\na"
                + "HTTP/1.1 204 No Content\r\n" + dateLine + "connection: close\r\n\r\n")
    }

    @Test func dateChangesAfterOneSecond() {
        let clock = SerializerTestClock(784_111_777)
        var serializer = HTTP1Serializer(clock: clock)
        var buffer = ByteBuffer()
        serializer.write(HTTPResponse(), into: &buffer, context: HTTP1ResponseContext())
        #expect(text(buffer).contains("date: Sun, 06 Nov 1994 08:49:37 GMT\r\n"))
        buffer.clear()
        clock.set(784_111_778)
        serializer.write(HTTPResponse(), into: &buffer, context: HTTP1ResponseContext())
        #expect(text(buffer).contains("date: Sun, 06 Nov 1994 08:49:38 GMT\r\n"))
    }

    @Test func systemClockSerializer() {
        var serializer = HTTP1Serializer()
        var buffer = ByteBuffer()
        serializer.write(HTTPResponse(), into: &buffer, context: HTTP1ResponseContext())
        let bytes = text(buffer)
        #expect(bytes.hasPrefix("HTTP/1.1 200 OK\r\ndate: "))
        #expect(bytes.contains(" GMT\r\ncontent-length: 0\r\n"))
    }

    // MARK: Validation

    @Test(arguments: ["a\r\nSet-Cookie: x=1", "a\nb", "a\rb", "a\u{0}b", "a\u{7F}b"])
    func validatedWriteRejectsSplittingValues(value: String) {
        var serializer = makeSerializer()
        var buffer = ByteBuffer("prefix")
        let response = HTTPResponse(headers: fields([("X-Ok", "fine"), ("Location", value)]))
        #expect(throws: HTTP1SerializationError.invalidFieldValue(position: 1)) {
            try serializer.writeValidated(response, into: &buffer, context: HTTP1ResponseContext())
        }
        #expect(text(buffer) == "prefix")
    }

    @Test func validatedWriteRejectsBadNames() {
        var serializer = makeSerializer()
        var buffer = ByteBuffer()
        let response = HTTPResponse(headers: fields([("Bad Name", "x")]))
        #expect(throws: HTTP1SerializationError.invalidFieldName(position: 0)) {
            try serializer.writeValidated(response, into: &buffer, context: HTTP1ResponseContext())
        }
        #expect(buffer.isEmpty)
    }

    @Test func validatedWriteAcceptsTabsAndObsText() throws {
        var serializer = makeSerializer()
        var buffer = ByteBuffer()
        var headers = HTTPFields()
        [UInt8](arrayLiteral: 0x61, 0x09, 0x20, 0xE2, 0x82, 0xAC).withUnsafeBufferPointer { value in
            headers.append(.server, value: value.span)
        }
        let framing = try serializer.writeValidated(HTTPResponse(headers: headers), into: &buffer,
                                                    context: HTTP1ResponseContext())
        #expect(framing == .complete)
        #expect(text(buffer).hasPrefix("HTTP/1.1 200 OK\r\nserver: a\t \u{20AC}\r\n"))
    }

    @Test func longestWellKnownNameFitsTheBound() {
        let longest = HTTPFieldName.allCases.map { $0.canonicalName.utf8CodeUnitCount }.max()
        #expect(longest == HTTP1Serializer<SystemWallClock>.maximumWellKnownNameLength)
    }

    @Test func everyWellKnownNameIsWrittenInLowercase() {
        var headers = HTTPFields()
        for name in HTTPFieldName.allCases where name.isWellKnown && name.rawValue > HTTPFieldName.pseudoProtocol.rawValue
            && ![.contentLength, .transferEncoding, .connection, .date].contains(name) {
            headers.append(name, "v")
        }
        var serializer = makeSerializer()
        var buffer = ByteBuffer(capacity: 1)
        serializer.write(HTTPResponse(headers: headers), into: &buffer, context: HTTP1ResponseContext())
        var expected = "HTTP/1.1 200 OK\r\n"
        for i in 0..<headers.count { expected += "\(headers[i].name.canonicalName): v\r\n" }
        expected += dateLine + "content-length: 0\r\nconnection: keep-alive\r\n\r\n"
        #expect(text(buffer) == expected)
    }

    @Test func validationErrorIsNilForTypicalResponses() {
        let response = HTTPResponse(headers: fields([("Content-Type", "text/html"), ("X-Request-Id", "42")]))
        #expect(HTTP1Serializer<SystemWallClock>.validationError(response) == nil)
    }
}
