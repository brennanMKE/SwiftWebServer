public import HTTPCore

/// Dispatches requests to handlers by method and path pattern (#0094, docs/ROADMAP.md §5.2).
///
/// ```swift
/// let router = try Router {
///     GET("/users/:id") { request, context in
///         let id = context.params["id"]          // decoded on demand
///         …
///     }
///     POST("/users") { request, context in … }
///     Group("/api") {
///         GET("/status") { _, _ in HTTPResponse(status: .ok) }
///         Route("/files/*path", methods: [.get, .put]) { request, context in … }
///     }
/// }
/// let server = Server(listeners: [listener], protocols: [HTTP1()]) {
///     router
///     StaticFiles(root: publicURL)
/// }
/// ```
///
/// - Patterns: literal segments, `:name` captures one non-empty segment, a trailing `*` or
///   `*name` captures the rest (``Route``). Literals compare with the still-encoded path.
/// - Precedence at each segment: literal, then parameter, then wildcard, with backtracking.
/// - A `GET` route answers `HEAD` too, unless a `HEAD` route exists for the same pattern.
/// - A path some route matches, requested with a method no matching route answers, gets `405`
///   with `Allow` listing the methods that would be answered.
/// - Anything else falls through to `next` (as a middleware) or gets `404` (as a handler).
/// - Building checks every pattern and rejects two routes that match the same paths with the
///   same method (``RouterError``).
///
/// ## Hot path
///
/// The table is a segment trie compiled once, in flat arrays. Matching walks the path bytes
/// and records captures as byte ranges inline in ``RouteParameters``: no allocation, no
/// `String`, on hits and misses alike (`sws-bench micro --filter Router`,
/// docs/benchmarks/M6-router.md). A capture becomes a `String`, percent-decoded only when it
/// contains `%`, when the handler reads it.
public struct Router: HTTPMiddleware, HTTPHandler {
    let table: RouteTable

    /// Builds the table from `routes`.
    public init(@RouteBuilder _ routes: () -> [Route]) throws(RouterError) {
        try self.init(routes: routes())
    }

    /// Builds the table from `routes`, in order (the order only matters for error messages).
    public init(routes: [Route]) throws(RouterError) {
        table = try RouteTable(routes)
    }

    /// Number of routes.
    public var count: Int { table.routes.count }

    // MARK: Matching

    /// The outcome of ``match(_:)``.
    public enum Match: Sendable {
        /// A route answers the request.
        case route(MatchedRoute)
        /// The path matches, the method does not: a `405` with `Allow`.
        case methodNotAllowed(HTTPResponse)
        /// No route matches the path.
        case notFound
    }

    /// A route that matched, with its captured parameters.
    public struct MatchedRoute: Sendable {
        let index: Int32
        /// The captured parameters.
        public let parameters: RouteParameters
        let table: RouteTable

        /// The matched route's pattern.
        public var pattern: String { table.routes[Int(index)].pattern }
    }

    /// Matches `request` against the table. Synchronous; does not allocate, except for a `405` on
    /// a path matched by more than one pattern (the combined `Allow` is built then).
    public func match(_ request: HTTPRequest) -> Match {
        var captures = Captures()
        let table = table
        let outcome = request.withSpan(of: request.path) { path in
            table.lookup(path: path, method: request.method, captures: &captures)
        }
        switch outcome {
        case .route(let index):
            let names = table.routes[Int(index)].names
            let parameters = names == nil
                ? RouteParameters()
                : RouteParameters(names: names, source: request.headers, base: request.path.offset, captures: captures)
            return .route(MatchedRoute(index: index, parameters: parameters, table: table))
        case .methodNotAllowed(let terminal):
            return .methodNotAllowed(methodNotAllowed(request, first: terminal))
        case .notFound:
            return .notFound
        }
    }

    /// The `405` for `request`: the matching pattern's prebuilt response, or a combined one
    /// (built per request) when several patterns match the path.
    func methodNotAllowed(_ request: HTTPRequest, first: Int32) -> HTTPResponse {
        let table = table
        var matching = 0
        request.withSpan(of: request.path) { path in
            table.forEachMatchingTerminal(path: path) { _ in matching += 1 }
        }
        if matching <= 1 { return table.terminals[Int(first)].methodNotAllowed }
        var methods: [HTTPMethod] = []
        request.withSpan(of: request.path) { path in
            table.forEachMatchingTerminal(path: path) { terminal in
                for method in table.terminals[Int(terminal)].allowed where !methods.contains(method) {
                    methods.append(method)
                }
            }
        }
        return RouteTable.methodNotAllowed(RouteTable.displayOrder(methods))
    }

    // MARK: HTTPMiddleware and HTTPHandler

    /// Answers a matched route, a `405`, or passes the request to `next`.
    public func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                          next: Next) async throws -> HTTPResponse {
        switch match(request) {
        case .route(let route):
            return try await table.routes[Int(route.index)].handler(
                request, RouteContext(requestContext: context, params: route.parameters))
        case .methodNotAllowed(let response):
            return response
        case .notFound:
            return try await next.handle(request, context: context)
        }
    }

    /// Answers a matched route, a `405`, or `404`.
    public func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        try await handle(request, context: context, next: NotFoundHandler())
    }
}
