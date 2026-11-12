/// Settings a ``Server`` captures once, at construction (docs/ROADMAP.md §3: an immutable
/// `Sendable` value, never an actor hop per request).
public struct ServerConfiguration: Sendable, Hashable {
    /// What happens to a connection that arrives while ``maxConnections`` are open.
    public enum ConnectionLimitPolicy: Sendable, Hashable {
        /// Stop pulling from the listener until a connection closes. New connections wait in
        /// the listener's bounded pending queue; the listener refuses those beyond its bound.
        case backpressure
        /// Keep accepting and close each connection over the limit at once, without starting
        /// any work for it.
        case refuse
    }

    /// Most connections served at once (#0024).
    public var maxConnections: Int
    /// Behaviour at ``maxConnections``.
    public var connectionLimitPolicy: ConnectionLimitPolicy
    /// How long a graceful shutdown waits for open connections before cancelling them.
    /// `nil` waits indefinitely.
    public var drainTimeout: Duration?
    /// How long a cleartext connection may take to send enough bytes for the protocol registry
    /// to pick a protocol, when more than one protocol is registered (#0088). `nil` waits
    /// indefinitely. Defaults to the HTTP/1.1 header timeout.
    public var sniffTimeout: Duration?

    public init(
        maxConnections: Int = 1024,
        connectionLimitPolicy: ConnectionLimitPolicy = .backpressure,
        drainTimeout: Duration? = .seconds(10),
        sniffTimeout: Duration? = .seconds(10)
    ) {
        self.maxConnections = maxConnections
        self.connectionLimitPolicy = connectionLimitPolicy
        self.drainTimeout = drainTimeout
        self.sniffTimeout = sniffTimeout
    }

    /// Throws ``ServerError/invalidConfiguration(_:)`` when a value is out of range.
    public func validate() throws(ServerError) {
        guard maxConnections > 0 else {
            throw .invalidConfiguration("maxConnections must be positive (got \(maxConnections))")
        }
        if let drainTimeout, drainTimeout < .zero {
            throw .invalidConfiguration("drainTimeout must not be negative")
        }
        if let sniffTimeout, sniffTimeout <= .zero {
            throw .invalidConfiguration("sniffTimeout must be positive")
        }
    }
}

/// Errors thrown by ``Server``.
public enum ServerError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A configuration value is out of range.
    case invalidConfiguration(String)
    /// `run()` was called on a server that already ran (or is running).
    case alreadyStarted
    /// The server has no protocols to serve connections with.
    case noProtocols

    public var description: String {
        switch self {
        case .invalidConfiguration(let message): "invalid configuration: \(message)"
        case .alreadyStarted: "the server was already started"
        case .noProtocols: "no connection protocols are registered"
        }
    }
}
