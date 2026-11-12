public import HTTPCore
import Synchronization

/// An HTTP server: listeners, a protocol registry and a handler, driven by a
/// ``ServerLifecycle`` (#0079; replaces the legacy singleton, #0002).
///
/// ```swift
/// let server = Server(configuration: config, listeners: [try TCPListener()], protocols: [HTTP1()]) {
///     AccessLog()
///     if config.compression { Compression() }
///     StaticFiles(root: publicURL)
/// }
/// try await server.run()          // returns after a graceful shutdown
/// ```
///
/// The trailing closure is a ``MiddlewareBuilder``: `Handler` is the chain's nested generic
/// type, so components left out by an `if` are not in it (#0083). `handler: app` is the same
/// as a builder with one element.
///
/// ## Components
///
/// ``ServerComponent``s (background work: log flushing, cache eviction) come from the
/// `components:` parameter and from the builder chain (a middleware that is also a component).
/// They run as child tasks once the listeners are bound and are cancelled after the last
/// connection closes. A component that throws shuts the server down, and `run()` rethrows the
/// error after draining.
///
/// ## Task tree
///
/// `run()` is the root: one child task per component, one per listener, and under each listener
/// one child task per connection, all in discarding task groups (no unstructured tasks, #0029). Cancelling the
/// task that calls `run()` cancels the whole tree.
///
/// ## Connection limit
///
/// At most ``ServerConfiguration/maxConnections`` connections are served at once (#0024). With
/// ``ServerConfiguration/ConnectionLimitPolicy/backpressure`` the accept loop stops pulling from
/// the listener until a connection closes; with ``ServerConfiguration/ConnectionLimitPolicy/refuse``
/// it closes the extra connection at once. Neither starts work for a connection over the limit.
///
/// ## Shutdown
///
/// ``requestShutdown()`` (synchronous, safe from a signal handler) or ``shutdown()`` moves the
/// lifecycle to draining: listeners stop accepting, ``ConnectionContext/shutdown`` triggers on
/// every connection, and the server waits up to ``ServerConfiguration/drainTimeout`` for
/// connections to finish before cancelling them. A shutdown before or during startup is never
/// lost (#0005). Startup failures, such as a port in use, throw out of `run()` (#0004).
///
/// ## Several kinds of listener
///
/// `Server<SomeListener, Handler>` serves listeners of one byte-stream type. A
/// `Server<ServerListener, Handler>` (built from ``ServerListener`` values) serves any mix:
/// cleartext and TLS byte streams through the registry, and QUIC connections through a
/// ``MultiplexedConnectionProtocol`` such as HTTP/3 (#0089). Listeners bind in order; if one
/// fails, those already bound are closed and `run()` throws. Every listener shares the
/// connection limit, the drain and the ``ShutdownSignal``, so a shutdown also sends HTTP/3
/// GOAWAY. ``listenerStatistics`` has per-listener counts.
public final class Server<Listener, Handler: HTTPHandler>: Sendable {
    public let configuration: ServerConfiguration
    public let protocols: ProtocolRegistry
    let listeners: [ServerListener]
    let handler: Handler
    /// Background components: the `components:` argument, then those found in the chain.
    let components: [any ServerComponent]
    /// The chain reads ``RequestContext/startTime``, so the runners stamp each request.
    let recordsRequestStartTime: Bool

    /// Triggers when draining starts; handed to every connection.
    let shutdownSignal = ShutdownSignal()
    /// Triggers when the listeners have stopped and the last connection closed while draining.
    let drained = ShutdownSignal()
    /// Triggers when `run()` is about to return (or the server stopped before it ran).
    let finished = ShutdownSignal()

    struct State {
        var lifecycle = ServerLifecycle()
        /// Connection slots in use: connections being served plus ``reserved``.
        var open = 0
        /// Slots reserved by accept loops waiting on the listener (backpressure).
        var reserved = 0
        var activeAcceptLoops = 0
        var addresses: [TransportAddress] = []
        var startupError: (any Error)?
        var runError: (any Error)?
        var nextWaiterID: UInt64 = 0
        var capacityWaiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
        var readyWaiters: [CheckedContinuation<[TransportAddress], any Error>] = []
        var accepted = 0
        var refused = 0
        var peakOpen = 0
        var runCalled = false
        var perListener: [ListenerStatistics] = []
    }

    let state = Mutex(State())

