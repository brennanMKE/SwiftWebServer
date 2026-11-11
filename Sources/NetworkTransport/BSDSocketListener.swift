public import HTTPCore
import Darwin
import Synchronization

/// A cleartext TCP listener over a non-blocking POSIX socket and kqueue, whose accepted
/// connections are ``BSDSocketTransport``s (#0113). The alternative to ``TCPListener``,
/// selected by configuration (`sws-bench serve --transport bsd`).
///
/// ## Demand-driven accept
///
/// ``connections`` calls `accept(2)` only when its `next()` is called: it takes a connection
/// the kernel has already completed, or arms a one-shot kqueue wait on the listening socket
/// and suspends. A consumer that stops pulling stops accepting. Connections that arrive
/// meanwhile wait in the kernel's listen queue, bounded by ``Configuration/backlog`` (and by
/// `kern.ipc.somaxconn`); beyond that the kernel stops completing handshakes and clients
/// retry. Nothing is buffered in the process.
///
/// An accepted socket is already established, so a connection is handed over as soon as
/// `accept` returns, with its addresses: no readiness handshake and no queue hop.
///
/// ## Binding
///
/// Binds a numeric ``Configuration/host`` (loopback by default, which never triggers the
/// application firewall prompt; see AGENTS.md). Port 0 picks a free port; ``start()`` returns
/// the actual port.
public final class BSDSocketListener: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Numeric address to bind (`127.0.0.1`, `::1`, or `0.0.0.0` for all interfaces).
        public var host: String
        /// Port to bind; 0 picks a free port.
        public var port: UInt16
        /// The `listen(2)` backlog: most completed connections the kernel holds before
        /// ``BSDSocketListener/connections`` takes them (capped by `kern.ipc.somaxconn`).
        public var backlog: Int32
        /// Socket options for accepted connections. `connectionTimeout` does not apply.
        public var tcp: TCPConfiguration

        public init(
            host: String = "127.0.0.1",
            port: UInt16 = 0,
            backlog: Int32 = 1024,
            tcp: TCPConfiguration = TCPConfiguration()
        ) {
            precondition(backlog > 0, "backlog must be positive")
            self.host = host
            self.port = port
            self.backlog = backlog
            self.tcp = tcp
        }
    }

    struct State {
        var core: SocketCore?
        var port: UInt16 = 0
        var localAddress: TransportAddress?
        var closed = false
        var accepted = 0
    }

    public let configuration: Configuration
    let state = Mutex(State())
    private let address: sockaddr_storage
    /// True when the bind address is a wildcard, so each connection's local address must be
    /// asked for.
    private let isWildcard: Bool

    /// Validates the address. Nothing is bound until ``start()``.
    public init(configuration: Configuration = Configuration()) throws {
        guard let address = BSDSocket.address(host: configuration.host, port: configuration.port) else {
            throw TransportError.failed(code: EINVAL)
        }
        self.configuration = configuration
        self.address = address
        isWildcard = configuration.host == "0.0.0.0" || configuration.host == "::" || configuration.host == "[::]"
    }

    deinit {
        state.withLock { $0.core }?.requestClose(abortive: false)
    }

    /// Binds and starts listening; returns the bound port. Calling it again returns the same
    /// port. Throws ``TransportError/closed`` after ``close()``.
    @discardableResult
    public func start() async throws -> UInt16 {
        try state.withLock { state throws(TransportError) -> UInt16 in
            if state.closed { throw .closed }
            if state.core != nil { return state.port }
            let fd = socket(Int32(address.ss_family), SOCK_STREAM, 0)
            guard fd >= 0 else { throw TransportError(errno: errno) }
            func fail(_ code: Int32) -> TransportError {
                Darwin.close(fd)
                return TransportError(errno: code)
            }
            if configuration.tcp.allowLocalEndpointReuse {
                BSDSocket.setOption(fd, SOL_SOCKET, SO_REUSEADDR, 1)
            }
            if BSDSocket.setNonBlocking(fd) != 0 { throw fail(errno) }
            var bindAddress = address
            let bound = withUnsafePointer(to: &bindAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, BSDSocket.length(of: address)) }
            }
            if bound != 0 { throw fail(errno) }
            if Darwin.listen(fd, configuration.backlog) != 0 { throw fail(errno) }
            guard let local = BSDSocket.localAddress(fd) else { throw fail(errno) }
            state.port = local.port
            state.localAddress = TransportAddress(host: configuration.host, port: local.port)
            state.core = SocketCore(fd: fd, loop: BSDEventLoop.next(), closesOnCancel: false)
            return local.port
        }
    }

    /// The bound port (0 until started).
    public var port: UInt16 { state.withLock { $0.port } }

    /// The bound address (`nil` until started).
    public var localAddress: TransportAddress? { state.withLock { $0.localAddress } }

    /// Connections taken by ``connections`` since start.
    public var acceptedConnectionCount: Int { state.withLock { $0.accepted } }

    /// Accepted connections, in the order the kernel completed them. One consumer at a time.
    /// Iteration ends when the listener is closed.
    public var connections: Connections { Connections(listener: self) }

    /// Stops listening and ends ``connections``. Connections still in the kernel's listen
    /// queue are reset; connections already taken are unaffected. Idempotent.
    public func close() async {
        let core = state.withLock { state -> SocketCore? in
            state.closed = true
            return state.core
        }
        core?.requestClose(abortive: false)
    }

    // MARK: Accept

    func next() async throws -> BSDSocketTransport? {
        let (core, localAddress) = state.withLock { ($0.core, $0.localAddress) }
        guard let core else {
            if state.withLock({ $0.closed }) { return nil }
            throw TransportError.closed   // not started
        }
        while true {
            guard let listenFD = core.acquire() else { return nil }
            var peer = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let fd = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listenFD, $0, &length) }
            }
            let code = errno
            core.release()
            if fd >= 0 {
                let acceptedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                _ = BSDSocket.setNonBlocking(fd)
                BSDSocket.configureConnection(fd, configuration.tcp)
                let info = ConnectionInfo(
                    localAddress: isWildcard ? BSDSocket.localAddress(fd) : localAddress,
                    remoteAddress: BSDSocket.transportAddress(peer))
                state.withLock { $0.accepted += 1 }
                let connectionCore = SocketCore(fd: fd, loop: BSDEventLoop.next(), closesOnCancel: true)
                return BSDSocketTransport(core: connectionCore, info: info, acceptedAt: acceptedAt)
            }
            switch code {
            case EINTR, ECONNABORTED:
                continue
            case EAGAIN:
                switch await core.wait(.read) {
                case .ready: continue
                case .cancelled: throw CancellationError()
                case .closed: return nil
                }
            case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                // Out of descriptors or memory: leave the connection queued and retry shortly
                // rather than failing the listener.
                try await Task.sleep(for: .milliseconds(10))
            default:
                if state.withLock({ $0.closed }) { return nil }
                throw TransportError(errno: code)
            }
        }
    }

    /// A demand-driven sequence of accepted connections: `next()` accepts one or suspends
    /// until one is ready.
    public struct Connections: AsyncSequence, Sendable {
        public typealias Element = BSDSocketTransport
        public typealias Failure = any Error
        let listener: BSDSocketListener

        public func makeAsyncIterator() -> Iterator { Iterator(listener: listener) }

        public struct Iterator: AsyncIteratorProtocol {
            let listener: BSDSocketListener

            public mutating func next() async throws -> BSDSocketTransport? {
                try await listener.next()
            }

            public mutating func next(isolation actor: isolated (any Actor)?) async throws -> BSDSocketTransport? {
                try await listener.next()
            }
        }
    }
}

extension BSDSocketListener: TransportListener {
    /// Binds and starts listening; returns the bound address.
    public func listen() async throws -> TransportAddress {
        let port = try await start()
        return TransportAddress(host: configuration.host, port: port)
    }
}
