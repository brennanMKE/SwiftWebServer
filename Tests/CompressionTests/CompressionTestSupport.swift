import Compression
import Foundation
import HTTPCore
import Synchronization

/// A request built the way a connection builds one: target and fields in one storage.
struct TestRequest {
    let storage: HTTPRequestStorage
    let request: HTTPRequest

    init(_ method: HTTPMethod = .get, _ path: String = "/", headers: [(String, String)] = []) {
        let storage = HTTPRequestStorage(bufferCapacity: 1024, fieldCapacity: 8)
        self.storage = storage
        func add(_ bytes: [UInt8]) -> ByteView {
            let start = storage.buffer.writerIndex
            storage.buffer.append(contentsOf: bytes)
            return ByteView(offset: start, length: bytes.count)
        }
        let pathView = add(Array(path.utf8))
        for (name, value) in headers {
            let nameView = add(Array(name.utf8))
            let valueView = add(Array(value.utf8))
            let hash = storage.buffer.withSpan(of: nameView) { ASCII.fnv1aLowercased($0) }
            storage.appendField(nameView: nameView, hash: hash, valueView: valueView)
        }
        request = HTTPRequest(method: method, path: pathView, headers: storage.fieldsView)
    }
}

/// Answers every request with a copy of `response`.
struct Fixed: HTTPHandler {
    let response: HTTPResponse
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse { response }
}

/// Collects what a `.stream` body writes, optionally slowly.
final class CollectingWriter: HTTPBodyWriter, Sendable {
    struct State {
        var bytes: [UInt8] = []
        var writes: [Int] = []
    }

    let state = Mutex(State())
    let delay: Duration?

    init(delay: Duration? = nil) { self.delay = delay }

    func write(_ bytes: ByteBuffer) async throws {
        if let delay { try await Task.sleep(for: delay) }
        let copy = bytes.withUnsafeReadableBytes { Array($0) }
        state.withLock {
            $0.bytes += copy
            $0.writes.append(copy.count)
        }
    }

    var bytes: [UInt8] { state.withLock { $0.bytes } }
    var writes: [Int] { state.withLock { $0.writes } }
}

extension HTTPResponse {
    /// The first value of `name`, as a string.
    func header(_ name: HTTPFieldName) -> String? { headers.firstValueString(for: name) }

    /// Every value of `name`.
    func headerValues(_ name: HTTPFieldName) -> [String] {
        headers.values(for: name).map { headers.string(of: $0) }
    }

    /// The body bytes, running a stream or reading a file region.
    func bodyBytes(into writer: CollectingWriter = CollectingWriter()) async throws -> [UInt8] {
        switch body {
        case .empty, .tunnel: return []
        case .bytes(let buffer): return buffer.withUnsafeReadableBytes { Array($0) }
        case .stream(_, let produce):
            try await produce(writer)
            return writer.bytes
        case .file(let region):
            var bytes = [UInt8](repeating: 0, count: Int(region.length))
            let n = bytes.withUnsafeMutableBytes { pread(region.file.rawValue, $0.baseAddress, Int(region.length), off_t(region.offset)) }
            return Array(bytes[..<max(n, 0)])
        }
    }
}

/// Text that compresses like real markup: words from a small vocabulary in a fixed
/// pseudo-random order.
func sampleText(_ count: Int, seed: UInt64 = 42) -> [UInt8] {
    let words = ["<div class=\"item\">", "</div>", "<p>", "</p>", "server", "request", "response", "stream",
                 "compression", "the", "of", "and", "header", "body", "chunk", "\n", " ", "<span>", "</span>"]
    var state = seed
    var out: [UInt8] = []
    out.reserveCapacity(count)
    while out.count < count {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        out += Array(words[Int((state >> 33) % UInt64(words.count))].utf8)
        if state >> 60 == 0 {
            out += Array(String(state >> 40, radix: 16).utf8)     // some entropy
        }
    }
    return Array(out[..<count])
}

/// Bytes that do not compress.
func randomBytes(_ count: Int) -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
}

func response(_ body: [UInt8], type: String = "text/html; charset=utf-8", status: HTTPStatus = .ok,
              extra: [(String, String)] = []) -> HTTPResponse {
    var headers = HTTPFields()
    headers.append(name: "Content-Type", value: type)
    for (name, value) in extra { headers.append(name: name, value: value) }
    return HTTPResponse(status: status, headers: headers, body: .bytes(ByteBuffer(bytes: body)))
}

/// Runs `response` through `compression` for a request with `headers`.
func compress(_ response: HTTPResponse, _ method: HTTPMethod = .get, headers: [(String, String)],
              with compression: Compression = Compression()) async throws -> HTTPResponse {
    let request = TestRequest(method, "/", headers: headers)
    return try await compression.handle(request.request, context: RequestContext(), next: Fixed(response: response))
}
