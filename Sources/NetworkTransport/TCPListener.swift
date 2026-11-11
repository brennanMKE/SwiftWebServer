public import HTTPCore
import Dispatch
import Network
import Synchronization

/// A TCP listener over `NWListener` whose accepted connections are a demand-driven
/// `AsyncSequence` of ``TCPTransport`` (issue #0078).
///
/// ## Bounded accept queue
///
/// `NWListener` hands over connections as they arrive, whether or not anyone is accepting.
/// The listener keeps at most ``Configuration/pendingConnectionLimit`` connections that have
/// been handed over but not yet taken by ``connections`` (still in the TCP handshake or ready
/// and waiting). A connection beyond that is cancelled at once and counted in
/// ``rejectedConnectionCount``; the peer sees the connection close. Nothing is buffered
/// without bound.
///
/// ## Binding
///
/// The listener binds with `requiredLocalEndpoint` to ``Configuration/host`` (loopback by
/// default, which never triggers the application firewall prompt; see AGENTS.md). Port 0 picks
/// a free port; ``start()`` returns the actual port once the listener is ready.
///
/// Handlers are installed in `init`, before `start(queue:)`.
public final class TCPListener: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Numeric address to bind (`127.0.0.1`, `::1`, or `0.0.0.0` for all interfaces).
        public var host: String
        /// Port to bind; 0 picks a free port.
        public var port: UInt16
        /// Most accepted connections held before ``TCPListener/connections`` takes them.
        public var pendingConnectionLimit: Int
        /// Socket options for accepted connections.
        public var tcp: TCPConfiguration

        public init(
            host: String = "127.0.0.1",
            port: UInt16 = 0,
            pendingConnectionLimit: Int = 64,
            tcp: TCPConfiguration = TCPConfiguration()
        ) {
            precondition(pendingConnectionLimit > 0, "pendingConnectionLimit must be positive")
            self.host = host
            self.port = port
            self.pendingConnectionLimit = pendingConnectionLimit
            self.tcp = tcp
        }
    }

    let listener: NWListener
    let queue: DispatchQueue
    let core: Core
    public let configuration: Configuration

    /// Creates the listener and installs its handlers. Nothing is bound until ``start()``.
    public init(configuration: Configuration = Configuration()) throws {
        self.configuration = configuration
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: configuration.port) ?? .any)
        let parameters = configuration.tcp.makeParameters(localEndpoint: endpoint)
        do {
            listener = try NWListener(using: parameters)
        } catch let error as NWError {
            throw TransportError(error)
        }
        queue = DispatchQueue(label: "sws.tcp.listener")
        let core = Core(limit: configuration.pendingConnectionLimit)
        self.core = core

        listener.stateUpdateHandler = { [core, weak listener] state in
            core.handle(state, listener: listener)
        }
        listener.newConnectionHandler = { [core] connection in
            core.accept(connection)
        }
    }

    deinit {
        listener.cancel()
    }

    /// Binds and starts listening; returns the bound port once the listener is ready.
    @discardableResult
    public func start() async throws -> UInt16 {
        let alreadyStarted = core.state.withLock { state in
            defer { state.started = true }
            return state.started
        }
        if !alreadyStarted { listener.start(queue: queue) }
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = core.state.withLock { state in
                    switch state.phase {
                    case .ready: return .success(())
                    case .failed(let error): return .failure(error)
                    case .closed: return .failure(TransportError.closed)
                    case .setup:
                        if Task.isCancelled { return .failure(CancellationError()) }
                        state.readyWaiters.append(continuation)
                        return nil
                    }
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            listener.cancel()
        }
        return core.state.withLock { $0.port }
    }

    /// The bound port (0 until the listener is ready).
    public var port: UInt16 { core.state.withLock { $0.port } }

    /// The bound address (`nil` until the listener is ready).
    public var localAddress: TransportAddress? {
        let port = self.port
        return port == 0 ? nil : TransportAddress(host: configuration.host, port: port)
    }

    /// Connections cancelled because the pending-accept queue was full.
    public var rejectedConnectionCount: Int { core.state.withLock { $0.rejected } }

    /// Connections handed over by Network.framework and not yet taken by ``connections``.
    public var pendingConnectionCount: Int {
        core.state.withLock { $0.pendingCount }
    }

    /// Accepted connections, ready to use, in arrival order. One consumer at a time. Iteration
    /// ends when the listener is closed and throws if it fails.
    public var connections: Connections { Connections(core: core) }

    /// Stops listening, cancels connections not yet taken, and ends ``connections``.
    /// Connections already taken are unaffected. Idempotent.
    public func close() async {
        let (pending, first) = core.markClosed()
        for transport in pending {
            await transport.close(.shutdown)
        }
        guard first else { return }
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let done = core.state.withLock { state -> Bool in
                if state.didCancel { return true }
                state.cancelWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() } else { listener.cancel() }
        }
    }

    // MARK: Connections

    /// A demand-driven sequence of accepted connections: `next()` takes one from the bounded
    /// pending queue or suspends until one is ready.
    public struct Connections: AsyncSequence, Sendable {
        public typealias Element = TCPTransport
        public typealias Failure = any Error
        let core: Core

        public func makeAsyncIterator() -> Iterator { Iterator(core: core) }

        public struct Iterator: AsyncIteratorProtocol {
            let core: Core

            public mutating func next() async throws -> TCPTransport? {
                try await core.next()
            }

            public mutating func next(isolation actor: isolated (any Actor)?) async throws -> TCPTransport? {
                try await core.next()
            }
        }
    }
}

