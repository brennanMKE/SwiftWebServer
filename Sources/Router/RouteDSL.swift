public import HTTPCore

/// Answers a matched route. The request is valid only while the handler runs (see
/// ``HTTPRequest``); `context.params` reads the captured path parameters.
public typealias RouteHandler = @Sendable (HTTPRequest, RouteContext) async throws -> HTTPResponse

/// One route: a path pattern, the methods it answers and its handler (#0094).
///
/// Pattern syntax, one rule per `/`-separated segment:
///
/// | Segment | Matches |
/// |---|---|
/// | `users` | exactly these bytes (compared with the still percent-encoded request path) |
/// | `:id` | any non-empty segment, captured as `id` |
/// | `*` or `*path` (last segment only) | the rest of the path, possibly empty, captured as `*` or `path` |
///
/// `methods: nil` answers every method. A route for `GET` also answers `HEAD` unless a `HEAD`
/// route exists for the same pattern.
public struct Route: Sendable {
    /// The pattern as written (with any ``Group(_:_:)`` prefixes applied).
    public let pattern: String
    /// The methods the route answers; `nil` for all.
    public let methods: [HTTPMethod]?
    let handler: RouteHandler

    /// A route answering `methods` (all when `nil`) with a closure.
    public init(_ pattern: String, methods: [HTTPMethod]? = nil, _ handler: @escaping RouteHandler) {
        self.pattern = pattern
        self.methods = methods
        self.handler = handler
    }

    /// A route answering `methods` (all when `nil`) with an ``HTTPHandler``. The handler finds
    /// the captured parameters in ``RequestContext/routeParameters`` (setting them costs one
    /// small allocation per request, see ``RouteContext/requestContextWithParameters``).
    public init<H: HTTPHandler>(_ pattern: String, methods: [HTTPMethod]? = nil, handler: H) {
        self.init(pattern, methods: methods) { request, context in
            try await handler.handle(request, context: context.requestContextWithParameters)
        }
    }

    /// The same route with `prefix` in front of its pattern.
    func prefixed(_ prefix: String) -> Route {
        Route(Route.join(prefix, pattern), methods: methods, handler)
    }

    /// `prefix` + `pattern`, so that `Group("/api") { GET("/") }` is `/api` and
    /// `Group("/api/") { GET("/x") }` is `/api/x`.
    static func join(_ prefix: String, _ pattern: String) -> String {
        var base = Substring(prefix)
        while base.hasSuffix("/") { base = base.dropLast() }
        if pattern == "/" || pattern.isEmpty { return base.isEmpty ? "/" : String(base) }
        return String(base) + (pattern.hasPrefix("/") ? pattern : "/" + pattern)
    }
}

/// Collects routes: `Route`s, ``Group(_:_:)``s, `if`, `if`/`else` and `for` loops.
@resultBuilder
public enum RouteBuilder {
    public static func buildExpression(_ route: Route) -> [Route] { [route] }
    public static func buildExpression(_ routes: [Route]) -> [Route] { routes }
    public static func buildBlock(_ components: [Route]...) -> [Route] { components.flatMap { $0 } }
    public static func buildOptional(_ component: [Route]?) -> [Route] { component ?? [] }
    public static func buildEither(first component: [Route]) -> [Route] { component }
    public static func buildEither(second component: [Route]) -> [Route] { component }
    public static func buildArray(_ components: [[Route]]) -> [Route] { components.flatMap { $0 } }
    public static func buildLimitedAvailability(_ component: [Route]) -> [Route] { component }
}

/// The routes built by `routes`, each with `prefix` in front of its pattern. Groups nest.
public func Group(_ prefix: String, @RouteBuilder _ routes: () -> [Route]) -> [Route] {
    routes().map { $0.prefixed(prefix) }
}

// MARK: - Method shorthands

/// A `GET` route (it also answers `HEAD`).
public func GET(_ pattern: String, _ handler: @escaping RouteHandler) -> Route {
    Route(pattern, methods: [.get], handler)
}
/// A `HEAD` route; it takes precedence over the `GET` route of the same pattern for `HEAD`.
public func HEAD(_ pattern: String, _ handler: @escaping RouteHandler) -> Route {
    Route(pattern, methods: [.head], handler)
}
/// A `POST` route.
public func POST(_ pattern: String, _ handler: @escaping RouteHandler) -> Route {
    Route(pattern, methods: [.post], handler)
}
/// A `PUT` route.
public func PUT(_ pattern: String, _ handler: @escaping RouteHandler) -> Route {
    Route(pattern, methods: [.put], handler)
}
/// A `DELETE` route.
public func DELETE(_ pattern: String, _ handler: @escaping RouteHandler) -> Route {
    Route(pattern, methods: [.delete], handler)
}
/// A `PATCH` route.
public func PATCH(_ pattern: String, _ handler: @escaping RouteHandler) -> Route {
    Route(pattern, methods: [.patch], handler)
}
/// An `OPTIONS` route.
public func OPTIONS(_ pattern: String, _ handler: @escaping RouteHandler) -> Route {
    Route(pattern, methods: [.options], handler)
}

/// A `GET` route served by an ``HTTPHandler``.
public func GET<H: HTTPHandler>(_ pattern: String, handler: H) -> Route {
    Route(pattern, methods: [.get], handler: handler)
}
/// A `POST` route served by an ``HTTPHandler``.
public func POST<H: HTTPHandler>(_ pattern: String, handler: H) -> Route {
    Route(pattern, methods: [.post], handler: handler)
}
/// A `PUT` route served by an ``HTTPHandler``.
public func PUT<H: HTTPHandler>(_ pattern: String, handler: H) -> Route {
    Route(pattern, methods: [.put], handler: handler)
}
/// A `DELETE` route served by an ``HTTPHandler``.
public func DELETE<H: HTTPHandler>(_ pattern: String, handler: H) -> Route {
    Route(pattern, methods: [.delete], handler: handler)
}
