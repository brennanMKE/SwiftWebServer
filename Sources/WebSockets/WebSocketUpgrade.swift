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
/// opening handshakes with `101 Switching Protocols` (HTTP/1.1) or `200` (an extended CONNECT
/// over HTTP/3, RFC 9220) and runs a ``WebSocket`` session over the connection's byte stream
/// or the request stream.
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
/// - With ``WebSocketConfiguration/compression`` set, a permessage-deflate offer in
///   `Sec-WebSocket-Extensions` is accepted (RFC 7692, ``PerMessageDeflate``) and answered in
///   the response's `Sec-WebSocket-Extensions`.
/// - Requests on other paths go to the next handler untouched.
///
/// The session itself only needs a ``ByteStreamTransport``, so the same handler runs over
/// HTTP/3 (RFC 9220, #0111) and later HTTP/2 (RFC 8441, #0067) extended CONNECT streams: an
/// extended CONNECT with `:protocol websocket` and `Sec-WebSocket-Version: 13` on the path is
/// answered `200` (`400` otherwise, with `Sec-WebSocket-Version: 13` for a wrong version), with
/// the same Origin, subprotocol and permessage-deflate handling. The component is an
/// ``ExtendedConnectProvider``, so HTTP/3 advertises `SETTINGS_ENABLE_CONNECT_PROTOCOL` when it
/// is in the chain.
public struct WebSocketUpgrade: HTTPMiddleware, ExtendedConnectProvider {
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

    /// `websocket`, for HTTP/2 and HTTP/3 extended CONNECT.
    public var extendedConnectProtocols: [String] { ["websocket"] }

    /// The handshake response for a request on this component's path.
    public func upgrade(_ request: HTTPRequest, context: RequestContext) -> HTTPResponse {
        let extendedConnect = request.method == .connect
        var accept: String?
        do {
            if extendedConnect {
                try WebSocketHandshake.validateExtendedConnect(request)
            } else {
                accept = try WebSocketHandshake.validate(request)
            }
        } catch {
            return extendedConnect ? error.extendedConnectResponse : error.response
        }
        let info = WebSocketRequest(request, context: context)
        if let origin, !origin(info) { return HTTPResponse(status: .forbidden) }
        let chosen: String? = subprotocol.flatMap { pick in
            pick(info).flatMap { info.offeredSubprotocols.contains($0) ? $0 : nil }
        }

        let agreement = negotiateCompression(request)

        var headers = HTTPFields()
        if let accept {
            headers.append(.upgrade, "websocket")
            headers.append(.connection, "Upgrade")
            headers.append(.secWebSocketAccept, string: accept)
        }
        if let chosen { headers.append(.secWebSocketProtocol, string: chosen) }
        if let agreement { headers.append(.secWebSocketExtensions, string: agreement.responseValue) }
        let configuration = configuration
        let handler = handler
        let compression = agreement?.parameters
        return HTTPResponse(status: extendedConnect ? .ok : .switchingProtocols, headers: headers, body: .tunnel { transport, tunnel in
            await Self.serve(transport, subprotocol: chosen, configuration: configuration, compression: compression,
                             shutdown: tunnel.shutdown) { socket in
                try await handler(socket, info)
            }
        })
    }

    /// The permessage-deflate agreement for `request`'s `Sec-WebSocket-Extensions` offers, when
    /// ``WebSocketConfiguration/compression`` enables the extension.
    func negotiateCompression(_ request: HTTPRequest) -> PerMessageDeflate.Agreement? {
        guard let compression = configuration.compression else { return nil }
        var offers = ""
        for value in request.headers.values(for: .secWebSocketExtensions) {
            if !offers.isEmpty { offers += "," }
            offers += request.string(of: value)
        }
        guard !offers.isEmpty else { return nil }
        return PerMessageDeflate.negotiate(offers: offers, configuration: compression)
    }

    /// Opens the existential so the session is specialized on the transport type.
    static func serve<T: ByteStreamTransport>(
        _ transport: T, subprotocol: String?, configuration: WebSocketConfiguration,
        compression: PerMessageDeflate.Parameters?, shutdown: ShutdownSignal,
        handler: @escaping @Sendable (WebSocket) async throws -> Void
    ) async {
        await WebSocket.run(over: transport, subprotocol: subprotocol, configuration: configuration,
                            compression: compression, shutdown: shutdown, handler: handler)
    }
}
