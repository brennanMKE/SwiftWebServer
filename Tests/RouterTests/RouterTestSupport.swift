import HTTPCore
@testable import Router

/// A request built the way a connection builds one: target bytes in the request storage,
/// after some leading bytes so that views have a non-zero offset.
struct TestRequest {
    let storage: HTTPRequestStorage
    let request: HTTPRequest

    init(_ method: HTTPMethod = .get, _ target: String) {
        storage = HTTPRequestStorage(bufferCapacity: 512, fieldCapacity: 4)
        storage.buffer.append(contentsOf: Array("GARBAGE ".utf8))
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathStart = storage.buffer.writerIndex
        storage.buffer.append(contentsOf: Array(parts[0].utf8))
        let path = ByteView(offset: pathStart, length: storage.buffer.writerIndex - pathStart)
        var query = ByteView.empty
        if parts.count > 1 {
            let start = storage.buffer.writerIndex
            storage.buffer.append(contentsOf: Array(parts[1].utf8))
            query = ByteView(offset: start, length: storage.buffer.writerIndex - start)
        }
        request = HTTPRequest(method: method, path: path, query: query, headers: storage.fieldsView)
    }
}

/// A handler answering with `status`, for dispatch tests.
func respond(_ code: Int) -> RouteHandler {
    { _, _ in HTTPResponse(status: HTTPStatus(code: code)) }
}

/// A route answering `200`, for match tests.
let ok: RouteHandler = { _, _ in HTTPResponse(status: .ok) }

/// The next handler of a router used as a middleware: answers `299`.
struct FallThrough: HTTPHandler {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        HTTPResponse(status: HTTPStatus(code: 299))
    }
}

/// Outcome of matching, flattened for `#expect`.
enum MatchResult: Equatable {
    case route(String, [String: String])
    case methodNotAllowed(String)
    case notFound
}

extension Router {
    /// Matches `target` with `method` and returns the outcome with decoded parameters.
    func resolve(_ target: String) -> MatchResult { resolve(.get, target) }

    func resolve(_ method: HTTPMethod, _ target: String) -> MatchResult {
        let test = TestRequest(method, target)
        switch match(test.request) {
        case .route(let route):
            var values: [String: String] = [:]
            for name in route.parameters.names { values[name] = route.parameters[name] }
            return .route(route.pattern, values)
        case .methodNotAllowed(let response):
            return .methodNotAllowed(response.headers.firstValueString(for: .allow) ?? "")
        case .notFound:
            return .notFound
        }
    }

    /// Dispatches `target` as a middleware in front of ``FallThrough`` and returns the status.
    func status(_ method: HTTPMethod, _ target: String) async throws -> Int {
        let test = TestRequest(method, target)
        let response = try await handle(test.request, context: RequestContext(), next: FallThrough())
        return Int(response.status.code)
    }
}