    init(
        configuration: ServerConfiguration,
        entries: [ServerListener],
        protocols: [any ConnectionProtocol],
        components: [any ServerComponent],
        handler: Handler
    ) {
        self.configuration = configuration
        self.listeners = entries
        self.protocols = ProtocolRegistry(protocols, sniffTimeout: configuration.sniffTimeout)
        self.handler = handler
        self.components = components + MiddlewareChainInspector.serverComponents(in: handler)
        self.recordsRequestStartTime = MiddlewareChainInspector.needsRequestStartTime(handler)
        state.withLock { state in
            state.perListener = entries.map { ListenerStatistics(name: $0.name, kind: $0.kind) }
        }
    }

    // MARK: Observation

    /// The current lifecycle state.
    public var lifecycleState: ServerLifecycle.State { state.withLock { $0.lifecycle.state } }

    /// Bound listener addresses (empty until running).
    public var localAddresses: [TransportAddress] { state.withLock { $0.addresses } }

    /// Connections currently being served.
    public var openConnectionCount: Int { state.withLock { $0.open - $0.reserved } }

    /// Connections admitted since start.
    public var acceptedConnectionCount: Int { state.withLock { $0.accepted } }

    /// Connections closed unserved because of the connection limit (``ServerConfiguration/ConnectionLimitPolicy/refuse``).
    public var refusedConnectionCount: Int { state.withLock { $0.refused } }

    /// The most connections open at once.
    public var peakConnectionCount: Int { state.withLock { $0.peakOpen } }

    /// Per-listener counts, in listener order (#0089). The connection limit is shared, so the
    /// `open` counts add up to ``openConnectionCount``.
    public var listenerStatistics: [ListenerStatistics] { state.withLock { $0.perListener } }

