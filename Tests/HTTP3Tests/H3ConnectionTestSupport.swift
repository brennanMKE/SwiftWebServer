import HeaderCompression
import HTTP3
import HTTPCore
import HTTPTestSupport
import QPACK
import Synchronization
import Testing

// An in-memory HTTP/3 client for driving `HTTP3` over `InMemoryMultiplexedTransport` (#0099).

typealias MuxStream = InMemoryMultiplexedTransport.Stream

/// Runs `HTTP3` on the server side of an in-memory pair while `body` drives the client side.
/// Afterwards the client closes the connection (if still open) and the server is awaited.
func withH3Server<H: HTTPHandler, R: Sendable>(
    handler: H,
    configuration: H3Configuration = H3Configuration(),
    shutdown: ShutdownSignal = ShutdownSignal(),
    serverTransport: InMemoryMultiplexedTransport.Configuration = InMemoryMultiplexedTransport.Configuration(),
    tracker: H3ConnectionTracker = H3ConnectionTracker(),
    _ body: (InMemoryMultiplexedTransport, InMemoryMultiplexedTransport) async throws -> R
) async throws -> R {
    let (client, server) = InMemoryMultiplexedTransport.makePair(server: serverTransport)
    return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            await HTTP3(configuration: configuration, tracker: tracker).run(
                server, handler: handler, context: ConnectionContext(info: server.info, shutdown: shutdown))
        }
        do {
            let result = try await body(client, server)
            await client.close(applicationError: HTTP3Error.noError.rawValue)
            try await group.waitForAll()
            return result
        } catch {
            await client.close(applicationError: HTTP3Error.noError.rawValue)
            try? await group.waitForAll()
            throw error
        }
    }
}

/// Waits until the connection is closed and returns the code the server closed it with.
func serverCloseCode(_ client: InMemoryMultiplexedTransport) async -> UInt64? {
    var iterator = client.inboundStreams.makeAsyncIterator()
    while (try? await iterator.next()) != nil {}
    return client.peerCloseApplicationError
}

// MARK: - Frames

enum H3Wire {
    static func frame(_ type: H3FrameType, _ payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        payload.withUnsafeBytes { try! H3FrameEncoder.encodeFrame(type: type, payload: $0, into: &bytes) }
        return bytes
    }

    static func settings(_ settings: H3Settings = H3Settings(qpackMaxTableCapacity: 0, qpackBlockedStreams: 0)) -> [UInt8] {
        var bytes: [UInt8] = []
        try! H3FrameEncoder.encodeSettings(settings, into: &bytes)
        return bytes
    }

    /// A SETTINGS frame with a raw payload (for duplicate or HTTP/2 identifiers).
    static func rawSettings(_ pairs: [(UInt64, UInt64)]) -> [UInt8] {
        var payload: [UInt8] = []
        for (id, value) in pairs {
            try! QUICVarint.encode(id, into: &payload)
            try! QUICVarint.encode(value, into: &payload)
        }
        return frame(.settings, payload)
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        try! QUICVarint.encode(value, into: &bytes)
        return bytes
    }

    /// A QPACK field section (static table and literals) for `fields`, in order.
    static func fieldSection(_ fields: [(String, String)]) -> [UInt8] {
        var section: [UInt8] = []
        QPACKEncoder().encode(fields.map { (Array($0.0.utf8), Array($0.1.utf8)) }, into: &section)
        return section
    }

    static func headers(_ fields: [(String, String)]) -> [UInt8] {
        frame(.headers, fieldSection(fields))
    }

    static func data(_ bytes: [UInt8]) -> [UInt8] {
        frame(.data, bytes)
    }

    static func request(
        method: String = "GET", path: String = "/", authority: String = "localhost",
        extra: [(String, String)] = []
    ) -> [(String, String)] {
        [(":method", method), (":scheme", "https"), (":authority", authority), (":path", path)] + extra
    }
}

// MARK: - Client

/// The client half of a test connection.
struct H3TestClient {
    let transport: InMemoryMultiplexedTransport

    /// Opens the client control stream and sends `bytes` (default: type 0x00 + SETTINGS).
    @discardableResult
    func openControlStream(_ bytes: [UInt8] = [0x00] + H3Wire.settings()) async throws -> MuxStream {
        let stream = try await transport.openUnidirectionalStream()
        try await stream.send(ByteBuffer(bytes: bytes), endOfStream: false)
        return stream
    }

    /// Opens a unidirectional stream that starts with `bytes`.
    @discardableResult
    func openUniStream(_ bytes: [UInt8], fin: Bool = false) async throws -> MuxStream {
        let stream = try await transport.openUnidirectionalStream()
        try await stream.send(ByteBuffer(bytes: bytes), endOfStream: fin)
        return stream
    }

    /// Opens a request stream and sends `bytes`, with FIN when `fin`.
    func openRequest(_ bytes: [UInt8], fin: Bool = true) async throws -> MuxStream {
        let stream = try await transport.openBidirectionalStream()
        try await stream.send(ByteBuffer(bytes: bytes), endOfStream: fin)
        return stream
    }

