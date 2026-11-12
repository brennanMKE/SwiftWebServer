import AccessLog
import HTTPCore
import Synchronization

/// A request built the way a connection builds one: target and fields in one storage. The
/// path is raw bytes so tests can send what a hostile client would.
struct TestRequest {
    let storage: HTTPRequestStorage
    let request: HTTPRequest

    init(_ method: HTTPMethod = .get, path: [UInt8], query: [UInt8] = [], headers: [(String, [UInt8])] = []) {
        let storage = HTTPRequestStorage(bufferCapacity: 1024, fieldCapacity: 8)
        self.storage = storage
        func add(_ bytes: [UInt8]) -> ByteView {
            let start = storage.buffer.writerIndex
            storage.buffer.append(contentsOf: bytes)
            return ByteView(offset: start, length: bytes.count)
        }
        let pathView = add(path)
        let queryView = query.isEmpty ? ByteView.empty : add(query)
        for (name, value) in headers {
            let nameView = add(Array(name.utf8))
            let valueView = add(value)
            let hash = storage.buffer.withSpan(of: nameView) { ASCII.fnv1aLowercased($0) }
            storage.appendField(nameView: nameView, hash: hash, valueView: valueView)
        }
        request = HTTPRequest(method: method, path: pathView, query: queryView, headers: storage.fieldsView)
    }

    init(_ target: String, headers: [(String, String)] = []) {
        self.init(.get, target, headers: headers)
    }

    init(_ method: HTTPMethod, _ target: String, headers: [(String, String)] = []) {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        self.init(method, path: Array(parts[0].utf8), query: parts.count > 1 ? Array(parts[1].utf8) : [],
                  headers: headers.map { ($0.0, Array($0.1.utf8)) })
    }
}

/// Answers with a fixed status and body; throws for `/throw`.
struct Responder: HTTPHandler {
    var status: HTTPStatus = .ok
    var body = "Hello, World!\n"

    struct Failure: Error {}

    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        if request.string(of: request.path) == "/throw" { throw Failure() }
        let status = request.string(of: request.path) == "/missing" ? HTTPStatus.notFound : self.status
        return HTTPResponse(status: status, body: .bytes(ByteBuffer(bytes: body.utf8)))
    }
}

/// Collects the batches a `.handler` destination receives.
final class Capture: Sendable {
    let batches = Mutex<[[UInt8]]>([])

    var destination: AccessLogDestination {
        .handler { batch in
            let bytes = batch.withUnsafeReadableBytes { Array($0) }
            self.batches.withLock { $0.append(bytes) }
        }
    }

    var bytes: [UInt8] { batches.withLock { $0.flatMap { $0 } } }

    /// The received lines, without their newlines.
    var lines: [String] {
        let text = String(decoding: bytes, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

let peer = ConnectionInfo(remoteAddress: TransportAddress(host: "192.0.2.7", port: 50_000))

/// A connection's context with the log's per-connection state, as the server sets it up.
func openConnection(_ log: AccessLog, info: ConnectionInfo = peer, startTime: Bool = true) -> ConnectionContext {
    var context = ConnectionContext(info: info, recordsRequestStartTime: startTime)
    log.connectionWillStart(&context)
    return context
}

/// Sends `request` through `log` on `connection`, stamping the start time like a runner.
@discardableResult
func perform(_ request: TestRequest, through log: AccessLog, on connection: ConnectionContext,
          to handler: some HTTPHandler = Responder()) async throws -> HTTPResponse {
    var context = connection.requestContext
    if connection.recordsRequestStartTime { context.startTime = .now() }
    return try await log.handle(request.request, context: context, next: handler)
}

/// Runs the log's writer and stops it at once: it writes everything queued and buffered.
func drain(_ log: AccessLog) async throws {
    let handle = ServerHandle(localAddresses: [], draining: ShutdownSignal()) {}
    try await withThrowingTaskGroup { group in
        group.addTask { try await log.run(server: handle) }
        group.cancelAll()
        try await group.waitForAll()
    }
}
