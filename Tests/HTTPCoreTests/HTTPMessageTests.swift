import Testing
import HTTPCore

/// Builds a request the way a connection does: target bytes and fields in one storage.
private func makeRequest(_ storage: HTTPRequestStorage) -> HTTPRequest {
    let pathStart = storage.buffer.writerIndex
    storage.buffer.append("/index.html")
    let queryStart = storage.buffer.writerIndex
    storage.buffer.append("a=1")
    FieldScanner.fill(storage, with: "Host: example.com\r\nX-Trace: abc")
    return HTTPRequest(method: .get,
                       path: ByteView(offset: pathStart, length: queryStart - pathStart),
                       query: ByteView(offset: queryStart, length: 3),
                       headers: storage.fieldsView)
}

@Suite struct HTTPMessageTests {
    @Test func requestReadsBorrowedBytes() {
        let storage = HTTPRequestStorage(bufferCapacity: 256, fieldCapacity: 8)
        let request = makeRequest(storage)
        #expect(request.isValid)
        #expect(request.string(of: request.path) == "/index.html")
        #expect(request.string(of: request.query) == "a=1")
        #expect(request.scheme.isEmpty)
        #expect(request.headers.firstValueString(for: .host) == "example.com")
        #expect(request.body.isEmpty)
    }

    @Test func snapshotOutlivesTheRequest() {
        let storage = HTTPRequestStorage(bufferCapacity: 256, fieldCapacity: 8)
        let request = makeRequest(storage)
        let kept = request.snapshot()
        storage.endRequest()
        storage.buffer.clear()
        storage.buffer.append("garbage garbage garbage garbage garbage")
        #expect(!request.isValid)
        #expect(kept.isValid)
        #expect(kept.method == .get)
        #expect(kept.string(of: kept.path) == "/index.html")
        #expect(kept.string(of: kept.query) == "a=1")
        #expect(kept.headers.pairs.map(\.0) == ["host", "X-Trace"])
        #expect(kept.headers.pairs.map(\.1) == ["example.com", "abc"])
    }

    @Test func emptyBodyYieldsNothing() async throws {
        var iterator = HTTPRequestBody.empty.makeAsyncIterator()
        #expect(try await iterator.next() == nil)
    }

    @Test func responseDefaults() {
        var response = HTTPResponse()
        #expect(response.status == .ok)
        #expect(response.headers.isEmpty)
        #expect(response.body.knownLength == 0)
        response.headers.append(.contentType, "text/plain")
        response.body = .bytes(ByteBuffer("hello"))
        #expect(response.body.knownLength == 5)
        response.body = .stream(length: nil) { writer in try await writer.write(ByteBuffer("x")) }
        #expect(response.body.knownLength == nil)
        response.body = .tunnel { transport in await transport.close(.normal) }
        #expect(response.body.knownLength == nil)
    }

    @Test func handlerAndMiddlewareCompose() async throws {
        struct Echo: HTTPHandler {
            func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
                var response = HTTPResponse()
                if let host = request.headers.firstValue(for: .host) {
                    request.withSpan(of: host) { response.headers.append(.xForwardedHost, value: $0) }
                }
                return response
            }
        }
        struct AddServer: HTTPMiddleware {
            func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                           next: Next) async throws -> HTTPResponse {
                var response = try await next.handle(request, context: context)
                response.headers.append(.server, "sws")
                return response
            }
        }
        struct Chain<M: HTTPMiddleware, N: HTTPHandler>: HTTPHandler {
            let middleware: M
            let next: N
            func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
                try await middleware.handle(request, context: context, next: next)
            }
        }
        let storage = HTTPRequestStorage(bufferCapacity: 256, fieldCapacity: 8)
        let request = makeRequest(storage)
        let response = try await Chain(middleware: AddServer(), next: Echo()).handle(request, context: RequestContext())
        #expect(response.headers.pairs.map(\.0) == ["x-forwarded-host", "server"])
        #expect(response.headers.pairs.map(\.1) == ["example.com", "sws"])
    }

    #if DEBUG
    /// The debug generation check traps when a request is read after the handler returned.
    @Test func useAfterReturnTrapsInDebug() async {
        await #expect(processExitsWith: .failure) {
            let storage = HTTPRequestStorage(bufferCapacity: 64, fieldCapacity: 4)
            storage.buffer.append("/")
            let request = HTTPRequest(method: .get, path: ByteView(offset: 0, length: 1),
                                      headers: storage.fieldsView)
            storage.endRequest()   // the handler returned
            _ = request.headers.count
        }
    }
    #endif
}
