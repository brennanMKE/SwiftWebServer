import Testing
import HTTPCore
@testable import Router

@Suite struct RouterMatchTests {
    @Test func literalRoutes() throws {
        let router = try Router {
            GET("/", ok)
            GET("/users", ok)
            GET("/users/list", ok)
            GET("/a b", ok)
        }
        #expect(router.resolve("/") == .route("/", [:]))
        #expect(router.resolve("/users") == .route("/users", [:]))
        #expect(router.resolve("/users/list") == .route("/users/list", [:]))
        #expect(router.resolve("/a%20b") == .route("/a b", [:]))
        #expect(router.resolve("/users/") == .notFound)        // a trailing slash is a different path
        #expect(router.resolve("/user") == .notFound)
        #expect(router.resolve("/users/list/more") == .notFound)
        #expect(router.resolve("") == .notFound)
        #expect(router.resolve("*") == .notFound)
        #expect(router.resolve("/users?x=1") == .route("/users", [:]))   // the query is not part of the path
    }

    @Test func parameters() throws {
        let router = try Router {
            GET("/users/:id", ok)
            GET("/users/:id/posts/:post", ok)
            GET("/orgs/:org/members", ok)
        }
        #expect(router.resolve("/users/42") == .route("/users/:id", ["id": "42"]))
        #expect(router.resolve("/users/42/posts/7") == .route("/users/:id/posts/:post", ["id": "42", "post": "7"]))
        #expect(router.resolve("/orgs/acme/members") == .route("/orgs/:org/members", ["org": "acme"]))
        #expect(router.resolve("/users/") == .notFound)        // a parameter never matches an empty segment
        #expect(router.resolve("/users//posts/7") == .notFound)
        #expect(router.resolve("/orgs/acme") == .notFound)

        let test = TestRequest(.get, "/users/42/posts/7")
        guard case .route(let route) = router.match(test.request) else { Issue.record("no match"); return }
        #expect(route.parameters.count == 2)
        #expect(route.parameters.names == ["id", "post"])
        #expect(route.parameters.decimal("id") == 42)
        #expect(route.parameters.value(at: 1) == "7")
        #expect(route.parameters["missing"] == nil)
        #expect(route.parameters.wildcard == nil)
        let view = try #require(route.parameters.view("id"))
        #expect(test.request.string(of: view) == "42")
        #expect(route.parameters.withBytes("post") { $0.count } == 1)
    }

    @Test func wildcards() throws {
        let router = try Router {
            GET("/files/*path", ok)
            GET("/static/*", ok)
            GET("/users/:id/*rest", ok)
        }
        #expect(router.resolve("/files/a/b/c.txt") == .route("/files/*path", ["path": "a/b/c.txt"]))
        #expect(router.resolve("/files/") == .route("/files/*path", ["path": ""]))
        #expect(router.resolve("/files") == .notFound)
        #expect(router.resolve("/static/x") == .route("/static/*", ["*": "x"]))
        #expect(router.resolve("/users/7/a/b") == .route("/users/:id/*rest", ["id": "7", "rest": "a/b"]))

        let test = TestRequest(.get, "/files/x/y")
        guard case .route(let route) = router.match(test.request) else { Issue.record("no match"); return }
        #expect(route.parameters.wildcard == "x/y")
    }

    @Test func precedenceLiteralThenParameterThenWildcard() throws {
        let router = try Router {
            GET("/users/*", ok)          // registration order does not matter
            GET("/users/:id", ok)
            GET("/users/new", ok)
        }
        #expect(router.resolve("/users/new") == .route("/users/new", [:]))
        #expect(router.resolve("/users/42") == .route("/users/:id", ["id": "42"]))
        #expect(router.resolve("/users/42/x") == .route("/users/*", ["*": "42/x"]))
        #expect(router.resolve("/users/") == .route("/users/*", ["*": ""]))
    }

    @Test func backtracksFromLiteralToParameter() throws {
        let router = try Router {
            GET("/a/b/c", ok)
            GET("/a/:x/d", ok)
            GET("/a/:x/:y/e", ok)
            GET("/a/*", ok)
        }
        #expect(router.resolve("/a/b/c") == .route("/a/b/c", [:]))
        #expect(router.resolve("/a/b/d") == .route("/a/:x/d", ["x": "b"]))
        #expect(router.resolve("/a/b/c/e") == .route("/a/:x/:y/e", ["x": "b", "y": "c"]))
        #expect(router.resolve("/a/b/zz") == .route("/a/*", ["*": "b/zz"]))
    }

