import HTTPCore
import Synchronization
import Testing

// #0083: the middleware result builder, RequestContext values and component discovery.

/// Records what the chain did, in order.
private final class Trace: Sendable {
    let events = Mutex<[String]>([])
    func add(_ event: String) { events.withLock { $0.append(event) } }
    var all: [String] { events.withLock { $0 } }
}

private struct Boom: Error, Equatable {
    let where_: String
}

/// Logs `name>` on the way in and `<name` on the way out, and adds a response header.
private struct Recorder: HTTPMiddleware {
    let name: String
    let trace: Trace

    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse {
        trace.add("\(name)>")
        do {
            var response = try await next.handle(request, context: context)
            trace.add("<\(name)")
            response.headers.append(.via, string: name)
            return response
        } catch {
            trace.add("!\(name)")
            throw error
        }
    }
}

/// Answers without calling `next`.
private struct Deny: HTTPMiddleware {
    let trace: Trace
    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse {
        trace.add("deny")
        return HTTPResponse(status: .forbidden)
    }
}

/// Maps any error from the rest of the chain to `500`.
private struct Recover: HTTPMiddleware {
    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse {
        do {
            return try await next.handle(request, context: context)
        } catch {
            return HTTPResponse(status: .internalServerError)
        }
    }
}

private struct Throwing: HTTPMiddleware {
    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse {
        throw Boom(where_: "middleware")
    }
}

private struct Terminal: HTTPHandler {
    let trace: Trace
    var status: HTTPStatus = .ok
    var fails = false
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        trace.add("handler")
        if fails { throw Boom(where_: "handler") }
        return HTTPResponse(status: status)
    }
}

private enum Principal: RequestContextKey {
    static var defaultValue: String? { nil }
}

private enum Hops: RequestContextKey {
    static var defaultValue: Int { 0 }
}

private struct SetPrincipal: HTTPMiddleware {
    let name: String
    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse {
        var context = context
        context[Principal.self] = name
        context[Hops.self] += 1
        return try await next.handle(request, context: context)
    }
}

/// Echoes the context back in headers.
private struct ContextEcho: HTTPHandler {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        var response = HTTPResponse()
        response.headers.append(.server, string: context[Principal.self] ?? "anonymous")
        response.headers.append(.age, decimal: context[Hops.self])
        return response
    }
}

/// A middleware with a background job.
private struct Flusher: HTTPMiddleware, ServerComponent {
    let name: String
    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse {
        try await next.handle(request, context: context)
    }
    func run(server: ServerHandle) async throws {}
}

private func makeRequest(_ storage: HTTPRequestStorage) -> HTTPRequest {
    let pathStart = storage.buffer.writerIndex
    storage.buffer.append("/index.html")
    FieldScanner.fill(storage, with: "Host: example.com")
    return HTTPRequest(method: .get,
                       path: ByteView(offset: pathStart, length: 11),
                       headers: storage.fieldsView)
}

private func send<H: HTTPHandler>(_ handler: H, context: RequestContext = RequestContext()) async throws -> HTTPResponse {
    let storage = HTTPRequestStorage(bufferCapacity: 256, fieldCapacity: 8)
    let request = makeRequest(storage)
    defer { storage.endRequest() }
    return try await handler.handle(request, context: context)
}

private func vias(_ response: HTTPResponse) -> [String] {
    response.headers.pairs.filter { $0.0 == "via" }.map(\.1)
}

@Suite struct MiddlewareBuilderTests {
    @Test func middlewaresRunInOnionOrder() async throws {
        let trace = Trace()
        let app = MiddlewareBuilder.build {
            Recorder(name: "a", trace: trace)
            Recorder(name: "b", trace: trace)
            Recorder(name: "c", trace: trace)
            Terminal(trace: trace)
        }
        let response = try await send(app)
        #expect(response.status == .ok)
        #expect(trace.all == ["a>", "b>", "c>", "handler", "<c", "<b", "<a"])
        // The innermost middleware sees the response first.
        #expect(vias(response) == ["c", "b", "a"])
    }

