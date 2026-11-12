/// A component with a lifetime of its own (docs/ROADMAP.md §5.2): background work such as
/// flushing an access log, evicting a cache or scraping metrics (#0083).
///
/// The server runs each registered component as a child task of its task tree once its
/// listeners are bound, and cancels the components after the last connection has closed (or
/// was cancelled at the drain deadline), so a component can flush what the final requests
/// produced. ``run(server:)`` should run until cancelled; returning early is allowed and just
/// ends that component. A thrown error other than `CancellationError` shuts the server down,
/// and `Server.run()` rethrows it after draining.
///
/// Register a component by passing it to the server's `components:` parameter, or by putting a
/// type that is both an ``HTTPMiddleware`` (or ``HTTPHandler``) and a `ServerComponent` in the
/// middleware builder: the server finds those in the chain at startup. A component inside an
/// `if` whose condition was false is not in the chain and is not run.
public protocol ServerComponent: Sendable {
    func run(server: ServerHandle) async throws
}

/// What a ``ServerComponent`` may know about and do to the server that runs it.
public struct ServerHandle: Sendable {
    /// The addresses the server's listeners are bound to.
    public let localAddresses: [TransportAddress]
    /// Triggers when the server starts draining (the components are cancelled later, once the
    /// connections are gone).
    public let draining: ShutdownSignal
    let shutdownRequester: @Sendable () -> Void

    public init(
        localAddresses: [TransportAddress],
        draining: ShutdownSignal,
        requestShutdown: @escaping @Sendable () -> Void
    ) {
        self.localAddresses = localAddresses
        self.draining = draining
        self.shutdownRequester = requestShutdown
    }

    /// Starts a graceful shutdown of the server. Returns at once.
    public func requestShutdown() {
        shutdownRequester()
    }
}

/// A chain element with per-connection state (#0090): an access log's line buffer and
/// metric counters, kept per connection so the request path shares nothing between
/// connections (docs/ROADMAP.md §7, "shard, don't share").
///
/// Whoever runs a connection (`Server` in HTTPServer, or a benchmark driving a
/// runner directly) calls ``connectionWillStart(_:)`` before the protocol runs and
/// ``connectionDidEnd(_:)`` after it returned, through ``ConnectionObservers``. In
/// `connectionWillStart` the observer sets typed values on `connection.requestContext`
/// (``RequestContext/subscript(_:)``); every request on the connection then sees them in its
/// ``RequestContext``, and `connectionDidEnd` reads them back.
///
/// Requests on one connection run one at a time for HTTP/1.1 but may overlap for multiplexed
/// protocols (HTTP/2, HTTP/3), so per-connection state must tolerate concurrent requests.
///
/// The server finds observers in the chain (and in its `components:`) at startup, like
/// ``ServerComponent``s. With none, a connection pays one empty-array check.
public protocol ConnectionObserver: Sendable {
    /// Called once per connection, before its first request.
    func connectionWillStart(_ connection: inout ConnectionContext)
    /// Called once per connection, after its last response was handed to the transport.
    func connectionDidEnd(_ connection: ConnectionContext)
}

/// The ``ConnectionObserver``s of a chain, found once at startup.
public struct ConnectionObservers: Sendable {
    public let observers: [any ConnectionObserver]

    public init(_ observers: [any ConnectionObserver] = []) {
        self.observers = observers
    }

    /// The observers in `chain` (see ``MiddlewareChainInspector/connectionObservers(in:)``).
    public init(chain: Any) {
        self.init(MiddlewareChainInspector.connectionObservers(in: chain))
    }

    @inlinable public var isEmpty: Bool { observers.isEmpty }

    /// Lets every observer set its connection-scoped values, in chain order.
    public func connectionWillStart(_ connection: inout ConnectionContext) {
        for observer in observers { observer.connectionWillStart(&connection) }
    }

    /// Tells every observer the connection ended, in reverse chain order.
    public func connectionDidEnd(_ connection: ConnectionContext) {
        for observer in observers.reversed() { observer.connectionDidEnd(connection) }
    }
}

/// A chain element that answers extended CONNECT requests (RFC 8441 over HTTP/2, RFC 9220
/// over HTTP/3) for some `:protocol` values with a `.tunnel` response, such as the WebSocket
/// component. Protocol runners find it with
/// ``MiddlewareChainInspector/extendedConnectProtocols(in:)`` and only then advertise
/// `SETTINGS_ENABLE_CONNECT_PROTOCOL`, so a server without one never receives `:protocol`.
public protocol ExtendedConnectProvider {
    /// The `:protocol` values served (`["websocket"]`).
    var extendedConnectProtocols: [String] { get }
}

/// A builder type that holds other chain elements: every composition type of
/// ``MiddlewareBuilder`` conforms, so the server can inspect a built chain once at startup
/// (find its ``ServerComponent``s and whether it has a ``RequestStartTimeConsumer``).
public protocol MiddlewareChainContainer {
    /// Calls `body` with each direct child element present in the chain (an absent optional
    /// component is not a child).
    func forEachChainElement(_ body: (Any) -> Void)
}

/// Startup-time inspection of a chain built by ``MiddlewareBuilder``. It uses dynamic casts,
/// so it is never for the request path.
public enum MiddlewareChainInspector {
    /// Calls `body` with `root` and then every element nested in it, outermost first.
    public static func visit(_ root: Any, _ body: (Any) -> Void) {
        body(root)
        if let container = root as? any MiddlewareChainContainer {
            container.forEachChainElement { visit($0, body) }
        }
    }

    /// The ``ServerComponent``s in the chain, outermost first.
    public static func serverComponents(in root: Any) -> [any ServerComponent] {
        var components: [any ServerComponent] = []
        visit(root) { if let component = $0 as? any ServerComponent { components.append(component) } }
        return components
    }

    /// The ``ConnectionObserver``s in the chain, outermost first.
    public static func connectionObservers(in root: Any) -> [any ConnectionObserver] {
        var observers: [any ConnectionObserver] = []
        visit(root) { if let observer = $0 as? any ConnectionObserver { observers.append(observer) } }
        return observers
    }

    /// The extended CONNECT protocols (RFC 8441 / RFC 9220 `:protocol` values) that elements
    /// of the chain serve, in chain order. HTTP/3 advertises `SETTINGS_ENABLE_CONNECT_PROTOCOL`
    /// when this is not empty (#0111).
    public static func extendedConnectProtocols(in root: Any) -> [String] {
        var protocols: [String] = []
        visit(root) { if let provider = $0 as? any ExtendedConnectProvider { protocols += provider.extendedConnectProtocols } }
        return protocols
    }

    /// True when an element of the chain reads ``RequestContext/startTime``.
    public static func needsRequestStartTime(_ root: Any) -> Bool {
        var found = false
        visit(root) { if $0 is any RequestStartTimeConsumer { found = true } }
        return found
    }
}
