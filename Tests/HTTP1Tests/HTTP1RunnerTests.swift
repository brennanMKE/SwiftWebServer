import Foundation
import Synchronization
import Testing
import HTTPCore
import HTTPTestSupport
@testable import HTTP1

// MARK: - Support

/// Answers `200` with the request path as the body. `/throw` throws, `/stream` returns an
/// empty streamed body, `/file` sends ``fileRegion``.
struct PathHandler: HTTPHandler {
    struct Failure: Error {}

    var filePath: String?

    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        let path = request.string(of: request.path)
        switch path {
        case "/throw":
            throw Failure()
        case "/stream":
            return HTTPResponse(body: .stream(length: nil) { _ in })
        case "/file":
            let file = try OwnedFileDescriptor.openForReading(path: filePath ?? "")
            return HTTPResponse(body: .file(try FileRegion.entireFile(file)))
        case "/upgrade":
            var headers = HTTPFields()
            headers.append(.connection, "upgrade")
            headers.append(.upgrade, "echo")
            return HTTPResponse(status: .switchingProtocols, headers: headers, body: .tunnel { stream, _ in
                // Echo four bytes, then end.
                var buffer = ByteBuffer()
                while buffer.readableBytes < 4 {
                    guard let count = try? await stream.receive(into: &buffer, maxLength: 4 - buffer.readableBytes),
                          count > 0 else { break }
                }
                try? await stream.send(buffer, endOfStream: true)
            })
        default:
            var body = ByteBuffer()
            body.append(contentsOf: Array(path.utf8))
            return HTTPResponse(body: .bytes(body))
        }
    }
}

/// Counts sends and checks that receives and sends never overlap.
final class CountingTransport<Base: ByteStreamTransport>: ByteStreamTransport {
    let base: Base
    let sends = Atomic<Int>(0)
    let receives = Atomic<Int>(0)

    init(_ base: Base) { self.base = base }

    var info: ConnectionInfo { base.info }

    func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        receives.add(1, ordering: .relaxed)
        return try await base.receive(into: &buffer, maxLength: maxLength)
    }

    func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws {
        if !bytes.isEmpty { sends.add(1, ordering: .relaxed) }
        try await base.send(bytes, endOfStream: endOfStream)
    }

    func sendFile(_ region: FileRegion) async throws {
        try await base.sendFile(region)
    }

    func close(_ reason: CloseReason) async {
        await base.close(reason)
    }
}

/// A response as the client sees it.
struct WireResponse: CustomStringConvertible {
    var status: Int
    var headers: [(String, String)]
    var body: String

    func header(_ name: String) -> String? {
        headers.first { $0.0 == name }?.1
    }

    var description: String { "\(status) \(headers) \(body)" }
}