    @Test func chainIsOneNestedGenericType() {
        let trace = Trace()
        let app = MiddlewareBuilder.build {
            Recorder(name: "a", trace: trace)
            Recorder(name: "b", trace: trace)
            Terminal(trace: trace)
        }
        let expected = CompiledChain<MiddlewareChain<Recorder, MiddlewareChain<Recorder, Terminal>>>.self
        #expect(type(of: app) == expected)
        let middlewaresOnly = MiddlewareBuilder.build {
            Recorder(name: "a", trace: trace)
            Recorder(name: "b", trace: trace)
            Recorder(name: "c", trace: trace)
        }
        typealias Composed = ComposedMiddleware<Recorder, ComposedMiddleware<Recorder, Recorder>>
        #expect(type(of: middlewaresOnly) == CompiledChain<MiddlewareChain<Composed, NotFoundHandler>>.self)
    }

    @Test func middlewareCanShortCircuit() async throws {
        let trace = Trace()
        let app = MiddlewareBuilder.build {
            Recorder(name: "a", trace: trace)
            Deny(trace: trace)
            Recorder(name: "c", trace: trace)
            Terminal(trace: trace)
        }
        let response = try await send(app)
        #expect(response.status == .forbidden)
        #expect(trace.all == ["a>", "deny", "<a"])
        #expect(vias(response) == ["a"])
    }

    @Test func handlerErrorsPropagateOutward() async throws {
        let trace = Trace()
        let app = MiddlewareBuilder.build {
            Recorder(name: "a", trace: trace)
            Recorder(name: "b", trace: trace)
            Terminal(trace: trace, fails: true)
        }
        await #expect(throws: Boom(where_: "handler")) { try await send(app) }
        #expect(trace.all == ["a>", "b>", "handler", "!b", "!a"])
    }

    @Test func middlewareErrorsPropagateAndCanBeRecovered() async throws {
        let trace = Trace()
        let failing = MiddlewareBuilder.build {
            Recorder(name: "a", trace: trace)
            Throwing()
            Terminal(trace: trace)
        }
        await #expect(throws: Boom(where_: "middleware")) { try await send(failing) }
        #expect(trace.all == ["a>", "!a"])

        let recovered = MiddlewareBuilder.build {
            Recover()
            Recorder(name: "b", trace: trace)
            Terminal(trace: trace, fails: true)
        }
        #expect(try await send(recovered).status == .internalServerError)
    }

    @Test func disabledConditionalComponentIsNotCalled() async throws {
        let trace = Trace()
        let compression = false
        let app = MiddlewareBuilder.build {
            Recorder(name: "a", trace: trace)
            if compression { Recorder(name: "compression", trace: trace) }
            Terminal(trace: trace)
        }
        _ = try await send(app)
        #expect(trace.all == ["a>", "handler", "<a"])
        #expect(type(of: app) == CompiledChain<MiddlewareChain<Recorder, MiddlewareChain<OptionalMiddleware<Recorder>, Terminal>>>.self)
    }

    @Test func enabledConditionalComponentRunsInPlace() async throws {
        let trace = Trace()
        let compression = true
        let app = MiddlewareBuilder.build {
            Recorder(name: "a", trace: trace)
            if compression {
                Recorder(name: "x", trace: trace)
                Recorder(name: "y", trace: trace)
            }
            Recorder(name: "b", trace: trace)
            Terminal(trace: trace)
        }
        _ = try await send(app)
        #expect(trace.all == ["a>", "x>", "y>", "b>", "handler", "<b", "<y", "<x", "<a"])
    }

