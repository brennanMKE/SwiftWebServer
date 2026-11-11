import Foundation
import Synchronization
import Testing
import HTTPCore
import HTTPTestSupport
@testable import HTTP1

// MARK: - Support

/// A response as the client sees it, with chunked and close-delimited bodies decoded.
struct ParsedResponse: CustomStringConvertible {
    var status: Int
    var headers: [(String, String)]
    var body: [UInt8]
    var trailers: [(String, String)] = []

    func header(_ name: String) -> String? { headers.first { $0.0 == name }?.1 }
    var text: String { String(decoding: body, as: UTF8.self) }
    /// Headers without `date`, for comparing two responses.
    var stableHeaders: [String] { headers.filter { $0.0 != "date" }.map { "\($0.0): \($0.1)" } }
    var description: String { "\(status) \(headers) \(text)" }
}

/// Splits the bytes a server sent into responses. `headResponses` holds the indices (among
/// final, non-1xx responses) that answer HEAD requests. Returns the bytes that did not form a
/// complete response.
func parseWire(_ bytes: ByteBuffer, headResponses: Set<Int> = []) -> (responses: [ParsedResponse], rest: [UInt8]) {
    let all = bytes.withReadableSpan { span in (0..<span.count).map { span[$0] } }
    var responses: [ParsedResponse] = []
    var finals = 0
    var index = 0
    func line(from start: Int) -> (String, Int)? {
        var i = start
        while i + 1 < all.count {
            if all[i] == 13 && all[i + 1] == 10 { return (String(decoding: all[start..<i], as: UTF8.self), i + 2) }
            i += 1
        }
        return nil
    }
    while index < all.count {
        guard let (statusLine, afterStatus) = line(from: index) else { break }
        let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
        var headers: [(String, String)] = []
        var cursor = afterStatus
        var complete = false
        while let (text, next) = line(from: cursor) {
            cursor = next
            if text.isEmpty { complete = true; break }
            guard let colon = text.firstIndex(of: ":") else { continue }
            headers.append((text[..<colon].lowercased(), text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        guard complete else { break }
        var response = ParsedResponse(status: status, headers: headers, body: [])
        let bodiless = status < 200 || status == 204 || status == 304 || headResponses.contains(finals)
        if status >= 200 { finals += 1 }
        if bodiless {
            index = cursor
        } else if response.header("transfer-encoding") == "chunked" {
            var ok = false
            while let (sizeLine, next) = line(from: cursor) {
                let size = Int(sizeLine.split(separator: ";").first ?? "", radix: 16) ?? -1
                guard size >= 0 else { break }
                cursor = next
                if size == 0 {
                    while let (text, next) = line(from: cursor) {
                        cursor = next
                        if text.isEmpty { ok = true; break }
                        if let colon = text.firstIndex(of: ":") {
                            response.trailers.append((text[..<colon].lowercased(), text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
                        }
                    }
                    break
                }
                guard cursor + size + 2 <= all.count else { break }
                response.body += all[cursor..<(cursor + size)]
                cursor += size + 2
            }
            guard ok else { break }
            index = cursor
        } else if let length = response.header("content-length").flatMap({ Int($0) }) {
            guard cursor + length <= all.count else { break }
            response.body = Array(all[cursor..<(cursor + length)])
            index = cursor + length
        } else {
            // Close-delimited.
            response.body = Array(all[cursor...])
            index = all.count
        }
        responses.append(response)
    }
    return (responses, index < all.count ? Array(all[index...]) : [])
}

/// Counts handler calls and stream-writer runs.
final class BodyCounters: Sendable {
    let calls = Atomic<Int>(0)
    let writerRuns = Atomic<Int>(0)
    let escaped = Mutex<HTTPRequestBody?>(nil)
}

/// Handlers for request and response bodies. Paths:
///
/// - `/echo`: reads the whole body and answers with it; `x-chunks` and `x-max-chunk` describe
///   the chunks, `x-trailer-<name>` the trailers.
/// - `/length`: reads the whole body and answers with its length.
/// - `/first`: reads one chunk only.
/// - `/ignore`: does not read the body.
/// - `/collect`: `collect(upTo: 10)`.
/// - `/escape`: keeps the body past the handler.
/// - `/stream`, `/stream-length`, `/stream-short`, `/stream-long`, `/stream-throw`,
///   `/stream-big`: streamed responses.
/// - `/kind/<empty|bytes|file|stream|streamlen>/<status>`: that body kind with that status.
/// - anything else: the path.
struct BodyHandler: HTTPHandler {
    var filePath: String = ""
    var counters = BodyCounters()
    var bigStreamSize = 1 << 20

    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        counters.calls.add(1, ordering: .relaxed)
        let path = request.string(of: request.path)
        switch path {
        case "/echo":
            var body = ByteBuffer()
            var chunks = 0
            var maxChunk = 0
            for try await chunk in request.body {
                body.append(chunk)
                chunks += 1
                maxChunk = max(maxChunk, chunk.readableBytes)
            }
            var headers = HTTPFields()
            headers.append(name: "x-chunks", value: "\(chunks)")
            headers.append(name: "x-max-chunk", value: "\(maxChunk)")
            if let trailers = request.body.trailers {
                for i in 0..<trailers.count {
                    headers.append(name: "x-trailer-\(trailers.nameString(at: i).lowercased())", value: trailers.valueString(at: i))
                }
            }
            return HTTPResponse(headers: headers, body: .bytes(body))
        case "/length":
            var length = 0
            for try await chunk in request.body { length += chunk.readableBytes }
            return HTTPResponse(body: .bytes(buffer("\(length)")))
        case "/first":
            var iterator = request.body.makeAsyncIterator()
            let first = try await iterator.next()
            return HTTPResponse(body: .bytes(buffer("first \(first?.readableBytes ?? 0)")))
        case "/ignore":
            return HTTPResponse(body: .bytes(buffer("ignored")))
        case "/collect":
            return HTTPResponse(body: .bytes(try await request.body.collect(upTo: 10)))
        case "/escape":
            counters.escaped.withLock { $0 = request.body }
            return HTTPResponse(body: .bytes(buffer("escaped")))
        case "/stream":
            return HTTPResponse(body: .stream(length: nil) { [counters] writer in
                counters.writerRuns.add(1, ordering: .relaxed)
                for piece in ["hello", ", ", "world"] { try await writer.write(buffer(piece)) }
            })
        case "/stream-length":
            return HTTPResponse(body: .stream(length: 12) { writer in
                try await writer.write(buffer("hello, "))
                try await writer.write(ByteBuffer())   // empty writes are no-ops
                try await writer.write(buffer("world"))
            })
        case "/stream-short":
            return HTTPResponse(body: .stream(length: 20) { writer in try await writer.write(buffer("hello")) })
        case "/stream-long":
            return HTTPResponse(body: .stream(length: 3) { writer in try await writer.write(buffer("hello")) })
        case "/stream-throw":
            return HTTPResponse(body: .stream(length: nil) { writer in
                try await writer.write(buffer("partial"))
                throw CancellationError()
            })
        case "/stream-big":
            let size = bigStreamSize
            return HTTPResponse(body: .stream(length: nil) { writer in
                var piece = ByteBuffer()
                piece.append(contentsOf: repeatElement(UInt8(ascii: "z"), count: 16 * 1024))
                var sent = 0
                while sent < size {
                    try await writer.write(piece)
                    sent += piece.readableBytes
                }
            })
        default:
            if path.hasPrefix("/kind/") { return try kindResponse(path) }
            return HTTPResponse(body: .bytes(buffer(path)))
        }
    }

    func kindResponse(_ path: String) throws -> HTTPResponse {
        let parts = path.split(separator: "/")
        let status = HTTPStatus(code: Int(parts[2]) ?? 200)
        let content = "0123456789abcdef"
        let body: HTTPResponseBody
        switch parts[1] {
        case "empty":
            body = .empty
        case "bytes":
            body = .bytes(buffer(content))
        case "file":
            body = .file(try FileRegion.entireFile(try OwnedFileDescriptor.openForReading(path: filePath)))
        case "stream":
            body = .stream(length: nil) { [counters] writer in
                counters.writerRuns.add(1, ordering: .relaxed)
                try await writer.write(buffer(content))
            }
        default:
            body = .stream(length: content.utf8.count) { [counters] writer in
                counters.writerRuns.add(1, ordering: .relaxed)
                try await writer.write(buffer(content))
            }
        }
        return HTTPResponse(status: status, body: body)
    }
}

func post(_ path: String, _ body: String, _ extra: String = "") -> String {
    "POST \(path) HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.utf8.count)\r\n\(extra)\r\n\(body)"
}

func postChunked(_ path: String, _ chunked: String, _ extra: String = "") -> String {
    "POST \(path) HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\(extra)\r\n\(chunked)"
}

/// Runs HTTP/1.1 over a scripted transport until the connection ends.
func serveBodies(
    _ events: [InMemoryTransport.Event],
    chunking: InMemoryTransport.Chunking = .unlimited,
    configuration: HTTP1Configuration = HTTP1Configuration(receiveSize: 64),
    handler: BodyHandler = BodyHandler(),
    headResponses: Set<Int> = []
) async -> (responses: [ParsedResponse], rest: [UInt8], transport: InMemoryTransport) {
    let transport = InMemoryTransport.scripted(events, configuration: .init(receiveChunking: chunking))
    await HTTP1(configuration: configuration).run(transport, handler: handler, context: ConnectionContext(info: transport.info))
    let parsed = parseWire(transport.sentBytes, headResponses: headResponses)
    return (parsed.responses, parsed.rest, transport)
}

func serveBodies(_ text: String, chunking: InMemoryTransport.Chunking = .unlimited,
                 configuration: HTTP1Configuration = HTTP1Configuration(receiveSize: 64),
                 handler: BodyHandler = BodyHandler(), headResponses: Set<Int> = []
) async -> (responses: [ParsedResponse], rest: [UInt8], transport: InMemoryTransport) {
    await serveBodies([.bytes(buffer(text)), .endOfStream], chunking: chunking, configuration: configuration,
                      handler: handler, headResponses: headResponses)
}

func pattern(_ count: Int) -> String {
    String((0..<count).map { Character(UnicodeScalar(UInt8(97 + $0 % 26))) })
}

// MARK: - Request bodies

@Suite struct HTTP1RequestBodyTests {
    @Test(.timeLimit(.minutes(1)))
    func contentLengthBodiesOfEverySizeAndChunking() async {
        // receiveSize 64: bodies below, at and above one receive.
        let chunkings: [InMemoryTransport.Chunking] = [.unlimited, .fixed(7), .pattern([3, 50, 1, 64, 65]), .bytewise]
        for size in [1, 2, 63, 64, 65, 129, 1000] {
            for chunking in chunkings {
                if case .fixed(1) = chunking, size > 200 { continue }
                let body = pattern(size)
                let result = await serveBodies(post("/echo", body) + get("/after"), chunking: chunking)
                #expect(result.responses.map(\.status) == [200, 200], "size \(size) \(chunking)")
                #expect(result.responses.first?.text == body, "size \(size) \(chunking)")
                #expect(Int(result.responses.first?.header("x-max-chunk") ?? "") ?? .max <= 64, "chunks bounded by receiveSize")
                #expect(result.responses.first?.header("connection") == "keep-alive")
                #expect(result.responses.last?.text == "/after", "size \(size) \(chunking)")
                #expect(result.rest.isEmpty)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func contentLengthBodySplitAtEveryOffset() async {
        let text = post("/echo", pattern(100)) + get("/after")
        let bytes = Array(text.utf8)
        for split in 1..<bytes.count {
            var first = ByteBuffer(); first.append(contentsOf: bytes[..<split])
            var second = ByteBuffer(); second.append(contentsOf: bytes[split...])
            let result = await serveBodies([.bytes(first), .bytes(second), .endOfStream])
            #expect(result.responses.map(\.text) == [pattern(100), "/after"], "split at \(split)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func emptyBodiesCostNothing() async {
        let result = await serveBodies(post("/echo", "") + get("/after"))
        #expect(result.responses.map(\.text) == ["", "/after"])
        #expect(result.responses.first?.header("x-chunks") == "0")
    }

    @Test(.timeLimit(.minutes(1)))
    func chunkedBodyWithExtensionsAndTrailersAtEverySplit() async {
        let chunked = "5;name=value\r\nhello\r\n1 ; x=\"y;z\"\r\n,\r\n6\r\n world\r\n0;end\r\nChecksum: abc\r\nX-Note: two words \r\n\r\n"
        let text = postChunked("/echo", chunked) + get("/after")
        let whole = await serveBodies(text)
        #expect(whole.responses.map(\.status) == [200, 200])
        #expect(whole.responses.first?.text == "hello, world")
        #expect(whole.responses.first?.header("x-trailer-checksum") == "abc")
        #expect(whole.responses.first?.header("x-trailer-x-note") == "two words")
        #expect(whole.responses.first?.header("connection") == "keep-alive")
        #expect(whole.responses.last?.text == "/after")

        let bytes = Array(text.utf8)
        for split in 1..<bytes.count {
            var first = ByteBuffer(); first.append(contentsOf: bytes[..<split])
            var second = ByteBuffer(); second.append(contentsOf: bytes[split...])
            let result = await serveBodies([.bytes(first), .bytes(second), .endOfStream])
            #expect(result.responses.map(\.text) == ["hello, world", "/after"], "split at \(split)")
            #expect(result.responses.first?.header("x-trailer-checksum") == "abc", "split at \(split)")
        }
        let bytewise = await serveBodies(text, chunking: .bytewise)
        #expect(bytewise.responses.map(\.text) == ["hello, world", "/after"])
    }

    @Test(.timeLimit(.minutes(1)))
    func largeChunkedBodyStreamsInBoundedChunks() async {
        // 40 chunks of 100 bytes with receiveSize 64, pipelined with a GET.
        let chunked = (0..<40).map { _ in "64\r\n" + pattern(100) + "\r\n" }.joined() + "0\r\n\r\n"
        for chunking in [InMemoryTransport.Chunking.unlimited, .fixed(13)] {
            let result = await serveBodies(postChunked("/echo", chunked) + get("/after"), chunking: chunking)
            #expect(result.responses.first?.body.count == 4000)
            #expect(Int(result.responses.first?.header("x-max-chunk") ?? "") ?? .max <= 64)
            #expect(result.responses.last?.text == "/after")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func malformedChunkedIs400AndClose() async {
        for chunked in [
            "z\r\nhello\r\n0\r\n\r\n",                 // bad hex
            "FFFFFFFFFFFFFFFFFF\r\n",                   // oversized chunk
            "5\r\nhelloX\r\n0\r\n\r\n",                 // missing CRLF after data
            "5\nhello\r\n0\r\n\r\n",                    // bare LF
        ] {
            let result = await serveBodies(postChunked("/echo", chunked) + get("/never"))
            #expect(result.responses.map(\.status) == [400], "\(chunked.debugDescription)")
            #expect(result.responses.first?.header("connection") == "close")
            #expect(result.transport.isClosed)
        }
        // A handler that ignores the body: the malformed rest is not drained, the connection closes.
        let ignored = await serveBodies(postChunked("/ignore", "zz\r\n") + get("/never"))
        #expect(ignored.responses.map(\.text) == ["ignored"])
        #expect(ignored.responses.first?.header("connection") == "close")
    }

    @Test(.timeLimit(.minutes(1)))
    func truncatedBodyIs400AndClose() async {
        let result = await serveBodies("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nhello")
        #expect(result.responses.map(\.status) == [400])
        #expect(result.responses.first?.header("connection") == "close")
    }

    @Test(.timeLimit(.minutes(1)))
    func bodyOverTheLimitIs413AndClose() async {
        let configuration = HTTP1Configuration(receiveSize: 64, maxBodySize: 100)
        let counters = BodyCounters()
        let declared = await serveBodies(post("/echo", pattern(101)) + get("/never"), configuration: configuration,
                                         handler: BodyHandler(counters: counters))
        #expect(declared.responses.map(\.status) == [413])
        #expect(declared.responses.first?.header("connection") == "close")
        #expect(counters.calls.load(ordering: .relaxed) == 0, "the handler never runs")
        #expect(declared.transport.isClosed)

        let atLimit = await serveBodies(post("/echo", pattern(100)), configuration: configuration)
        #expect(atLimit.responses.map(\.status) == [200])

        let chunked = "3c\r\n" + pattern(60) + "\r\n3c\r\n" + pattern(60) + "\r\n0\r\n\r\n"
        let streamed = await serveBodies(postChunked("/echo", chunked) + get("/never"), configuration: configuration)
        #expect(streamed.responses.map(\.status) == [413])
        #expect(streamed.responses.first?.header("connection") == "close")

        // A handler's own limit (collect(upTo:)) also maps to 413.
        let collected = await serveBodies(post("/collect", pattern(20)))
        #expect(collected.responses.map(\.status) == [413])
        let small = await serveBodies(post("/collect", "tiny") + get("/after"))
        #expect(small.responses.map(\.text) == ["tiny", "/after"])
    }

    @Test(.timeLimit(.minutes(1)))
    func unreadBodyIsDrainedThenKeepAlive() async {
        let contentLength = await serveBodies(post("/ignore", pattern(1000)) + get("/after"), chunking: .fixed(50))
        #expect(contentLength.responses.map(\.text) == ["ignored", "/after"])
        #expect(contentLength.responses.first?.header("connection") == "keep-alive")

        let partial = await serveBodies(post("/first", pattern(1000)) + get("/after"), chunking: .fixed(50))
        #expect(partial.responses.count == 2)
        let firstSize = Int(partial.responses.first?.text.dropFirst("first ".count) ?? "") ?? 0
        #expect(firstSize > 0 && firstSize <= 64, "\(partial.responses)")
        #expect(partial.responses.last?.text == "/after")

        let chunked = "3e8\r\n" + pattern(1000) + "\r\n0\r\nX: y\r\n\r\n"
        let chunkedResult = await serveBodies(postChunked("/ignore", chunked) + get("/after"))
        #expect(chunkedResult.responses.map(\.text) == ["ignored", "/after"])
        #expect(chunkedResult.responses.first?.header("connection") == "keep-alive")
    }

    @Test(.timeLimit(.minutes(1)))
    func unreadBodyOverTheDrainLimitCloses() async {
        let configuration = HTTP1Configuration(receiveSize: 64, maxDrainSize: 100)
        let contentLength = await serveBodies(post("/ignore", pattern(1000)) + get("/never"), configuration: configuration)
        #expect(contentLength.responses.map(\.text) == ["ignored"])
        #expect(contentLength.responses.first?.header("connection") == "close")
        #expect(contentLength.transport.isClosed)

        let chunked = "3e8\r\n" + pattern(1000) + "\r\n0\r\n\r\n"
        let chunkedResult = await serveBodies(postChunked("/ignore", chunked) + get("/never"), configuration: configuration)
        #expect(chunkedResult.responses.map(\.text) == ["ignored"])
        #expect(chunkedResult.responses.first?.header("connection") == "close")
    }

    @Test(.timeLimit(.minutes(1)))
    func bodyExpiresWhenTheHandlerReturns() async throws {
        let counters = BodyCounters()
        _ = await serveBodies(post("/escape", "hello"), handler: BodyHandler(counters: counters))
        let body = try #require(counters.escaped.withLock { $0 })
        await #expect(throws: HTTPRequestBodyError.expired) {
            var iterator = body.makeAsyncIterator()
            _ = try await iterator.next()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func largeBodyKeepsMemoryFlat() async {
        // 4 MiB through /length: the receive buffer and the chunk stay at one receive.
        let piece = pattern(64 * 1024)
        let head = "POST /length HTTP/1.1\r\nHost: x\r\nContent-Length: \(64 * 64 * 1024)\r\n\r\n"
        let events = [InMemoryTransport.Event.bytes(buffer(head))]
            + (0..<64).map { _ in InMemoryTransport.Event.bytes(buffer(piece)) } + [.endOfStream]
        let transport = InMemoryTransport.scripted(events)
        var driver = HTTP1ConnectionDriver(transport: transport, handler: BodyHandler(),
                                           context: ConnectionContext(info: transport.info),
                                           configuration: HTTP1Configuration())
        _ = await driver.run()
        #expect(parseWire(transport.sentBytes).responses.map(\.text) == ["\(64 * 64 * 1024)"])
        #expect(driver.storage.buffer.capacity <= HTTP1Configuration.defaultReceiveSize * 2)
        #expect((driver.bodyReader?.chunk.capacity ?? 0) <= HTTP1Configuration.defaultReceiveSize * 2)
        #expect((driver.bodyReader?.raw.capacity ?? 0) == 0)
    }
}

// MARK: - Expect: 100-continue

@Suite struct HTTP1ExpectContinueTests {
    static let expectHead = "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n"
    static let continueLine = "HTTP/1.1 100 Continue\r\n\r\n"

    @Test(.timeLimit(.minutes(1)))
    func continueIsSentWhenTheHandlerReads() async throws {
        let (client, server) = InMemoryTransport.makePair()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await HTTP1().run(server, handler: BodyHandler(), context: ConnectionContext(info: server.info))
            }
            try await client.send(buffer(Self.expectHead), endOfStream: false)
            var received = ByteBuffer()
            // The client waits for 100 before sending the body.
            while received.readableBytes < Self.continueLine.utf8.count {
                #expect(try await client.receive(into: &received, maxLength: 4096) > 0)
            }
            #expect(String(decoding: received.withReadableSpan { s in (0..<s.count).map { s[$0] } }, as: UTF8.self) == Self.continueLine)
            try await client.send(buffer("hello" + get("/after")), endOfStream: true)
            while try await client.receive(into: &received, maxLength: 4096) > 0 {}
            let responses = parseWire(received).responses
            #expect(responses.map(\.status) == [100, 200, 200])
            #expect(responses[1].text == "hello")
            #expect(responses[1].header("connection") == "keep-alive")
            #expect(responses[2].text == "/after")
            try await group.waitForAll()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func handlerThatDoesNotReadGetsNoContinueAndClose() async throws {
        let (client, server) = InMemoryTransport.makePair()
        let counters = BodyCounters()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await HTTP1().run(server, handler: BodyHandler(counters: counters), context: ConnectionContext(info: server.info))
            }
            let head = Self.expectHead.replacingOccurrences(of: "/echo", with: "/ignore")
            try await client.send(buffer(head), endOfStream: false)
            var received = ByteBuffer()
            // The client never sends the body; the server answers and closes anyway.
            while try await client.receive(into: &received, maxLength: 4096) > 0 {}
            let responses = parseWire(received).responses
            #expect(responses.map(\.status) == [200])
            #expect(responses.first?.text == "ignored")
            #expect(responses.first?.header("connection") == "close")
            try await group.waitForAll()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func earlierPipelinedResponsesGoFirstAndBufferedBodiesSkip100() async {
        // The body arrives later: /a's response is flushed, then 100, then the echo.
        let late = await serveBodies([.bytes(buffer(get("/a") + Self.expectHead)), .bytes(buffer("hello")), .endOfStream])
        #expect(late.responses.map(\.status) == [200, 100, 200])
        #expect(late.responses.map(\.text) == ["/a", "", "hello"])

        // The client did not wait: the body is already buffered, so no 100.
        let eager = await serveBodies(Self.expectHead + "hello")
        #expect(eager.responses.map(\.status) == [200])
        #expect(eager.responses.first?.text == "hello")
    }

    @Test(.timeLimit(.minutes(1)))
    func unknownExpectationIs417() async {
        let result = await serveBodies("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: x-magic\r\n\r\nhello")
        #expect(result.responses.map(\.status) == [417])
        #expect(result.responses.first?.header("connection") == "close")
    }

    @Test(.timeLimit(.minutes(1)))
    func http10IgnoresTheExpectation() async {
        let request = "POST /echo HTTP/1.0\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n"
        let result = await serveBodies([.bytes(buffer(request)), .bytes(buffer("hello")), .endOfStream])
        #expect(result.responses.map(\.status) == [200])
        #expect(result.responses.first?.text == "hello")
    }
}

// MARK: - Streamed responses and body rules

@Suite struct HTTP1ResponseBodyTests {
    @Test(.timeLimit(.minutes(1)))
    func streamWithoutLengthIsChunked() async {
        let result = await serveBodies(get("/stream") + get("/after"))
        #expect(result.responses.map(\.status) == [200, 200])
        #expect(result.responses.first?.header("transfer-encoding") == "chunked")
        #expect(result.responses.first?.header("content-length") == nil)
        #expect(result.responses.first?.header("connection") == "keep-alive")
        #expect(result.responses.first?.text == "hello, world")
        #expect(result.responses.last?.text == "/after")
        #expect(result.rest.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func streamWithLengthUsesContentLength() async {
        let result = await serveBodies(get("/stream-length") + get("/after"))
        #expect(result.responses.first?.header("content-length") == "12")
        #expect(result.responses.first?.header("transfer-encoding") == nil)
        #expect(result.responses.map(\.text) == ["hello, world", "/after"])
    }

    @Test(.timeLimit(.minutes(1)))
    func http10StreamIsCloseDelimited() async {
        let result = await serveBodies("GET /stream HTTP/1.0\r\nConnection: keep-alive\r\n\r\n" + get("/never"))
        #expect(result.responses.count == 1)
        let response = result.responses.first
        #expect(response?.header("transfer-encoding") == nil)
        #expect(response?.header("content-length") == nil)
        #expect(response?.header("connection") == "close")
        #expect(response?.text == "hello, world")
        #expect(result.transport.isClosed)
    }

    @Test(.timeLimit(.minutes(1)))
    func lengthMismatchOrWriterErrorAborts() async {
        for path in ["/stream-short", "/stream-long", "/stream-throw"] {
            let result = await serveBodies(get(path) + get("/never"))
            let sent = String(decoding: result.transport.sentBytes.withReadableSpan { s in (0..<s.count).map { s[$0] } }, as: UTF8.self)
            #expect(result.transport.isClosed, "\(path)")
            #expect(!sent.contains("/never"), "\(path)")
            #expect(!sent.hasSuffix("0\r\n\r\n"), "\(path): an aborted chunked body has no last chunk")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func streamHasBackpressure() async throws {
        // A 1 MiB stream through a pipe that holds about 8 KiB: the writer is paced by the reader.
        let clientConfig = InMemoryTransport.Configuration(bufferCapacity: 4 * 1024, segmentSize: 2 * 1024)
        let (client, server) = InMemoryTransport.makePair(client: clientConfig)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await HTTP1().run(server, handler: BodyHandler(), context: ConnectionContext(info: server.info))
            }
            try await client.send(buffer(get("/stream-big", "Connection: close\r\n")), endOfStream: false)
            var received = ByteBuffer()
            var total = 0
            while true {
                received.clear()
                let count = try await client.receive(into: &received, maxLength: 1024)
                if count == 0 { break }
                total += count
            }
            #expect(total > 1 << 20)
            #expect(client.inboundHighWaterMark <= clientConfig.bufferBound)
            try await group.waitForAll()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func headHasGetHeadersAndNoBodyForEveryKind() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "sws-h1-head-\(UInt64.random(in: 0...UInt64.max)).txt").path
        try Data("0123456789abcdef".utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        for kind in ["empty", "bytes", "file", "stream", "streamlen"] {
            let counters = BodyCounters()
            let handler = BodyHandler(filePath: path, counters: counters)
            let target = "/kind/\(kind)/200"
            let getResult = await serveBodies(get(target), handler: handler)
            let headResult = await serveBodies("HEAD \(target) HTTP/1.1\r\nHost: x\r\n\r\n" + get("/after"),
                                               handler: handler, headResponses: [0])
            let getResponse = try #require(getResult.responses.first)
            let headResponse = try #require(headResult.responses.first)
            #expect(headResponse.body.isEmpty, "\(kind)")
            #expect(headResult.responses.last?.text == "/after", "\(kind): the HEAD response carried body bytes")
            switch kind {
            case "empty", "stream":
                // No length known without producing the body: no framing on HEAD (RFC 9110 §9.3.2).
                #expect(headResponse.header("content-length") == nil, "\(kind)")
                #expect(headResponse.header("transfer-encoding") == nil, "\(kind)")
            default:
                #expect(headResponse.stableHeaders == getResponse.stableHeaders, "\(kind)")
                #expect(headResponse.header("content-length") == "16", "\(kind)")
            }
            // The stream writer runs for GET only.
            if kind.hasPrefix("stream") { #expect(counters.writerRuns.load(ordering: .relaxed) == 1, "\(kind)") }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func noContentAndNotModifiedNeverCarryABody() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "sws-h1-304-\(UInt64.random(in: 0...UInt64.max)).txt").path
        try Data("0123456789abcdef".utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        for status in [204, 304] {
            for kind in ["empty", "bytes", "file", "stream", "streamlen"] {
                let counters = BodyCounters()
                let result = await serveBodies(get("/kind/\(kind)/\(status)") + get("/after"),
                                               handler: BodyHandler(filePath: path, counters: counters))
                #expect(result.responses.map(\.status) == [status, 200], "\(status) \(kind)")
                #expect(result.responses.first?.body.isEmpty == true, "\(status) \(kind)")
                #expect(result.responses.first?.header("transfer-encoding") == nil, "\(status) \(kind)")
                #expect(result.responses.last?.text == "/after", "\(status) \(kind)")
                #expect(counters.writerRuns.load(ordering: .relaxed) == 0, "\(status) \(kind)")
                if status == 204 { #expect(result.responses.first?.header("content-length") == nil, "\(kind)") }
            }
        }
    }
}