    @Test func groups() throws {
        let router = try Router {
            GET("/", ok)
            Group("/api") {
                GET("/", ok)
                GET("/status", ok)
                Group("/v1/") {
                    GET("/users/:id", ok)
                    Group("/admin") { POST("/reset", ok) }
                }
                Group("/orgs/:org") { GET("/repos/:repo", ok) }
            }
        }
        #expect(router.count == 6)
        #expect(router.resolve("/") == .route("/", [:]))
        #expect(router.resolve("/api") == .route("/api", [:]))
        #expect(router.resolve("/api/status") == .route("/api/status", [:]))
        #expect(router.resolve("/api/v1/users/9") == .route("/api/v1/users/:id", ["id": "9"]))
        #expect(router.resolve(.post, "/api/v1/admin/reset") == .route("/api/v1/admin/reset", [:]))
        #expect(router.resolve("/api/orgs/a/repos/b") == .route("/api/orgs/:org/repos/:repo", ["org": "a", "repo": "b"]))
    }

    @Test func builderControlFlow() throws {
        let enabled = true
        let disabled = false
        let names = ["a", "b", "c"]
        let router = try Router {
            if enabled { GET("/on", ok) }
            if disabled { GET("/off", ok) }
            if disabled { GET("/x", ok) } else { GET("/y", ok) }
            for name in names { GET("/n/\(name)", ok) }
        }
        #expect(router.count == 5)
        #expect(router.resolve("/on") != .notFound)
        #expect(router.resolve("/off") == .notFound)
        #expect(router.resolve("/y") != .notFound)
        #expect(router.resolve("/n/c") != .notFound)
    }

    @Test func percentEncodedParameters() throws {
        let router = try Router {
            GET("/users/:name", ok)
            GET("/files/*path", ok)
        }
        #expect(router.resolve("/users/J%C3%B6rg") == .route("/users/:name", ["name": "Jörg"]))
        #expect(router.resolve("/users/a%2Fb") == .route("/users/:name", ["name": "a/b"]))
        #expect(router.resolve("/users/50%") == .route("/users/:name", ["name": "50%"]))     // malformed escape kept
        #expect(router.resolve("/users/a+b") == .route("/users/:name", ["name": "a+b"]))     // `+` is not a space
        #expect(router.resolve("/files/dir/a%20b.txt") == .route("/files/*path", ["path": "dir/a b.txt"]))

        let test = TestRequest(.get, "/users/J%C3%B6rg")
        guard case .route(let route) = router.match(test.request) else { Issue.record("no match"); return }
        #expect(route.parameters.isPercentEncoded("name"))
        #expect(route.parameters.rawValue("name") == "J%C3%B6rg")

        let plain = TestRequest(.get, "/users/plain")
        guard case .route(let plainRoute) = router.match(plain.request) else { Issue.record("no match"); return }
        #expect(!plainRoute.parameters.isPercentEncoded("name"))
    }

    @Test func percentFlagIsPerCapture() throws {
        let router = try Router { GET("/:a/:b/:c", ok) }
        #expect(router.resolve("/x%41/y/z%42") == .route("/:a/:b/:c", ["a": "xA", "b": "y", "c": "zB"]))
        // A capture that was popped while backtracking must not leave its flag behind.
        let backtrack = try Router {
            GET("/p/:x/end", ok)
            GET("/p/*", ok)
        }
        #expect(backtrack.resolve("/p/%41/other") == .route("/p/*", ["*": "A/other"]))
    }

    @Test func largeTable() throws {
        var routes: [Route] = []
        for i in 0..<300 {
            routes.append(GET("/r\(i)", ok))
            routes.append(GET("/r\(i)/items/:id", ok))
            routes.append(POST("/r\(i)/items", ok))
        }
        routes.append(GET("/r0/*", ok))
        let router = try Router(routes: routes)
        #expect(router.count == 901)
        for i in stride(from: 0, to: 300, by: 7) {
            #expect(router.resolve("/r\(i)") == .route("/r\(i)", [:]))
            #expect(router.resolve("/r\(i)/items/\(i * 3)") == .route("/r\(i)/items/:id", ["id": "\(i * 3)"]))
            #expect(router.resolve(.post, "/r\(i)/items") == .route("/r\(i)/items", [:]))
            // GET on a POST-only path: 405, except under /r0 where the GET wildcard answers.
            #expect(router.resolve("/r\(i)/items") == (i == 0 ? .route("/r0/*", ["*": "items"]) : .methodNotAllowed("POST")))
        }
        #expect(router.resolve("/r300") == .notFound)
        #expect(router.resolve("/r0/zzz") == .route("/r0/*", ["*": "zzz"]))
    }
}