    /// Sends a request and reads the whole response.
    func send(
        _ fields: [(String, String)] = H3Wire.request(), body: [UInt8]? = nil
    ) async throws -> H3TestResponse {
        var bytes = H3Wire.headers(fields)
        if let body { bytes += H3Wire.data(body) }
        let stream = try await transport.openBidirectionalStream()
        do {
            try await stream.send(ByteBuffer(bytes: bytes), endOfStream: true)
        } catch TransportError.connectionReset {
            // The stream reaches the server when it is opened, so the server can refuse it
            // (RESET_STREAM + STOP_SENDING, e.g. after GOAWAY) before this send runs. The send
            // then fails; the response read below reports the server's reset code.
        }
        return await H3TestResponse.read(stream)
    }
}

/// A response as the client saw it.
struct H3TestResponse: Sendable {
    var headers: [(name: String, value: String)] = []
    var body: [UInt8] = []
    var dataFrames = 0
    /// True when the stream ended with FIN.
    var finished = false
    /// The server's RESET_STREAM code, if the stream was reset.
    var resetCode: UInt64?
    /// A parse error in what the server sent.
    var frameError: HTTP3Error?

    var status: String? { headers.first { $0.name == ":status" }?.value }
    var bodyString: String { String(decoding: body, as: UTF8.self) }

    func header(_ name: String) -> String? { headers.first { $0.name == name }?.value }

    /// Reads `stream` until FIN or reset and parses the frames.
    static func read(_ stream: MuxStream) async -> H3TestResponse {
        var response = H3TestResponse()
        var buffer = ByteBuffer()
        do {
            while try await stream.receive(into: &buffer, maxLength: 64 * 1024) > 0 {}
            response.finished = true
        } catch {
            response.resetCode = stream.receivedResetCode
        }
        var parser = H3FrameParser(configuration: .init(streamKind: .request, role: .client))
        var bytes: [UInt8] = []
        buffer.withReadableSpan { span in for i in span.indices { bytes.append(span[i]) } }
        do {
            try bytes.withUnsafeBytes { input in
                var offset = 0
                while offset < input.count {
                    let rest = UnsafeRawBufferPointer(rebasing: input[offset...])
                    let output = try parser.parse(rest)
                    switch output.event {
                    case .headers(let location):
                        var decoder = QPACKDecoder(maxFieldSectionSize: 1 << 20)
                        var sink = CollectingSink()
                        parser.withPayload(location, in: rest) { section in
                            _ = try? decoder.decode(section, into: &sink)
                        }
                        response.headers += sink.fields
                    case .dataHeader:
                        response.dataFrames += 1
                    case .data(let range):
                        response.body += rest[range]
                    default:
                        break
                    }
                    offset += output.consumed
                }
            }
        } catch {
            response.frameError = error as? HTTP3Error
        }
        return response
    }
}

struct CollectingSink: QPACKFieldSink {
    var fields: [(name: String, value: String)] = []

    mutating func field(name: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer, neverIndexed: Bool) {
        fields.append((String(decoding: name, as: UTF8.self), String(decoding: value, as: UTF8.self)))
    }
}

/// Reads everything from a stream until FIN (or failure).
func receiveAll(_ stream: MuxStream) async -> [UInt8] {
    var buffer = ByteBuffer()
    _ = try? await { () async throws -> Void in
        while try await stream.receive(into: &buffer, maxLength: 64 * 1024) > 0 {}
    }()
    var bytes: [UInt8] = []
    buffer.withReadableSpan { span in for i in span.indices { bytes.append(span[i]) } }
    return bytes
}

/// Reads at least `count` bytes from a stream that stays open.
func receive(_ count: Int, from stream: MuxStream) async throws -> [UInt8] {
    var buffer = ByteBuffer()
    while buffer.readableBytes < count {
        guard try await stream.receive(into: &buffer, maxLength: 64 * 1024) > 0 else { break }
    }
    var bytes: [UInt8] = []
    buffer.withReadableSpan { span in for i in span.indices { bytes.append(span[i]) } }
    return bytes
}

// MARK: - Handlers

/// Answers `200 text/plain` with "hello <path>".
struct PathHandler: HTTPHandler {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        var headers = HTTPFields()
        headers.append(.contentType, "text/plain")
        var body = ByteBuffer("hello ")
        body.append(contentsOf: Array(request.string(of: request.path).utf8))
        if !request.query.isEmpty {
            body.append(UInt8(ascii: "?"))
            body.append(contentsOf: Array(request.string(of: request.query).utf8))
        }
        return HTTPResponse(status: .ok, headers: headers, body: .bytes(body))
    }
}

/// Echoes the request body.
struct EchoHandler: HTTPHandler {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        HTTPResponse(status: .ok, body: .bytes(try await request.body.collect(upTo: 1 << 24)))
    }
}

/// A handler whose behaviour is a closure.
struct ClosureHandler: HTTPHandler {
    let body: @Sendable (HTTPRequest) async throws -> HTTPResponse

    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        try await body(request)
    }
}

/// A one-shot flag tests can wait on.
final class Flag: Sendable {
    private let signal = ShutdownSignal()
    func set() { signal.trigger() }
    var isSet: Bool { signal.isTriggered }
    func wait() async { await signal.wait() }
}

struct TestError: Error {}
