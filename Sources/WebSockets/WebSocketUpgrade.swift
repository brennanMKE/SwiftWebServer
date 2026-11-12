public import HTTPCore

/// What the application learns about an accepted (or candidate) WebSocket request. It owns
/// its values, so it stays valid after the HTTP request is gone.
public struct WebSocketRequest: Sendable {
    /// The request path, still percent-encoded.
    public var path: String
    /// The query without `?`; empty when absent.
    public var query: String
    /// The `Origin` field, if any (browsers always send it).
    public var origin: String?
    /// The subprotocols the client offered, in its order of preference.
    public var offeredSubprotocols: [String]
    /// Every request field.
    public var headers: HTTPFields
    /// The connection's addresses.
    public var connection: ConnectionInfo

    public init(path: String, query: String = "", origin: String? = nil, offeredSubprotocols: [String] = [],
                headers: HTTPFields = HTTPFields(), connection: ConnectionInfo = ConnectionInfo()) {
        self.path = path
        self.query = query
        self.origin = origin
        self.offeredSubprotocols = offeredSubprotocols
        self.headers = headers
        self.connection = connection
    }

    init(_ request: HTTPRequest, context: RequestContext) {
        self.init(path: request.string(of: request.path), query: request.string(of: request.query),
                  origin: request.headers.firstValueString(for: .origin),
                  offeredSubprotocols: WebSocketHandshake.offeredSubprotocols(request),
                  headers: request.headers.snapshot(), connection: context.connection)
    }
}

/// The WebSocket component (RFC 6455 over the `.tunnel` hook): a middleware that answers
/// opening handshakes with `101 Switching Protocols` and runs a ``WebSocket`` session over
/// the connection's byte stream.
///
/// ```swift
/// Server(configuration: config, listeners: [listener], protocols: [HTTP1()]) {
///     WebSocketUpgrade(path: "/ws") { socket, request in
///         for await message in socket.messages { try await socket.send(message) }
///     }
///     StaticFiles(root: publicURL)
/// }
/// ```
///
/// Requests are matched by `path` (any path when `nil`):
/// - On a matching path, a request with `Upgrade: websocket` must be a valid handshake
///   (``WebSocketHandshake/validate(_:)``): otherwise `400`, or `426` with
///   `Sec-WebSocket-Version: 13` for a wrong version. With an explicit `path`, a request
///   without `Upgrade: websocket` gets `426`; with `path` `nil` it goes to the next handler.
/// - ``origin`` rejects a handshake with `403` when it returns false (browsers send `Origin`;
///   check it against your own origins to stop cross-site WebSocket hijacking).
/// - ``subprotocol`` picks one of the offered subprotocols (or `nil` for none); a choice the
///   client did not offer is ignored.
/// - Requests on other paths go to the next handler untouched.
///
/// The session itself only needs a ``ByteStreamTransport``, so the same handler can run
/// over HTTP/2 (RFC 8441) and HTTP/3 (RFC 9220) extended CONNECT streams.
public struct WebSocketUpgrade: HTTPMiddleware {
    public typealias Handler = @Sendable (WebSocket, WebSocketRequest) async throws -> Void

    public let path: [UInt8]?
    public let configuration: WebSocketConfiguration
    public let origin: (@Sendable (WebSocketRequest) -> Bool)?
    public let subprotocol: (@Sendable (WebSocketRequest) -> String?)?
    public let handler: Handler

    public init(
        path: String? = nil,
        configuration: WebSocketConfiguration = WebSocketConfiguration(),
        origin: (@Sendable (WebSocketRequest) -> Bool)? = nil,
        subprotocol: (@Sendable (WebSocketRequest) -> String?)? = nil,
        handler: @escaping Handler
    ) {
        self.path = path.map { Array($0.utf8) }
        self.configuration = configuration
        self.origin = origin
        self.subprotocol = subprotocol
        self.handler = handler
    }

    public func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                          next: Next) async throws -> HTTPResponse {
        if let path {
            let matches = request.withSpan(of: request.path) { span in
                span.withUnsafeBufferPointer { $0.elementsEqual(path) }
            }
            guard matches else { return try await next.handle(request, context: context) }
        } else if !WebSocketHandshake.isUpgradeRequest(request) {
            return try await next.handle(request, context: context)
        }
        return upgrade(request, context: context)
    }

    /// The handshake response for a request on this component's path.
    public func upgrade(_ request: HTTPRequest, context: RequestContext) -> HTTPResponse {
        let accept: String
        do {
            accept = try WebSocketHandshake.validate(request)
        } catch {
            return error.response
        }
        let info = WebSocketRequest(request, context: context)
        if let origin, !origin(info) { return HTTPResponse(status: .forbidden) }
        let chosen: String? = subprotocol.flatMap { pick in
            pick(info).flatMap { info.offeredSubprotocols.contains($0) ? $0 : nil }
        }

        var headers = HTTPFields()
        headers.append(.upgrade, "websocket")
        headers.append(.connection, "Upgrade")
        headers.append(.secWebSocketAccept, string: accept)
        if let chosen { headers.append(.secWebSocketProtocol, string: chosen) }
        let configuration = configuration
        let handler = handler
        return HTTPResponse(status: .switchingProtocols, headers: headers, body: .tunnel { transport, tunnel in
            await Self.serve(transport, subprotocol: chosen, configuration: configuration,
                             shutdown: tunnel.shutdown) { socket in
                try await handler(socket, info)
            }
        })
    }

    /// Opens the existential so the session is specialized on the transport type.
    static func serve<T: ByteStreamTransport>(
        _ transport: T, subprotocol: String?, configuration: WebSocketConfiguration, shutdown: ShutdownSignal,
        handler: @escaping @Sendable (WebSocket) async throws -> Void
    ) async {
        await WebSocket.run(over: transport, subprotocol: subprotocol, configuration: configuration,
                            shutdown: shutdown, handler: handler)
    }
}