// MARK: - Core

extension TCPListener {
    enum Phase {
        case setup
        case ready
        case failed(TransportError)
        case closed
    }

    final class Core: Sendable {
        struct State {
            var phase: Phase = .setup
            var started = false
            var port: UInt16 = 0
            var readyWaiters: [UnsafeContinuation<Void, any Error>] = []
            /// Accepted connections still in the handshake, keyed by identity (holding them
            /// keeps them alive).
            var preparing: [ObjectIdentifier: TCPTransport] = [:]
            /// Ready connections not yet taken; `ready[readyHead...]` is the queue.
            var ready: [TCPTransport] = []
            var readyHead = 0
            var consumer: UnsafeContinuation<TCPTransport?, any Error>?
            var rejected = 0
            var closeCalled = false
            var didCancel = false
            var cancelWaiters: [UnsafeContinuation<Void, Never>] = []

            var pendingCount: Int { preparing.count + ready.count - readyHead }

            mutating func popReady() -> TCPTransport? {
                guard readyHead < ready.count else { return nil }
                let transport = ready[readyHead]
                readyHead += 1
                if readyHead == ready.count {
                    ready.removeAll(keepingCapacity: true)
                    readyHead = 0
                } else if readyHead >= 32 && readyHead * 2 >= ready.count {
                    ready.removeFirst(readyHead)
                    readyHead = 0
                }
                return transport
            }
        }

        let state: Mutex<State>
        let limit: Int

        init(limit: Int) {
            self.limit = limit
            state = Mutex(State())
        }

        // MARK: Accept

        /// `newConnectionHandler`: admit the connection into the bounded queue or cancel it.
        func accept(_ connection: NWConnection) {
            let handedOverAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let admitted = state.withLock { state -> Bool in
                guard case .ready = state.phase, !state.closeCalled, state.pendingCount < limit else {
                    state.rejected += 1
                    return false
                }
                return true
            }
            guard admitted else {
                connection.cancel()
                return
            }
            let box = SettleBox()
            let transport = TCPTransport(connection: connection, failsWhileWaiting: false) { [self] ready in
                self.settled(box.id, ready: ready)
            }
            let id = ObjectIdentifier(transport)
            box.set(id)
            transport.core.state.withLock { $0.handedOverAt = handedOverAt }
            state.withLock { $0.preparing[id] = transport }
            transport.startConnection()
        }