    /// Suspends until the server is running and returns the bound addresses. Throws the
    /// startup error if startup fails, or `CancellationError` if the server stops first.
    public func waitUntilRunning() async throws -> [TransportAddress] {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = state.withLock { state -> Result<[TransportAddress], any Error>? in
                switch state.lifecycle.state {
                case .running, .draining: return .success(state.addresses)
                case .failed: return .failure(state.startupError ?? CancellationError())
                case .stopped: return state.addresses.isEmpty ? .failure(CancellationError()) : .success(state.addresses)
                case .idle, .starting:
                    state.readyWaiters.append(continuation)
                    return nil
                }
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    // MARK: Shutdown

    /// Starts a graceful shutdown and returns at once. Synchronous and non-suspending, so a
    /// `DispatchSource` signal handler can call it. Repeated calls are no-ops.
    public func requestShutdown() {
        let deadline = configuration.drainTimeout.map { Deadline.after($0) } ?? .never
        let action = state.withLock { $0.lifecycle.handle(.shutdownRequested(deadline: deadline)) }
        perform(action)
    }

    /// Starts a graceful shutdown and returns when the server has stopped (immediately if it
    /// never ran).
    public func shutdown() async {
        requestShutdown()
        await finished.wait()
    }

    private func perform(_ action: ServerLifecycle.Action) {
        switch action {
        case .finish:
            // Stopped before run(): nothing to tear down.
            failReadyWaiters(CancellationError())
            finished.trigger()
        case .abandonStartup:
            // run() closes the listeners once binding returns.
            shutdownSignal.trigger()
        case .drain:
            shutdownSignal.trigger()
            wakeCapacityWaiters()
        case .none, .startListeners, .rejectStart, .acceptConnections, .failStartup, .cancelConnections:
            break
        }
    }

    // MARK: Run

    /// Binds the listeners and serves connections until a shutdown completes.
    ///
    /// Throws when the configuration is invalid, a listener cannot bind, the server already
    /// ran, or a listener fails while running (after draining). Returns normally after a
    /// graceful shutdown, including one requested before `run()` was called.
    public func run() async throws {
        let (action, firstCall) = state.withLock { state in
            defer { state.runCalled = true }
            return (state.lifecycle.handle(.start), !state.runCalled)
        }
        switch action {
        case .startListeners:
            break
        case .rejectStart where firstCall && lifecycleState == .stopped:
            return   // shutdown requested before run (#0005): return at once
        default:
            throw ServerError.alreadyStarted
        }
        defer { finished.trigger() }

        do {
            try configuration.validate()
            let needsRegistry = listeners.contains { $0.kind == .byteStream }
            guard !needsRegistry || !protocols.protocols.isEmpty else { throw ServerError.noProtocols }
        } catch {
            _ = state.withLock { $0.lifecycle.handle(.listenerFailed) }
            failStartup(error)
            throw error
        }

        var addresses: [TransportAddress] = []
        var bound: [ServerListener.Bound] = []
        do {
            let registryTokens = protocols.alpnTokens
            for entry in listeners {
                if shutdownSignal.isTriggered { break }
                let listener = try entry.storage.resolve(boundAddresses: addresses, registryTokens: registryTokens)
                bound.append(listener)
                addresses.append(try await listener.listen())
            }
        } catch {
            for listener in bound { await listener.close() }
            let failure = state.withLock { $0.lifecycle.handle(.listenerFailed) }
            if failure == .failStartup {
                failStartup(error)
                throw error
            }
            failReadyWaiters(CancellationError())
            return   // shutdown requested while binding
        }

        let ready = state.withLock { state -> ServerLifecycle.Action in
            let action = state.lifecycle.handle(.listenerReady)
            if action == .acceptConnections {
                state.addresses = addresses
                for index in addresses.indices { state.perListener[index].address = addresses[index] }
            }
            return action
        }
        guard ready == .acceptConnections else {
            for listener in bound { await listener.close() }
            failReadyWaiters(CancellationError())
            return   // shutdown requested while binding
        }
        let waiters = state.withLock { state in
            defer { state.readyWaiters = [] }
            return state.readyWaiters
        }
        for waiter in waiters { waiter.resume(returning: addresses) }

        await serve(addresses: addresses, listeners: bound)

        if let error = state.withLock({ $0.runError }) { throw error }
    }

    private func failStartup(_ error: any Error) {
        state.withLock { $0.startupError = error }
        failReadyWaiters(error)
    }

    private func failReadyWaiters(_ error: any Error) {
        let waiters = state.withLock { state in
            defer { state.readyWaiters = [] }
            return state.readyWaiters
        }
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    /// The running phase: accept on every listener until shutdown, drain, then cancel what is
    /// left at the deadline.
    private func serve(addresses: [TransportAddress], listeners: [ServerListener.Bound]) async {
        guard !components.isEmpty else { return await serveConnections(listeners) }
        let handle = ServerHandle(localAddresses: addresses, draining: shutdownSignal) { [weak self] in
            self?.requestShutdown()
        }
        await withDiscardingTaskGroup { group in
            for component in components {
                group.addTask { await self.runComponent(component, handle: handle) }
            }
            await serveConnections(listeners)
            // The connections are gone: stop the components (they may flush first).
            group.cancelAll()
        }
    }

    private func runComponent(_ component: any ServerComponent, handle: ServerHandle) async {
        do {
            try await component.run(server: handle)
        } catch is CancellationError {
        } catch {
            failedWhileRunning(error)
        }
    }

    private func serveConnections(_ listeners: [ServerListener.Bound]) async {
        state.withLock { $0.activeAcceptLoops = listeners.count }
        await withDiscardingTaskGroup { group in
            for (index, listener) in listeners.enumerated() {
                switch listener {
                case .byteStream(let listener):
                    group.addTask { await self.acceptByteStreams(listener, index: index) }
                case .multiplexed(let listener, let proto):
                    group.addTask { await self.acceptMultiplexed(listener, protocol: proto, index: index) }
                }
            }

            await shutdownSignal.wait()
            if !shutdownSignal.isTriggered {
                // run() was cancelled: stop with no grace period.
                let action = state.withLock { $0.lifecycle.handle(.shutdownRequested(deadline: Deadline(.now))) }
                perform(action)
            }

            for listener in listeners { await listener.close() }
            checkDrained()

            let deadline = state.withLock { $0.lifecycle.drainDeadline }
            if let deadline, !(await waitForDrain(until: deadline)) {
                let action = state.withLock { $0.lifecycle.handle(.drainDeadlineReached) }
                if action == .cancelConnections { group.cancelAll() }
            }
        }
    }

    /// Waits until ``drained`` triggers (true) or `deadline` passes (false).
    private func waitForDrain(until deadline: Deadline) async -> Bool {
        if drained.isTriggered { return true }
        guard let instant = deadline.instant else {
            await drained.wait()
            return drained.isTriggered
        }
        let drained = self.drained
        return await withTaskGroup(of: Bool.self) { race in
            race.addTask {
                await drained.wait()
                return drained.isTriggered
            }
            race.addTask {
                try? await Task.sleep(until: instant, clock: .continuous)
                return false
            }
            let first = await race.next() ?? false
            race.cancelAll()
            return first || drained.isTriggered
        }
    }

    // MARK: Accept

    private func acceptByteStreams<L: TransportListener>(_ listener: L, index: Int) async {
        await acceptLoop(listener.connections, index: index,
                         refuse: { transport in await transport.close(.shutdown) },
                         serve: { transport in await self.serveConnection(transport) })
    }

    private func acceptMultiplexed<L: MultiplexedTransportListener, P: MultiplexedConnectionProtocol>(
        _ listener: L, protocol proto: P, index: Int
    ) async {
        await acceptLoop(listener.connections, index: index,
                         refuse: { connection in await listener.refuse(connection) },
                         serve: { connection in
                             let context = ConnectionContext(info: listener.connectionInfo(connection),
                                                             shutdown: self.shutdownSignal,
                                                             recordsRequestStartTime: self.recordsRequestStartTime)
                             await proto.run(connection, handler: self.handler, context: context)
                         })
    }

    /// Takes connections from one listener and serves each in a child task, within the
    /// shared connection limit.
    private func acceptLoop<Connections: AsyncSequence>(
        _ sequence: Connections, index: Int,
        refuse: @escaping @Sendable (Connections.Element) async -> Void,
        serve: @escaping @Sendable (Connections.Element) async -> Void
    ) async where Connections.Element: Sendable, Connections.Failure == any Error {
        await withDiscardingTaskGroup { connections in
            var iterator = sequence.makeAsyncIterator()
            accepting: while true {
                let reserved: Bool
                switch configuration.connectionLimitPolicy {
                case .backpressure:
                    // Stop pulling from the listener while at the limit (accept backpressure).
                    guard await reserveCapacity() else { break accepting }
                    reserved = true
                case .refuse:
                    reserved = false
                }

                let next: Connections.Element?
                do {
                    next = try await iterator.next()
                } catch {
                    if reserved { releaseSlot(reservation: true) }
                    if !(error is CancellationError) { failedWhileRunning(error) }
                    break accepting
                }
                guard let connection = next else {
                    if reserved { releaseSlot(reservation: true) }
                    break accepting
                }

                let admitted = state.withLock { state -> Bool in
                    guard state.lifecycle.isRunning else { return false }
                    if reserved {
                        state.reserved -= 1
                    } else {
                        guard state.open < configuration.maxConnections else {
                            state.refused += 1
                            state.perListener[index].refused += 1
                            return false
                        }
                        state.open += 1
                    }
                    state.accepted += 1
                    state.perListener[index].accepted += 1
                    state.perListener[index].open += 1
                    state.peakOpen = max(state.peakOpen, state.open - state.reserved)
                    return true
                }
                guard admitted else {
                    if reserved { releaseSlot(reservation: true) }
                    await refuse(connection)
                    continue
                }
                connections.addTask {
                    await serve(connection)
                    self.releaseSlot(listener: index)
                }
            }
        }
        let allEnded = state.withLock { state in
            state.activeAcceptLoops -= 1
            return state.activeAcceptLoops == 0 && state.lifecycle.isRunning
        }
        // Every listener stopped on its own: nothing more can be served.
        if allEnded { requestShutdown() }
        checkDrained()
    }

    private func serveConnection<T: ByteStreamTransport>(_ transport: T) async {
        let context = ConnectionContext(info: transport.info, shutdown: shutdownSignal,
                                        recordsRequestStartTime: recordsRequestStartTime)
        await protocols.serve(transport, handler: handler, context: context)
        await transport.close(.normal)
    }

    /// A listener or component failed while running: remember the first error, then shut down.
    private func failedWhileRunning(_ error: any Error) {
        state.withLock { state in
            if state.runError == nil { state.runError = error }
        }
        requestShutdown()
    }

    // MARK: Capacity

    /// Reserves a connection slot, waiting while ``ServerConfiguration/maxConnections`` are
    /// open. Returns false when the server stops running or the task is cancelled.
    private func reserveCapacity() async -> Bool {
        let id = state.withLock { state -> UInt64 in
            defer { state.nextWaiterID &+= 1 }
            return state.nextWaiterID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let immediate = state.withLock { state -> Bool? in
                    guard state.lifecycle.isRunning, !Task.isCancelled else { return false }
                    if state.open < configuration.maxConnections {
                        state.open += 1
                        state.reserved += 1
                        return true
                    }
                    state.capacityWaiters[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.capacityWaiters.removeValue(forKey: id) }
            waiter?.resume(returning: false)
        }
    }

    /// Frees a slot (a connection closed, or a reservation went unused) and hands it to a
    /// waiting accept loop as a reservation.
    private func releaseSlot(reservation: Bool = false, listener index: Int? = nil) {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            state.open -= 1
            if reservation { state.reserved -= 1 }
            if let index { state.perListener[index].open -= 1 }
            guard state.lifecycle.isRunning, let id = state.capacityWaiters.keys.first else { return nil }
            state.open += 1
            state.reserved += 1
            return state.capacityWaiters.removeValue(forKey: id)
        }
        waiter?.resume(returning: true)
        checkDrained()
    }

    private func wakeCapacityWaiters() {
        let waiters = state.withLock { state in
            defer { state.capacityWaiters = [:] }
            return Array(state.capacityWaiters.values)
        }
        for waiter in waiters { waiter.resume(returning: false) }
    }

    /// While draining, finishes the lifecycle once the accept loops have ended and no
    /// connection is open.
    private func checkDrained() {
        let action = state.withLock { state -> ServerLifecycle.Action in
            guard state.open == 0, state.activeAcceptLoops == 0 else { return .none }
            return state.lifecycle.handle(.lastConnectionClosed)
        }
        if action == .finish { drained.trigger() }
    }
}

// MARK: - Initializers

extension Server where Listener: TransportListener {
    /// - Parameters:
    ///   - configuration: captured once; validated by `run()`.
    ///   - listeners: where connections come from. `run()` binds them.
    ///   - protocols: the protocols connections may speak, in priority order.
    ///   - components: background components to run besides those found in `handler`.
    ///   - handler: answers requests; a builder chain with one element.
    public convenience init(
        configuration: ServerConfiguration = ServerConfiguration(),
        listeners: [Listener],
        protocols: [any ConnectionProtocol],
        components: [any ServerComponent] = [],
        handler: Handler
    ) {
        self.init(configuration: configuration, entries: listeners.map { .byteStream($0) },
                  protocols: protocols, components: components, handler: handler)
    }

    /// - Parameters:
    ///   - configuration: captured once; validated by `run()`.
    ///   - listeners: where connections come from. `run()` binds them.
    ///   - protocols: the protocols connections may speak, in priority order.
    ///   - components: background components to run besides those found in the chain.
    ///   - chain: the middlewares, in the order they see requests, optionally ending in a
    ///     handler (``NotFoundHandler`` otherwise). See ``MiddlewareBuilder``.
    public convenience init(
        configuration: ServerConfiguration = ServerConfiguration(),
        listeners: [Listener],
        protocols: [any ConnectionProtocol],
        components: [any ServerComponent] = [],
        @MiddlewareBuilder _ chain: () -> Handler
    ) {
        self.init(configuration: configuration, listeners: listeners, protocols: protocols,
                  components: components, handler: chain())
    }
}

extension Server where Listener == ServerListener {
    /// A server over several kinds of listener (#0089). See ``ServerListener``.
    ///
    /// - Parameters:
    ///   - configuration: captured once; validated by `run()`.
    ///   - listeners: where connections come from, bound in order by `run()`.
    ///   - protocols: the byte-stream protocols, in priority order. Multiplexed listeners
    ///     name their own protocol, so this may be empty when every listener is multiplexed.
    ///   - components: background components to run besides those found in `handler`.
    ///   - handler: answers requests from every listener.
    public convenience init(
        configuration: ServerConfiguration = ServerConfiguration(),
        listeners: [ServerListener],
        protocols: [any ConnectionProtocol],
        components: [any ServerComponent] = [],
        handler: Handler
    ) {
        self.init(configuration: configuration, entries: listeners,
                  protocols: protocols, components: components, handler: handler)
    }

    /// A server over several kinds of listener, with a middleware chain (#0089).
    public convenience init(
        configuration: ServerConfiguration = ServerConfiguration(),
        listeners: [ServerListener],
        protocols: [any ConnectionProtocol],
        components: [any ServerComponent] = [],
        @MiddlewareBuilder _ chain: () -> Handler
    ) {
        self.init(configuration: configuration, listeners: listeners, protocols: protocols,
                  components: components, handler: chain())
    }
}
