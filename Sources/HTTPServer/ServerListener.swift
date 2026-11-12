public import HTTPCore
import Synchronization

/// One listener of a ``Server`` that serves several kinds of listener at once (#0089): byte
/// streams (cleartext TCP, TLS) served through the ``ProtocolRegistry``, and multiplexed
/// connections (QUIC) served by a ``MultiplexedConnectionProtocol`` (HTTP/3).
///
/// ```swift
/// let server = Server(listeners: [
///     .byteStream(try BSDSocketListener(configuration: .init(port: 8080)), name: "http"),
///     .byteStream(name: "https") { bind in
///         try TCPListener(configuration: .init(port: 8443),
///                         tls: TLSConfiguration(identity: identity, alpn: bind.alpnTokens))
///     },
///     .multiplexed(name: "h3", protocol: HTTP3()) { bind in
///         try QUICListener(configuration: .init(port: bind.boundAddresses[1].port,
///                                               quic: QUICConfiguration(alpn: bind.alpnTokens)),
///                          identity: identity)
///     },
/// ], protocols: [HTTP1()]) { app }
/// ```
///
/// Each listener gets its own accept loop (a child of the server's task group) and shares the
/// server's connection limit, drain and ``ShutdownSignal``.
///
/// ## Listeners made at bind time
///
/// The `make` forms create the listener when ``Server/run()`` binds it, in list order, with a
/// ``BindContext``: the addresses bound so far (so a QUIC listener can take the port number a
/// TLS listener on port 0 was given) and the ALPN tokens the listener should offer (the
/// registry's ``ProtocolRegistry/alpnTokens`` for a byte-stream listener, the protocol's own
/// tokens for a multiplexed one). Network.framework fixes a listener's TLS options when it is
/// created, so this is how a TLS listener offers exactly the registered protocols.
public struct ServerListener: Sendable {
    /// What a listener carries.
    public enum Kind: Sendable, Hashable {
        /// Byte-stream connections served through the protocol registry.
        case byteStream
        /// Multiplexed connections served by one ``MultiplexedConnectionProtocol``.
        case multiplexed
    }

    /// What a `make` closure is given when the server binds the listener.
    public struct BindContext: Sendable {
        /// Addresses of the listeners before this one in the list, in order.
        public var boundAddresses: [TransportAddress]
        /// ALPN tokens the listener should offer.
        public var alpnTokens: [String]

        public init(boundAddresses: [TransportAddress], alpnTokens: [String]) {
            self.boundAddresses = boundAddresses
            self.alpnTokens = alpnTokens
        }
    }

    /// A name for logs and ``Server/listenerStatistics`` (`"http"`, `"https"`, `"h3"`).
    public let name: String
    public let kind: Kind
    let storage: Storage

    /// A byte-stream listener created by the caller.
    public static func byteStream<L: TransportListener>(_ listener: L, name: String = "tcp") -> ServerListener {
        ServerListener(name: name, kind: .byteStream, storage: Storage { _ in .byteStream(listener) })
    }

    /// A byte-stream listener created when the server binds it (see ``BindContext``).
    public static func byteStream<L: TransportListener>(
        name: String, _ make: @escaping @Sendable (BindContext) throws -> L
    ) -> ServerListener {
        ServerListener(name: name, kind: .byteStream, storage: Storage { context in
            .byteStream(try make(context))
        })
    }

    /// A multiplexed listener created by the caller, served by `protocol`.
    public static func multiplexed<L: MultiplexedTransportListener, P: MultiplexedConnectionProtocol>(
        _ listener: L, protocol: P, name: String = "quic"
    ) -> ServerListener {
        ServerListener(name: name, kind: .multiplexed, storage: Storage(alpnTokens: P.alpnTokens) { _ in
            .multiplexed(listener, `protocol`)
        })
    }

    /// A multiplexed listener created when the server binds it (see ``BindContext``), served
    /// by `protocol`.
    public static func multiplexed<L: MultiplexedTransportListener, P: MultiplexedConnectionProtocol>(
        name: String, protocol: P, _ make: @escaping @Sendable (BindContext) throws -> L
    ) -> ServerListener {
        ServerListener(name: name, kind: .multiplexed, storage: Storage(alpnTokens: P.alpnTokens) { context in
            .multiplexed(try make(context), `protocol`)
        })
    }

    /// The listener once made.
    enum Bound: Sendable {
        case byteStream(any TransportListener)
        case multiplexed(any MultiplexedTransportListener, any MultiplexedConnectionProtocol)

        func listen() async throws -> TransportAddress {
            switch self {
            case .byteStream(let listener): try await listener.listen()
            case .multiplexed(let listener, _): try await listener.listen()
            }
        }

        func close() async {
            switch self {
            case .byteStream(let listener): await listener.close()
            case .multiplexed(let listener, _): await listener.close()
            }
        }
    }

    /// Makes the listener once; later calls return the same one.
    final class Storage: Sendable {
        /// The ALPN tokens of a multiplexed protocol; `nil` for byte streams (the registry's).
        let alpnTokens: [String]?
        let make: @Sendable (BindContext) throws -> Bound
        let made = Mutex<Bound?>(nil)

        init(alpnTokens: [String]? = nil, make: @escaping @Sendable (BindContext) throws -> Bound) {
            self.alpnTokens = alpnTokens
            self.make = make
        }

        func resolve(boundAddresses: [TransportAddress], registryTokens: [String]) throws -> Bound {
            if let made = made.withLock({ $0 }) { return made }
            let bound = try make(BindContext(boundAddresses: boundAddresses, alpnTokens: alpnTokens ?? registryTokens))
            made.withLock { $0 = bound }
            return bound
        }
    }
}

/// Per-listener counters (``Server/listenerStatistics``).
public struct ListenerStatistics: Sendable, Hashable {
    /// The listener's ``ServerListener/name``.
    public var name: String
    public var kind: ServerListener.Kind
    /// The bound address (`nil` until the server is running).
    public var address: TransportAddress?
    /// Connections admitted from this listener.
    public var accepted: Int
    /// Connections from this listener being served now.
    public var open: Int
    /// Connections from this listener closed unserved because of the connection limit.
    public var refused: Int

    public init(name: String, kind: ServerListener.Kind, address: TransportAddress? = nil,
                accepted: Int = 0, open: Int = 0, refused: Int = 0) {
        self.name = name
        self.kind = kind
        self.address = address
        self.accepted = accepted
        self.open = open
        self.refused = refused
    }
}