    @Test(arguments: [true, false])
    func ifElseChoosesOneBranch(useFirst: Bool) async throws {
        let trace = Trace()
        let app = MiddlewareBuilder.build {
            if useFirst {
                Recorder(name: "first", trace: trace)
            } else {
                Recorder(name: "second", trace: trace)
                Recorder(name: "second2", trace: trace)
            }
            if useFirst {
                Terminal(trace: trace, status: .ok)
            } else {
                Terminal(trace: trace, status: .accepted)
            }
        }
        let response = try await send(app)
        if useFirst {
            #expect(trace.all == ["first>", "handler", "<first"])
            #expect(response.status == .ok)
        } else {
            #expect(trace.all == ["second>", "second2>", "handler", "<second2", "<second"])
            #expect(response.status == .accepted)
        }
    }

    @Test func chainWithoutHandlerEndsInNotFound() async throws {
        let trace = Trace()
        let app = MiddlewareBuilder.build {
            Recorder(name: "a", trace: trace)
        }
        let response = try await send(app)
        #expect(response.status == .notFound)
        #expect(trace.all == ["a>", "<a"])

        let empty = MiddlewareBuilder.build {}
        #expect(try await send(empty).status == .notFound)

        let enabled = false
        let optionalHandler = MiddlewareBuilder.build {
            if enabled { Terminal(trace: trace) }
        }
        #expect(try await send(optionalHandler).status == .notFound)
    }

    @Test func singleHandlerIsItself() async throws {
        let trace = Trace()
        let app = MiddlewareBuilder.build { Terminal(trace: trace, status: .accepted) }
        #expect(type(of: app) == Terminal.self)   // not wrapped: the same as `handler: app`
        #expect(try await send(app).status == .accepted)
    }

    @Test func manyElementsCompose() async throws {
        let trace = Trace()
        let app = MiddlewareBuilder.build {
            Recorder(name: "1", trace: trace)
            Recorder(name: "2", trace: trace)
            Recorder(name: "3", trace: trace)
            Recorder(name: "4", trace: trace)
            Recorder(name: "5", trace: trace)
            Recorder(name: "6", trace: trace)
            Recorder(name: "7", trace: trace)
            Recorder(name: "8", trace: trace)
            Recorder(name: "9", trace: trace)
            Terminal(trace: trace)
        }
        let response = try await send(app)
        #expect(vias(response) == (1...9).reversed().map(String.init))

        // Longer chains group middlewares in `if true { … }` blocks.
        let grouped = MiddlewareBuilder.build {
            if true {
                Recorder(name: "1", trace: trace)
                Recorder(name: "2", trace: trace)
                Recorder(name: "3", trace: trace)
                Recorder(name: "4", trace: trace)
                Recorder(name: "5", trace: trace)
                Recorder(name: "6", trace: trace)
                Recorder(name: "7", trace: trace)
                Recorder(name: "8", trace: trace)
                Recorder(name: "9", trace: trace)
                Recorder(name: "10", trace: trace)
            }
            Recorder(name: "11", trace: trace)
            Recorder(name: "12", trace: trace)
            Terminal(trace: trace)
        }
        #expect(vias(try await send(grouped)) == (1...12).reversed().map(String.init))
    }

