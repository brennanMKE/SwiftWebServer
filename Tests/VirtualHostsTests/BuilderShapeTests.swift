import AccessLog
import Auth
import Compression
import Foundation
import HTTP1
import HTTPCore
import HTTPServer
import NetworkTransport
import Router
import StaticFiles
import Testing
import VirtualHosts
import WebSockets

// #0126: `StaticFiles`, `Router` and `VirtualHosts` are both middlewares and handlers. As the
// last element of a `@MiddlewareBuilder` block they used to be ambiguous ("ambiguous use of
// 'buildBlock'"). This file compiling is the main test: it writes every documented chain shape
// in its natural form, with each of the three types last, alone, in the middle, and under
// `if`/`else`. The `#expect`s pin the types built, so the last element stays the terminal
// handler (no `NotFoundHandler` appended) and the chain stays one nested generic.

/// A middleware that only passes requests on.
struct Pass: HTTPMiddleware {
    func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                   next: Next) async throws -> HTTPResponse {
        try await next.handle(request, context: context)
    }
}

/// The three dual types, built once.
struct BuilderComponents {
    let files: StaticFiles
    let router: Router
    let sites: VirtualHosts

    init() throws {
        files = try StaticFiles(root: NSTemporaryDirectory())
        router = try Router {
            GET("/api/status") { _, _ in HTTPResponse(status: .ok) }
        }
        sites = try VirtualHosts {
            VirtualHost("a.test", handler: HTTPResponseHandler(.created))
            VirtualHost.default(handler: HTTPResponseHandler(.accepted))
        }
    }
}

/// Answers every request with `status`.
private struct HTTPResponseHandler: HTTPHandler {
    let status: HTTPStatus
    init(_ status: HTTPStatus) { self.status = status }
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        HTTPResponse(status: status)
    }
}

private func type<T>(_ value: T) -> String { String(describing: Swift.type(of: value)) }

/// The chain type a `Server` was built with.
private func handlerType<L, H>(_ server: Server<L, H>) -> H.Type { H.self }

@Suite struct BuilderShapeTests {
    let c: BuilderComponents

    init() throws { c = try BuilderComponents() }

    // MARK: Each dual type last, after middlewares

    @Test func staticFilesLast() {
        let one = MiddlewareBuilder.build { Pass(); c.files }
        #expect(Swift.type(of: one) == CompiledChain<MiddlewareChain<Pass, StaticFiles>>.self)
        let three = MiddlewareBuilder.build { Pass(); Pass(); Pass(); c.files }
        #expect(Swift.type(of: three) == CompiledChain<MiddlewareChain<Pass, MiddlewareChain<Pass, MiddlewareChain<Pass, StaticFiles>>>>.self)
    }

    @Test func routerLast() {
        let chain = MiddlewareBuilder.build { Pass(); c.router }
        #expect(Swift.type(of: chain) == CompiledChain<MiddlewareChain<Pass, Router>>.self)
    }

    @Test func virtualHostsLast() {
        let chain = MiddlewareBuilder.build { Pass(); c.sites }
        #expect(Swift.type(of: chain) == CompiledChain<MiddlewareChain<Pass, VirtualHosts>>.self)
    }

    @Test func dualTypesInTheMiddleAndLast() {
        // The custom-server example: every dual type but the last is a middleware.
        let chain = MiddlewareBuilder.build { Pass(); c.router; c.sites; c.files }
        #expect(Swift.type(of: chain) == CompiledChain<MiddlewareChain<Pass, MiddlewareChain<Router, MiddlewareChain<VirtualHosts, StaticFiles>>>>.self)
        let duals = MiddlewareBuilder.build { c.router; c.files }
        #expect(Swift.type(of: duals) == CompiledChain<MiddlewareChain<Router, StaticFiles>>.self)
    }

    @Test func tenElementsEndingInADualType() {
        let chain = MiddlewareBuilder.build {
            Pass(); Pass(); Pass(); Pass(); Pass(); Pass(); Pass(); Pass(); Pass()
            c.files
        }
        #expect(type(chain).hasSuffix("MiddlewareChain<Pass, StaticFiles>>>>>>>>>>"))
    }

    // MARK: Alone

    @Test func aloneIsTheHandlerItself() {
        let files = MiddlewareBuilder.build { c.files }
        let router = MiddlewareBuilder.build { c.router }
        let sites = MiddlewareBuilder.build { c.sites }
        #expect(Swift.type(of: files) == StaticFiles.self)
        #expect(Swift.type(of: router) == Router.self)
        #expect(Swift.type(of: sites) == VirtualHosts.self)
    }

    // MARK: A dual type that is not last stays a middleware

    @Test func dualTypeBeforeMiddlewaresOnlyEndsIn404() {
        let chain = MiddlewareBuilder.build { c.router; Pass() }
        #expect(Swift.type(of: chain) == CompiledChain<MiddlewareChain<ComposedMiddleware<Router, Pass>, NotFoundHandler>>.self)
    }

    // MARK: Conditionals

    @Test func optionalDualTypeLast() {
        let flag = Bool.random()
        let chain = MiddlewareBuilder.build {
            Pass()
            if flag { c.files }
        }
        #expect(Swift.type(of: chain) == CompiledChain<MiddlewareChain<Pass, OptionalMiddleware<StaticFiles>>>.self)
        let alone = MiddlewareBuilder.build { if flag { c.router } }
        #expect(Swift.type(of: alone) == OptionalMiddleware<Router>.self)
    }