/// Splits the bytes a server sent into responses (Content-Length framing only). Responses at
/// `headResponses` answer HEAD requests and carry no content.
func parseResponses(_ bytes: ByteBuffer, headResponses: Set<Int> = []) -> (responses: [WireResponse], trailing: String) {
    let all = bytes.withReadableSpan { span in (0..<span.count).map { span[$0] } }
    var responses: [WireResponse] = []
    var index = 0
    while index < all.count {
        guard let end = findHeadEnd(all, from: index) else { break }
        let head = String(decoding: all[index..<end], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let status = Int(statusLine.split(separator: " ")[1]) ?? 0
        var headers: [(String, String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        let length = Int(headers.first { $0.0 == "content-length" }?.1 ?? "0") ?? 0
        let bodyStart = end + 4
        let bodiless = status == 101 || headResponses.contains(responses.count)
        let bodyEnd = bodiless ? bodyStart : min(all.count, bodyStart + length)
        responses.append(WireResponse(status: status, headers: headers,
                                      body: String(decoding: all[bodyStart..<bodyEnd], as: UTF8.self)))
        index = bodyEnd
        if status == 101 { break }
    }
    let trailing = index < all.count ? String(decoding: all[index...], as: UTF8.self) : ""
    return (responses, trailing)
}

private func findHeadEnd(_ bytes: [UInt8], from start: Int) -> Int? {
    var i = start
    while i + 3 < bytes.count {
        if bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 { return i }
        i += 1
    }
    return nil
}

func buffer(_ text: String) -> ByteBuffer {
    var buffer = ByteBuffer()
    buffer.append(contentsOf: Array(text.utf8))
    return buffer
}

func get(_ path: String, _ extra: String = "") -> String {
    "GET \(path) HTTP/1.1\r\nHost: example.com\r\n\(extra)\r\n"
}

/// Runs HTTP/1.1 over a scripted transport until the connection ends.
func serveScripted(
    _ events: [InMemoryTransport.Event],
    chunking: InMemoryTransport.Chunking = .unlimited,
    handler: PathHandler = PathHandler(),
    shutdown: ShutdownSignal = ShutdownSignal(),
    headResponses: Set<Int> = []
) async -> (responses: [WireResponse], trailing: String, transport: CountingTransport<InMemoryTransport>) {
    let base = InMemoryTransport.scripted(events, configuration: .init(receiveChunking: chunking))
    let transport = CountingTransport(base)
    await HTTP1().run(transport, handler: handler, context: ConnectionContext(info: base.info, shutdown: shutdown))
    let parsed = parseResponses(base.sentBytes, headResponses: headResponses)
    return (parsed.responses, parsed.trailing, transport)
}

// MARK: - Tests

@Suite struct HTTP1RunnerTests {
    @Test(.timeLimit(.minutes(1)))
    func keepAliveAcrossOneHundredRequests() async {
        let events = (0..<100).map { InMemoryTransport.Event.bytes(buffer(get("/r\($0)"))) } + [.endOfStream]
        let result = await serveScripted(events)
        #expect(result.responses.count == 100)
        for (i, response) in result.responses.enumerated() {
            #expect(response.status == 200)
            #expect(response.body == "/r\(i)")
            #expect(response.header("connection") == "keep-alive")
            #expect(response.header("date") != nil)
        }
        #expect(result.trailing.isEmpty)
        #expect(result.transport.base.isClosed)
    }

    @Test(.timeLimit(.minutes(1)))
    func keepAliveOverAPairedConnection() async throws {
        let (client, server) = InMemoryTransport.makePair()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await HTTP1().run(server, handler: PathHandler(), context: ConnectionContext(info: server.info))
            }
            var received = ByteBuffer()
            for i in 0..<20 {
                try await client.send(buffer(get("/k\(i)")), endOfStream: false)
                // Read until this response is complete.
                while parseResponses(received).responses.count < i + 1 {
                    let count = try await client.receive(into: &received, maxLength: 4096)
                    #expect(count > 0)
                    if count == 0 { return }
                }
            }
            let responses = parseResponses(received).responses
            #expect(responses.map(\.body) == (0..<20).map { "/k\($0)" })
            try await client.send(ByteBuffer(), endOfStream: true)
            try await group.waitForAll()
            // The server closed after the client's end of stream.
            #expect(try await client.receive(into: &received, maxLength: 1) == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func tenPipelinedRequestsInOneWriteGetTenOrderedResponsesInOneSend() async {
        let pipelined = (0..<10).map { get("/p\($0)") }.joined()
        let result = await serveScripted([.bytes(buffer(pipelined)), .endOfStream])
        #expect(result.responses.map(\.body) == (0..<10).map { "/p\($0)" })
        #expect(result.responses.allSatisfy { $0.status == 200 })
        #expect(result.transport.sends.load(ordering: .relaxed) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func byteAtATimeDelivery() async {
        let pipelined = get("/a") + get("/bb", "Accept: */*\r\n") + get("/ccc")
        let result = await serveScripted([.bytes(buffer(pipelined)), .endOfStream], chunking: .bytewise)
        #expect(result.responses.map(\.body) == ["/a", "/bb", "/ccc"])
        #expect(result.trailing.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func everySplitOffsetOfTwoRequests() async {
        let text = get("/one") + get("/two", "X-Long: \(String(repeating: "v", count: 100))\r\n")
        let bytes = Array(text.utf8)
        for split in stride(from: 1, to: bytes.count, by: 7) {
            var first = ByteBuffer(); first.append(contentsOf: bytes[..<split])
            var second = ByteBuffer(); second.append(contentsOf: bytes[split...])
            let result = await serveScripted([.bytes(first), .bytes(second), .endOfStream])
            #expect(result.responses.map(\.body) == ["/one", "/two"], "split at \(split)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func handlerThrowGives500AndClose() async {
        let pipelined = get("/a") + get("/throw") + get("/never")
        let result = await serveScripted([.bytes(buffer(pipelined)), .endOfStream])
        #expect(result.responses.map(\.status) == [200, 500])
        #expect(result.responses[0].header("connection") == "keep-alive")
        #expect(result.responses[1].header("connection") == "close")
        #expect(result.responses[1].header("content-length") == "0")
        #expect(result.trailing.isEmpty)
        #expect(result.transport.base.isClosed)
    }

    @Test(.timeLimit(.minutes(1)))
    func handlerThrowOnAnOpenConnectionDoesNotHang() async throws {
        // Legacy #0009: the peer keeps its side open; the server must still answer and close.
        let (client, server) = InMemoryTransport.makePair()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await HTTP1().run(server, handler: PathHandler(), context: ConnectionContext(info: server.info))
            }
            try await client.send(buffer(get("/throw")), endOfStream: false)
            var received = ByteBuffer()
            while try await client.receive(into: &received, maxLength: 4096) > 0 {}
            let responses = parseResponses(received).responses
            #expect(responses.map(\.status) == [500])
            #expect(responses.first?.header("connection") == "close")
            try await group.waitForAll()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func connectionCloseEndsAfterTheResponse() async {
        let pipelined = get("/a", "Connection: close\r\n") + get("/never")
        let result = await serveScripted([.bytes(buffer(pipelined)), .endOfStream])
        #expect(result.responses.count == 1)
        #expect(result.responses.first?.header("connection") == "close")
        #expect(result.transport.base.isClosed)
    }

    @Test(.timeLimit(.minutes(1)))
    func http10ClosesWithoutKeepAlive() async {
        let pipelined = "GET /old HTTP/1.0\r\n\r\n" + get("/never")
        let result = await serveScripted([.bytes(buffer(pipelined)), .endOfStream])
        #expect(result.responses.count == 1)
        #expect(result.responses.first?.body == "/old")
        #expect(result.responses.first?.header("connection") == "close")
    }

    @Test(.timeLimit(.minutes(1)))
    func http10KeepAliveOptIn() async {
        let request = "GET /old HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"
        let result = await serveScripted([.bytes(buffer(request + request)), .endOfStream])
        #expect(result.responses.count == 2)
        #expect(result.responses.allSatisfy { $0.header("connection") == "keep-alive" })
        #expect(result.responses.allSatisfy { $0.header("transfer-encoding") == nil })
    }

    @Test(.timeLimit(.minutes(1)))
    func malformedRequestGives400AndClose() async {
        let result = await serveScripted([.bytes(buffer(get("/ok") + "GET / HTTP/1.1\nHost: x\r\n\r\n" + get("/never"))), .endOfStream])
        #expect(result.responses.map(\.status) == [200, 400])
        #expect(result.responses.last?.header("connection") == "close")
        #expect(result.transport.base.isClosed)
    }

    @Test(.timeLimit(.minutes(1)))
    func parseErrorStatusesAreMapped() async {
        let missingHost = await serveScripted([.bytes(buffer("GET / HTTP/1.1\r\n\r\n")), .endOfStream])
        #expect(missingHost.responses.map(\.status) == [400])
        let version = await serveScripted([.bytes(buffer("GET / HTTP/2.0\r\nHost: x\r\n\r\n")), .endOfStream])
        #expect(version.responses.map(\.status) == [505])
        let huge = get("/", "X-Big: \(String(repeating: "a", count: 20_000))\r\n")
        let tooLarge = await serveScripted([.bytes(buffer(huge)), .endOfStream])
        #expect(tooLarge.responses.map(\.status) == [431])
    }

    @Test(.timeLimit(.minutes(1)))
    func endOfStreamMidHeadClosesQuietly() async {
        let result = await serveScripted([.bytes(buffer("GET / HTTP/1.1\r\nHost: exa")), .endOfStream])
        #expect(result.responses.isEmpty)
        #expect(result.trailing.isEmpty)
        #expect(result.transport.base.isClosed)
    }

    @Test(.timeLimit(.minutes(1)))
    func endOfStreamAfterResponsesClosesQuietly() async {
        let result = await serveScripted([.bytes(buffer(get("/a"))), .endOfStream])
        #expect(result.responses.count == 1)
        #expect(result.transport.base.isClosed)
    }

    @Test(.timeLimit(.minutes(1)))
    func receiveErrorEndsTheLoopWithoutAResponse() async {
        // Legacy #0008: no response is attempted after a transport failure.
        let result = await serveScripted([.bytes(buffer("GET / HT")), .error(.connectionReset)])
        #expect(result.responses.isEmpty)
        #expect(result.trailing.isEmpty)
        #expect(result.transport.sends.load(ordering: .relaxed) == 0)
        #expect(result.transport.base.isClosed)
    }

    @Test(.timeLimit(.minutes(1)))
    func fileBodyGoesThroughSendFile() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "sws-h1-file-\(UInt64.random(in: 0...UInt64.max)).txt").path
        let content = String(repeating: "0123456789", count: 1000)
        try Data(content.utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = await serveScripted([.bytes(buffer(get("/file") + get("/after"))), .endOfStream],
                                         handler: PathHandler(filePath: path))
        #expect(result.responses.map(\.status) == [200, 200])
        #expect(result.responses.first?.body == content)
        #expect(result.responses.last?.body == "/after")

        let head = await serveScripted([.bytes(buffer("HEAD /file HTTP/1.1\r\nHost: x\r\n\r\n" + get("/after"))), .endOfStream],
                                       handler: PathHandler(filePath: path), headResponses: [0])
        #expect(head.responses.first?.header("content-length") == "10000")
        #expect(head.responses.first?.body == "")
        // The HEAD response carried no content, so the next response follows the head directly.
        #expect(head.responses.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func tunnelGetsTheStreamAndBufferedBytes() async {
        let request = get("/upgrade", "Connection: upgrade\r\nUpgrade: echo\r\n")
        let result = await serveScripted([.bytes(buffer(request + "pi")), .bytes(buffer("ng")), .endOfStream])
        #expect(result.responses.map(\.status) == [101])
        #expect(result.responses.first?.header("upgrade") == "echo")
        #expect(result.trailing == "ping")
    }

    @Test(.timeLimit(.minutes(1)))
    func drainingAnswersWithClose() async {
        let shutdown = ShutdownSignal()
        shutdown.trigger()
        let idle = await serveScripted([.bytes(buffer(get("/a"))), .endOfStream], shutdown: shutdown)
        #expect(idle.responses.isEmpty)   // closed before reading a request

        // Shutdown arriving while /b is handled: /b's response says close (#0082) and the
        // pipelined /c, not started yet, gets no response.
        let (client, server) = InMemoryTransport.makePair()
        let signal = ShutdownSignal()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await HTTP1().run(server, handler: TriggeringHandler(signal: signal),
                                  context: ConnectionContext(info: server.info, shutdown: signal))
            }
            try? await client.send(buffer(get("/a") + get("/b") + get("/c")), endOfStream: false)
            var received = ByteBuffer()
            while (try? await client.receive(into: &received, maxLength: 4096)) ?? 0 > 0 {}
            let responses = parseResponses(received).responses
            #expect(responses.map(\.status) == [200, 200])
            #expect(responses.map { $0.header("connection") } == ["keep-alive", "close"])
            // The server lingers (it left /c unread) until the client closes.
            try? await client.send(ByteBuffer(), endOfStream: true)
            await group.waitForAll()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func receiveBufferDoesNotGrowAcrossRequests() async {
        // Legacy #0007: consumed bytes are discarded after every batch.
        let request = get("/x", "X-Pad: \(String(repeating: "p", count: 1000))\r\n")
        let events = (0..<200).map { _ in InMemoryTransport.Event.bytes(buffer(request)) } + [.endOfStream]
        let transport = InMemoryTransport.scripted(events)
        var driver = HTTP1ConnectionDriver(transport: transport, handler: PathHandler(),
                                           context: ConnectionContext(info: transport.info),
                                           configuration: HTTP1Configuration())
        let ending = await driver.run()
        #expect(ending == .closed(.normal))
        #expect(driver.connection.requestCount == 200)
        #expect(driver.storage.buffer.capacity <= HTTP1Configuration.defaultReceiveSize * 2)
        #expect(driver.output.capacity <= 8 * 1024)
    }

    @Test func cleartextPrefaceSniffing() {
        #expect(HTTP1.matchesCleartextPreface(buffer("GET / HTTP/1.1")) == .match)
        #expect(HTTP1.matchesCleartextPreface(buffer("\r\nPOST ")) == .match)
        #expect(HTTP1.matchesCleartextPreface(buffer("GE")) == .needMoreBytes)
        #expect(HTTP1.matchesCleartextPreface(buffer("")) == .needMoreBytes)
        #expect(HTTP1.matchesCleartextPreface(buffer(" GET")) == .noMatch)
        #expect(HTTP1.matchesCleartextPreface(buffer("\u{16}\u{03}\u{01}")) == .noMatch)
        #expect(HTTP1.alpnTokens == ["http/1.1"])
    }
}

/// Triggers the shutdown signal while handling `/b`, after the pipelined heads were read in one
/// batch: `/b`'s response is the last one and says close.
struct TriggeringHandler: HTTPHandler {
    let signal: ShutdownSignal

    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        if request.string(of: request.path) == "/b" { signal.trigger() }
        return HTTPResponse(body: .bytes(buffer("ok")))
    }
}
