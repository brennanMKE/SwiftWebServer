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

    /// True when an element of the chain reads ``RequestContext/startTime``.
    public static func needsRequestStartTime(_ root: Any) -> Bool {
        var found = false
        visit(root) { if $0 is any RequestStartTimeConsumer { found = true } }
        return found
    }
}