@Suite struct RouterMethodTests {
    @Test func methodNotAllowedListsAllow() throws {
        let router = try Router {
            GET("/users", ok)
            POST("/users", ok)
            Route("/things", methods: [.put, .patch, .other(HTTPMethod.Token("PROPFIND")!)], ok)
        }
        #expect(router.resolve(.delete, "/users") == .methodNotAllowed("GET, HEAD, POST"))
        #expect(router.resolve(.get, "/things") == .methodNotAllowed("PUT, PATCH, PROPFIND"))
        #expect(router.resolve(.other(HTTPMethod.Token("PROPFIND")!), "/things") == .route("/things", [:]))
    }

    @Test func methodNotAllowedCombinesMatchingPatterns() throws {
        let router = try Router {
            GET("/users/new", ok)
            PUT("/users/:id", ok)
            Route("/users/*", methods: [.options], ok)
        }
        #expect(router.resolve(.delete, "/users/new") == .methodNotAllowed("GET, HEAD, PUT, OPTIONS"))
        #expect(router.resolve(.delete, "/users/7") == .methodNotAllowed("PUT, OPTIONS"))
    }

    @Test func methodFallsToLowerPrecedenceRoute() throws {
        let router = try Router {
            GET("/users/new", ok)
            POST("/users/:id", ok)
        }
        #expect(router.resolve(.post, "/users/new") == .route("/users/:id", ["id": "new"]))
        #expect(router.resolve(.get, "/users/new") == .route("/users/new", [:]))
    }

    @Test func headIsServedByGet() async throws {
        let router = try Router {
            GET("/page", respond(200))
            GET("/both", respond(200))
            HEAD("/both", respond(204))
            POST("/post", respond(201))
        }
        #expect(router.resolve(.head, "/page") == .route("/page", [:]))
        #expect(try await router.status(.head, "/page") == 200)
        #expect(try await router.status(.head, "/both") == 204)
        #expect(try await router.status(.get, "/both") == 200)
        #expect(router.resolve(.head, "/post") == .methodNotAllowed("POST"))
    }

    @Test func anyMethodRoute() throws {
        let router = try Router {
            Route("/any", ok)
            GET("/mixed", ok)
            Route("/mixed/:x", ok)
        }
        #expect(router.resolve(.delete, "/any") == .route("/any", [:]))
        #expect(router.resolve(.other(HTTPMethod.Token("BREW")!), "/any") == .route("/any", [:]))
        #expect(router.resolve(.put, "/mixed/1") == .route("/mixed/:x", ["x": "1"]))
    }
}

@Suite struct RouterDispatchTests {
    @Test func fallsThroughToNext() async throws {
        let router = try Router {
            GET("/users/:id", respond(200))
            POST("/users", respond(201))
        }
        #expect(try await router.status(.get, "/users/1") == 200)
        #expect(try await router.status(.post, "/users") == 201)
        #expect(try await router.status(.get, "/index.html") == 299)    // e.g. StaticFiles next
        #expect(try await router.status(.get, "/users/1/x") == 299)
        #expect(try await router.status(.get, "/users") == 405)

        // As a lone handler: 404.
        let test = TestRequest(.get, "/nothing")
        #expect(try await router.handle(test.request, context: RequestContext()).status.code == 404)
    }

    @Test func composesInMiddlewareChain() async throws {
        let router = try Router { GET("/api/ping", respond(204)) }
        let chain = MiddlewareBuilder.build {
            router
            FallThrough()
        }
        let hit = TestRequest(.get, "/api/ping")
        let miss = TestRequest(.get, "/style.css")
        #expect(try await chain.handle(hit.request, context: RequestContext()).status.code == 204)
        #expect(try await chain.handle(miss.request, context: RequestContext()).status.code == 299)
    }