        /// An accepted connection became ready (hand it over) or failed (drop it).
        private func settled(_ id: ObjectIdentifier?, ready: Bool) {
            guard let id else { return }
            let handoff = state.withLock { state -> (UnsafeContinuation<TCPTransport?, any Error>, TCPTransport)? in
                guard let transport = state.preparing.removeValue(forKey: id) else { return nil }
                guard ready, !state.closeCalled else { return nil }
                if let consumer = state.consumer {
                    state.consumer = nil
                    return (consumer, transport)
                }
                state.ready.append(transport)
                return nil
            }
            if let (consumer, transport) = handoff { consumer.resume(returning: transport) }
        }

        // MARK: Consume

        func next() async throws -> TCPTransport? {
            try await withTaskCancellationHandler {
                try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<TCPTransport?, any Error>) in
                    let immediate: Result<TCPTransport?, any Error>? = state.withLock { state in
                        if let transport = state.popReady() { return .success(transport) }
                        if state.closeCalled { return .success(nil) }
                        switch state.phase {
                        case .failed(let error): return .failure(error)
                        case .closed: return .success(nil)
                        case .setup, .ready: break
                        }
                        if Task.isCancelled { return .failure(CancellationError()) }
                        precondition(state.consumer == nil, "TCPListener.connections: concurrent next() calls")
                        state.consumer = continuation
                        return nil
                    }
                    if let immediate { continuation.resume(with: immediate) }
                }
            } onCancel: {
                let consumer = state.withLock { state in
                    defer { state.consumer = nil }
                    return state.consumer
                }
                consumer?.resume(throwing: CancellationError())
            }
        }

        // MARK: Close

        /// Returns the connections not yet taken and whether this was the first close.
        func markClosed() -> ([TCPTransport], Bool) {
            let taken = state.withLock { state -> ([TCPTransport], UnsafeContinuation<TCPTransport?, any Error>?, Bool) in
                let first = !state.closeCalled
                state.closeCalled = true
                var pending = Array(state.preparing.values)
                pending += state.ready[state.readyHead...]
                state.preparing = [:]
                state.ready = []
                state.readyHead = 0
                defer { state.consumer = nil }
                return (pending, state.consumer, first)
            }
            taken.1?.resume(returning: nil)
            return (taken.0, taken.2)
        }

        // MARK: State

        func handle(_ newState: NWListener.State, listener: NWListener?) {
            switch newState {
            case .ready:
                let port = listener?.port?.rawValue ?? 0
                let waiters = state.withLock { state in
                    if case .setup = state.phase { state.phase = .ready }
                    state.port = port
                    defer { state.readyWaiters = [] }
                    return state.readyWaiters
                }
                for waiter in waiters { waiter.resume() }
            case .waiting(let error), .failed(let error):
                // A listener that cannot bind (address in use, not permitted) waits or fails;
                // either way it is not serving, so report the failure and stop.
                let mapped = TransportError(error)
                let (waiters, consumer) = state.withLock { state in
                    state.phase = .failed(mapped)
                    defer { state.readyWaiters = []; state.consumer = nil }
                    return (state.readyWaiters, state.consumer)
                }
                for waiter in waiters { waiter.resume(throwing: mapped) }
                consumer?.resume(throwing: mapped)
                listener?.cancel()
            case .cancelled:
                let (readyWaiters, consumer, cancelWaiters) = state.withLock { state in
                    if case .failed = state.phase {} else { state.phase = .closed }
                    state.didCancel = true
                    defer { state.readyWaiters = []; state.consumer = nil; state.cancelWaiters = [] }
                    return (state.readyWaiters, state.consumer, state.cancelWaiters)
                }
                for waiter in readyWaiters { waiter.resume(throwing: TransportError.closed) }
                consumer?.resume(returning: nil)
                for waiter in cancelWaiters { waiter.resume() }
                listener?.stateUpdateHandler = nil
                listener?.newConnectionHandler = nil
            case .setup:
                break
            @unknown default:
                break
            }
        }
    }

    /// Carries a transport's identity into its own settle callback, which is created before
    /// the transport exists. Written once, before the connection starts.
    final class SettleBox: Sendable {
        private let storage = Mutex<ObjectIdentifier?>(nil)
        var id: ObjectIdentifier? { storage.withLock { $0 } }
        func set(_ id: ObjectIdentifier) { storage.withLock { $0 = id } }
    }
}
