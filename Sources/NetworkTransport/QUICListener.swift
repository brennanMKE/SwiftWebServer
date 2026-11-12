public import HTTPCore
import Dispatch
import Network
import Synchronization

/// A QUIC listener over `NWListener` with `newConnectionGroupHandler` (issue #0098, ROADMAP §6):
/// one `NWConnectionGroup`, and so one ``QUICConnection``, per QUIC connection. Accepted
/// connections are a demand-driven `AsyncSequence`.
///
/// ## Bounded accept queue
///
/// At most ``Configuration/pendingConnectionLimit`` connections are held that Network.framework
/// has handed over but ``connections`` has not taken (in the handshake, or usable and
/// waiting). A connection beyond that is closed at once and counted in
/// ``rejectedConnectionCount``.
///
/// A connection is handed over once it is usable: its group is ready, or one of its streams
/// is (group state can lag behind streams, spike gotcha 7).
///
/// ## Binding and identity
///
/// Binds with `requiredLocalEndpoint` to ``Configuration/host`` (loopback by default, so no
/// firewall prompt; AGENTS.md). Port 0 picks a free port; ``start()`` returns it. The TLS
/// identity is a ``TLSIdentity`` loaded in memory only.
public final class QUICListener: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Numeric address to bind (`127.0.0.1`, `::1`, or `0.0.0.0` for all interfaces).
        public var host: String
        /// UDP port to bind; 0 picks a free port.
        public var port: UInt16
        /// Most accepted connections held before ``QUICListener/connections`` takes them.
        public var pendingConnectionLimit: Int
        /// Application error code for connections closed by the listener (over the limit, or
        /// not yet taken at ``QUICListener/close()``). Default `H3_NO_ERROR` (0x100).
        public var closeApplicationError: UInt64
        /// Transport settings for every connection, including the accepted ALPN list.
        public var quic: QUICConfiguration

        public init(
            host: String = "127.0.0.1",
            port: UInt16 = 0,
            pendingConnectionLimit: Int = 64,
            closeApplicationError: UInt64 = 0x100,
            quic: QUICConfiguration = QUICConfiguration()
        ) {
            precondition(pendingConnectionLimit > 0, "pendingConnectionLimit must be positive")
            self.host = host
            self.port = port
            self.pendingConnectionLimit = pendingConnectionLimit
            self.closeApplicationError = closeApplicationError
            self.quic = quic
        }
    }

    let listener: NWListener
    let queue: DispatchQueue
    let core: Core
    public let configuration: Configuration

    /// Creates the listener and installs its handlers. Nothing is bound until ``start()``.
    public init(configuration: Configuration = Configuration(), identity: TLSIdentity) throws {
        self.configuration = configuration
        let quic = configuration.quic.makeOptions()
        guard let secIdentity = identity.makeSecIdentity() else { throw TransportError.failed(code: -1) }
        sec_protocol_options_set_local_identity(quic.securityProtocolOptions, secIdentity)
        let parameters = NWParameters(quic: quic)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: configuration.port) ?? .any)
        do {
            listener = try NWListener(using: parameters)
        } catch let error as NWError {
            throw TransportError(error)
        }
        queue = DispatchQueue(label: "sws.quic.listener")
        let core = Core(configuration: configuration)
        self.core = core

        listener.stateUpdateHandler = { [core, weak listener] state in
            core.handle(state, listener: listener)
        }
        listener.newConnectionGroupHandler = { [core] group in
            core.accept(group)
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

    /// The bound UDP port (0 until the listener is ready).
    public var port: UInt16 { core.state.withLock { $0.port } }

    /// Connections closed because the pending-accept queue was full.
    public var rejectedConnectionCount: Int { core.state.withLock { $0.rejected } }

    /// Connections handed over by Network.framework and not yet taken by ``connections``.
    public var pendingConnectionCount: Int { core.state.withLock { $0.pendingCount } }

    /// Accepted, usable connections in the order they became usable. One consumer at a time.
    /// Iteration ends when the listener is closed and throws if it fails.
    public var connections: Connections { Connections(core: core) }

    /// Stops listening, closes connections not yet taken, and ends ``connections``.
    /// Connections already taken are unaffected. Idempotent.
    public func close() async {
        let (pending, first) = core.markClosed()
        for connection in pending {
            await connection.close(applicationError: configuration.closeApplicationError)
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

    public struct Connections: AsyncSequence, Sendable {
        public typealias Element = QUICConnection
        public typealias Failure = any Error
        let core: Core

        public func makeAsyncIterator() -> Iterator { Iterator(core: core) }

        public struct Iterator: AsyncIteratorProtocol {
            public typealias Element = QUICConnection
            public typealias Failure = any Error
            let core: Core

            public mutating func next() async throws -> QUICConnection? {
                try await core.next()
            }

            public mutating func next(isolation actor: isolated (any Actor)?) async throws -> QUICConnection? {
                try await core.next()
            }
        }
    }
}

// MARK: - Core

extension QUICListener {
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
            /// Connections still in the handshake, keyed by identity (holding them keeps them
            /// alive).
            var preparing: [ObjectIdentifier: QUICConnection] = [:]
            var ready: [QUICConnection] = []
            var readyHead = 0
            var consumer: UnsafeContinuation<QUICConnection?, any Error>?
            var rejected = 0
            var closeCalled = false
            var didCancel = false
            var cancelWaiters: [UnsafeContinuation<Void, Never>] = []

            var pendingCount: Int { preparing.count + ready.count - readyHead }

            mutating func popReady() -> QUICConnection? {
                guard readyHead < ready.count else { return nil }
                let connection = ready[readyHead]
                readyHead += 1
                if readyHead == ready.count {
                    ready.removeAll(keepingCapacity: true)
                    readyHead = 0
                } else if readyHead >= 32 && readyHead * 2 >= ready.count {
                    ready.removeFirst(readyHead)
                    readyHead = 0
                }
                return connection
            }
        }

        let state = Mutex(State())
        let configuration: Configuration

        init(configuration: Configuration) {
            self.configuration = configuration
        }

        // MARK: Accept

        /// `newConnectionGroupHandler`: admit the connection into the bounded queue or close it.
        func accept(_ group: NWConnectionGroup) {
            let admitted = state.withLock { state -> Bool in
                guard case .ready = state.phase, !state.closeCalled,
                      state.pendingCount < configuration.pendingConnectionLimit
                else {
                    state.rejected += 1
                    return false
                }
                return true
            }
            let box = SettleBox()
            var onUsable: (@Sendable (Bool) -> Void)?
            if admitted {
                onUsable = { [self] usable in self.settled(box.id, usable: usable) }
            }
            // The peer's address, so requests see it from the start (a proxy's
            // X-Forwarded-For, #0124); streams fill it in later otherwise.
            let remote = (group.descriptor as? NWMultiplexGroup)?.members.first
            let connection = QUICConnection(
                group: group, configuration: configuration.quic, remote: remote, onUsable: onUsable)
            guard admitted else {
                // Start it so it can be closed: an unstarted group cannot send anything.
                connection.startGroup()
                connection.core.abandon()
                return
            }
            let id = ObjectIdentifier(connection)
            box.set(id)
            state.withLock { $0.preparing[id] = connection }
            connection.startGroup()
        }

        /// A connection became usable (hand it over) or ended before that (drop it).
        private func settled(_ id: ObjectIdentifier?, usable: Bool) {
            guard let id else { return }
            let handoff = state.withLock { state -> (UnsafeContinuation<QUICConnection?, any Error>, QUICConnection)? in
                guard let connection = state.preparing.removeValue(forKey: id) else { return nil }
                guard usable, !state.closeCalled else { return nil }
                if let consumer = state.consumer {
                    state.consumer = nil
                    return (consumer, connection)
                }
                state.ready.append(connection)
                return nil
            }
            if let (consumer, connection) = handoff { consumer.resume(returning: connection) }
        }

        // MARK: Consume

        func next() async throws -> QUICConnection? {
            try await withTaskCancellationHandler {
                try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<QUICConnection?, any Error>) in
                    let immediate: Result<QUICConnection?, any Error>? = state.withLock { state in
                        if let connection = state.popReady() { return .success(connection) }
                        if state.closeCalled { return .success(nil) }
                        switch state.phase {
                        case .failed(let error): return .failure(error)
                        case .closed: return .success(nil)
                        case .setup, .ready: break
                        }
                        if Task.isCancelled { return .failure(CancellationError()) }
                        precondition(state.consumer == nil, "QUICListener.connections: concurrent next() calls")
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
        func markClosed() -> ([QUICConnection], Bool) {
            let taken = state.withLock { state -> ([QUICConnection], UnsafeContinuation<QUICConnection?, any Error>?, Bool) in
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
                listener?.newConnectionGroupHandler = nil
            case .setup:
                break
            @unknown default:
                break
            }
        }
    }

    /// Carries a connection's identity into its own usability callback, which is created
    /// before the connection exists.
    final class SettleBox: Sendable {
        private let storage = Mutex<ObjectIdentifier?>(nil)
        var id: ObjectIdentifier? { storage.withLock { $0 } }
        func set(_ id: ObjectIdentifier) { storage.withLock { $0 = id } }
    }
}