    @Test func handlerReadsParameters() async throws {
        let router = try Router {
            GET("/users/:id/files/*path") { request, context in
                #expect(context.params["id"] == "J\u{F6}rg")
                #expect(context.params["path"] == "a/b")
                #expect(context.params.wildcard == "a/b")
                #expect(context[Tag.self] == "tagged")
                #expect(context.startTime == nil)
                return HTTPResponse(status: .ok)
            }
        }
        var context = RequestContext()
        context[Tag.self] = "tagged"
        let test = TestRequest(.get, "/users/J%C3%B6rg/files/a/b")
        #expect(try await router.handle(test.request, context: context, next: FallThrough()).status.code == 200)
    }

    @Test func httpHandlerRouteFindsParametersInContext() async throws {
        let router = try Router {
            GET("/items/:id", handler: ItemHandler())
            Route("/any/:id", handler: ItemHandler())
        }
        #expect(try await router.status(.get, "/items/17") == 217)
        #expect(try await router.status(.delete, "/any/3") == 203)
    }

    enum Tag: RequestContextKey { static var defaultValue: String { "" } }

    struct ItemHandler: HTTPHandler {
        func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
            let id = context.routeParameters?.decimal("id") ?? 0
            return HTTPResponse(status: HTTPStatus(code: 200 + Int(id)))
        }
    }
}

@Suite struct RouterBuildTests {
    @Test func duplicateRouteIsAConflict() {
        #expect(throws: RouterError.conflict(pattern: "/users", existing: "/users", method: "GET")) {
            try Router {
                GET("/users", ok)
                GET("/users", ok)
            }
        }
    }

    @Test func parameterNamesDoNotDisambiguate() {
        #expect(throws: RouterError.conflict(pattern: "/users/:name", existing: "/users/:id", method: "GET")) {
            try Router {
                GET("/users/:id", ok)
                GET("/users/:name", ok)
            }
        }
        #expect(throws: RouterError.conflict(pattern: "/f/*b", existing: "/f/*", method: "GET")) {
            try Router {
                GET("/f/*", ok)
                GET("/f/*b", ok)
            }
        }
    }

    @Test func overlappingMethodConstraintsConflict() {
        #expect(throws: RouterError.conflict(pattern: "/x", existing: "/x", method: "PUT")) {
            try Router {
                Route("/x", methods: [.get, .put], ok)
                Route("/x", methods: [.post, .put], ok)
            }
        }
        #expect(throws: RouterError.conflict(pattern: "/x", existing: "/x", method: "GET")) {
            try Router {
                Route("/x", ok)
                GET("/x", ok)
            }
        }
        #expect(throws: RouterError.conflict(pattern: "/api/x", existing: "/api/x", method: "GET")) {
            try Router {
                GET("/api/x", ok)
                Group("/api") { GET("/x", ok) }
            }
        }
    }

    @Test func disjointMethodsAndShapesDoNotConflict() throws {
        let router = try Router {
            GET("/x", ok)
            HEAD("/x", ok)
            POST("/x", ok)
            GET("/x/:id", ok)
            GET("/x/*", ok)
            GET("/x/", ok)
        }
        #expect(router.count == 6)
    }

    @Test func conflictErrorIsReadable() {
        let error = RouterError.conflict(pattern: "/a/:b", existing: "/a/:c", method: "GET")
        #expect(error.description == "route GET '/a/:b' conflicts with GET '/a/:c': both match the same paths")
    }

    @Test(arguments: [
        "users", "/a/*/b", "/a/:", "/a/:b-c", "/a/:x/:x", "/:a/:b/:c/:d/:e/:f/:g/:h/:i",
    ])
    func invalidPatterns(_ pattern: String) {
        #expect(throws: RouterError.self) { try Router { GET(pattern, ok) } }
    }

    @Test func emptyMethodListIsInvalid() {
        #expect(throws: RouterError.self) { try Router { Route("/x", methods: [], ok) } }
    }

    @Test func eightParametersAreAllowed() throws {
        let router = try Router { GET("/:a/:b/:c/:d/:e/:f/:g/*h", ok) }
        #expect(router.resolve("/1/2/3/4/5/6/7/8/9") == .route("/:a/:b/:c/:d/:e/:f/:g/*h", [
            "a": "1", "b": "2", "c": "3", "d": "4", "e": "5", "f": "6", "g": "7", "h": "8/9",
        ]))
    }
}