    @Test func timedComponentIsDetected() {
        struct Timed: HTTPMiddleware, RequestStartTimeConsumer {
            func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                           next: Next) async throws -> HTTPResponse {
                try await next.handle(request, context: context)
            }
        }
        let trace = Trace()
        let on = true
        let off = false
        let timed = MiddlewareBuilder.build {
            Recorder(name: "a", trace: trace)
            if on { Timed() }
            Terminal(trace: trace)
        }
        let untimed = MiddlewareBuilder.build {
            Recorder(name: "a", trace: trace)
            if off { Timed() }
            Terminal(trace: trace)
        }
        #expect(MiddlewareChainInspector.needsRequestStartTime(timed))
        #expect(!MiddlewareChainInspector.needsRequestStartTime(untimed))
    }

    // MARK: RequestContext

    @Test func contextValuesFlowDownstreamOnly() async throws {
        let trace = Trace()
        struct Inspect: HTTPMiddleware {
            let trace: Trace
            func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                           next: Next) async throws -> HTTPResponse {
                let response = try await next.handle(request, context: context)
                // Values set further in are not visible here.
                trace.add(context[Principal.self] ?? "none")
                return response
            }
        }
        let app = MiddlewareBuilder.build {
            Inspect(trace: trace)
            SetPrincipal(name: "alice")
            SetPrincipal(name: "bob")
            ContextEcho()
        }
        let response = try await send(app)
        #expect(response.headers.firstValueString(for: .server) == "bob")
        #expect(response.headers.firstValueString(for: .age) == "2")
        #expect(trace.all == ["none"])

        let anonymous = try await send(ContextEcho())
        #expect(anonymous.headers.firstValueString(for: .server) == "anonymous")
        #expect(anonymous.headers.firstValueString(for: .age) == "0")
    }

    @Test func contextIsAValue() {
        var a = RequestContext()
        #expect(!a.contains(Principal.self))
        a[Principal.self] = "alice"
        let b = a
        a[Principal.self] = "carol"
        a[Hops.self] = 3
        #expect(a[Principal.self] == "carol")
        #expect(a[Hops.self] == 3)
        #expect(b[Principal.self] == "alice")
        #expect(b[Hops.self] == 0)
        #expect(b.contains(Principal.self))
        #expect(!b.contains(Hops.self))
        a[Principal.self] = nil
        #expect(a.contains(Principal.self))
        #expect(a[Principal.self] == nil)
    }

    @Test func contextCarriesConnectionAndStartTime() async throws {
        let info = ConnectionInfo(remoteAddress: TransportAddress(host: "127.0.0.1", port: 5000),
                                  isSecure: true, negotiatedALPN: "h2")
        let before = MonotonicInstant.now()
        let after = MonotonicInstant.now()
        let context = RequestContext(connection: info)
        #expect(context.connection == info)
        #expect(context.startTime == nil)   // only recorded when a component asks
        #expect(before <= after)
        #expect(before.duration(to: after) >= .zero)
        #expect(after.duration(to: before) <= .zero)

        final class Capture: HTTPHandler {
            let seen = Mutex<RequestContext?>(nil)
            func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
                seen.withLock { $0 = context }
                return HTTPResponse()
            }
        }
        let capture = Capture()
        let start = MonotonicInstant(ticks: 42)
        _ = try await send(MiddlewareChain(middleware: PassthroughMiddleware(), next: capture),
                           context: RequestContext(connection: info, startTime: start))
        let seen = capture.seen.withLock { $0 }
        #expect(seen?.connection == info)
        #expect(seen?.startTime == start)
    }

    @Test func monotonicDurationsAreInNanoseconds() async throws {
        let start = MonotonicInstant.now()
        try await Task.sleep(for: .milliseconds(20))
        let elapsed = start.elapsed
        #expect(elapsed >= .milliseconds(15))
        #expect(elapsed < .seconds(10))
    }

    // MARK: Components

    @Test func serverComponentsAreFoundInTheChain() {
        let trace = Trace()
        let enabled = true
        let disabled = false
        let app = MiddlewareBuilder.build {
            Flusher(name: "log")
            Recorder(name: "a", trace: trace)
            if enabled { Flusher(name: "cache") }
            if disabled { Flusher(name: "off") }
            if disabled { Recorder(name: "b", trace: trace) } else { Flusher(name: "else") }
            Terminal(trace: trace)
        }
        let names = MiddlewareChainInspector.serverComponents(in: app).compactMap { ($0 as? Flusher)?.name }
        #expect(names == ["log", "cache", "else"])
        #expect(MiddlewareChainInspector.serverComponents(in: Terminal(trace: trace)).isEmpty)
        #expect(!MiddlewareChainInspector.needsRequestStartTime(app))
    }
}