    @Test func eitherDualTypesLastAndInTheMiddle() {
        let flag = Bool.random()
        let last = MiddlewareBuilder.build {
            Pass()
            if flag { c.router } else { c.sites }
        }
        #expect(Swift.type(of: last) == CompiledChain<MiddlewareChain<Pass, EitherHandler<Router, VirtualHosts>>>.self)
        let middle = MiddlewareBuilder.build {
            if flag { c.router } else { c.sites }
            c.files
        }
        #expect(Swift.type(of: middle) == CompiledChain<MiddlewareChain<EitherHandler<Router, VirtualHosts>, StaticFiles>>.self)
        let alone = MiddlewareBuilder.build { if flag { c.router } else { c.files } }
        #expect(Swift.type(of: alone) == CompiledChain<EitherHandler<Router, StaticFiles>>.self)
    }

    @Test func eitherMixingADualTypeAndAChain() {
        let flag = Bool.random()
        let chain = MiddlewareBuilder.build {
            if flag { Pass(); c.files } else { c.router }
        }
        #expect(Swift.type(of: chain) == CompiledChain<EitherHandler<MiddlewareChain<Pass, StaticFiles>, Router>>.self)
    }

    @Test(.timeLimit(.minutes(1))) func optionalDualTypeAnswers404WhenAbsent() async throws {
        let absent = MiddlewareBuilder.build { Pass(); if false { c.sites } }
        let test = HostRequest(host: "z.test")   // matches no name: the default host answers
        let request = test.request
        #expect(try await absent.handle(request, context: RequestContext()).status == .notFound)
        let present = MiddlewareBuilder.build { Pass(); if true { c.sites } }
        #expect(try await present.handle(request, context: RequestContext()).status == .accepted)
    }

    // MARK: The documented examples, as written

    @Test func serverDocExample() throws {
        // Sources/HTTPServer/Server.swift and docs/MIDDLEWARE.md.
        let compression = Bool.random()
        let server = Server(listeners: [BSDSocketListener](), protocols: [HTTP1()]) {
            AccessLog(destination: .standardError)
            if compression { Compression() }
            c.files
        }
        #expect(handlerType(server) == CompiledChain<MiddlewareChain<AccessLog, MiddlewareChain<OptionalMiddleware<Compression>, StaticFiles>>>.self)
    }

    @Test func authenticatorDocExample() throws {
        // Sources/Auth/Authenticator.swift.
        let auth = try Authenticator(paths: ["/admin"], realm: "Admin",
                                     tokens: [BearerToken(name: "ci", token: "secret")])
        let server = Server(listeners: [BSDSocketListener](), protocols: [HTTP1()]) {
            auth
            c.router
            c.files
        }
        #expect(handlerType(server) == CompiledChain<MiddlewareChain<Authenticator, MiddlewareChain<Router, StaticFiles>>>.self)
    }

    @Test func webSocketUpgradeDocExample() {
        // Sources/WebSockets/WebSocketUpgrade.swift.
        let server = Server(listeners: [BSDSocketListener](), protocols: [HTTP1()]) {
            WebSocketUpgrade(path: "/ws") { socket, _ in
                for await message in socket.messages { try await socket.send(message) }
            }
            c.files
        }
        #expect(handlerType(server) == CompiledChain<MiddlewareChain<WebSocketUpgrade, StaticFiles>>.self)
    }

    @Test func routerAndVirtualHostsDocExamples() {
        // Sources/Router/Router.swift and Sources/VirtualHosts/VirtualHosts.swift.
        let routed = Server(listeners: [BSDSocketListener](), protocols: [HTTP1()]) {
            AccessLog(destination: .standardError)
            c.router
        }
        #expect(handlerType(routed) == CompiledChain<MiddlewareChain<AccessLog, Router>>.self)
        let hosted = Server(listeners: [BSDSocketListener](), protocols: [HTTP1()]) {
            AccessLog(destination: .standardError)
            c.sites
        }
        #expect(handlerType(hosted) == CompiledChain<MiddlewareChain<AccessLog, VirtualHosts>>.self)
    }

    @Test func virtualHostChainEndingInStaticFiles() throws {
        // Sources/VirtualHosts/VirtualHosts.swift: a host's own chain.
        let files = c.files
        let sites = try VirtualHosts {
            VirtualHost("*.example.org") {
                AccessLog(destination: .standardError)
                files
            }
        }
        #expect(sites.hosts.count == 1)
    }

    @Test func customServerExample() {
        // Examples/custom-server and docs/guide/choosing-components.md.
        let echo = WebSocketUpgrade(path: "/ws") { _, _ in }
        let server = Server(listeners: [BSDSocketListener](), protocols: [HTTP1()]) {
            AccessLog(format: .combined, destination: .standardOutput)
            Compression()
            echo
            c.router
            c.files
        }
        #expect(handlerType(server) == CompiledChain<MiddlewareChain<AccessLog, MiddlewareChain<Compression, MiddlewareChain<WebSocketUpgrade, MiddlewareChain<Router, StaticFiles>>>>>.self)
    }
}
