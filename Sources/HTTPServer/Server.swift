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
public final class Server<Listener: TransportListener, Handler: HTTPHandler>: Sendable {
    public let configuration: ServerConfiguration
    public let protocols: ProtocolRegistry
    let listeners: [Listener]
    let handler: Handler
    /// Background components: the `components:` argument, then those found in the chain.
    let components: [any ServerComponent]
    /// The chain reads ``RequestContext/startTime``, so the runners stamp each request.
    let recordsRequestStartTime: Bool
    /// Elements with per-connection state (an access log): the `components:` that are
    /// observers, then those found in the chain.
    let connectionObservers: ConnectionObservers

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
    }

    let state = Mutex(State())

    /// - Parameters:
    ///   - configuration: captured once; validated by `run()`.
    ///   - listeners: where connections come from. `run()` binds them.
    ///   - protocols: the protocols connections may speak, in priority order.
    ///   - components: background components to run besides those found in `handler`.
    ///   - handler: answers requests; a builder chain with one element.
    public init(
        configuration: ServerConfiguration = ServerConfiguration(),
        listeners: [Listener],
        protocols: [any ConnectionProtocol],
        components: [any ServerComponent] = [],
        handler: Handler
    ) {
        self.configuration = configuration
        self.listeners = listeners
        self.protocols = ProtocolRegistry(protocols, sniffTimeout: configuration.sniffTimeout)
        self.handler = handler
        self.components = components + MiddlewareChainInspector.serverComponents(in: handler)
        self.recordsRequestStartTime = MiddlewareChainInspector.needsRequestStartTime(handler)
        self.connectionObservers = ConnectionObservers(
            components.compactMap { $0 as? any ConnectionObserver }
                + MiddlewareChainInspector.connectionObservers(in: handler))
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
            guard !protocols.protocols.isEmpty else { throw ServerError.noProtocols }
        } catch {
            _ = state.withLock { $0.lifecycle.handle(.listenerFailed) }
            failStartup(error)
            throw error
        }

        var addresses: [TransportAddress] = []
        var bound: [Listener] = []
        do {
            for listener in listeners {
                if shutdownSignal.isTriggered { break }
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
            if action == .acceptConnections { state.addresses = addresses }
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

        await serve(addresses: addresses)

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
    private func serve(addresses: [TransportAddress]) async {
        guard !components.isEmpty else { return await serveConnections() }
        let handle = ServerHandle(localAddresses: addresses, draining: shutdownSignal) { [weak self] in
            self?.requestShutdown()
        }
        await withDiscardingTaskGroup { group in
            for component in components {
                group.addTask { await self.runComponent(component, handle: handle) }
            }
            await serveConnections()
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

    private func serveConnections() async {
        state.withLock { $0.activeAcceptLoops = listeners.count }
        await withDiscardingTaskGroup { group in
            for listener in listeners {
                group.addTask { await self.acceptLoop(listener) }
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

    private func acceptLoop(_ listener: Listener) async {
        await withDiscardingTaskGroup { connections in
            var iterator = listener.connections.makeAsyncIterator()
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

                let next: Listener.Transport?
                do {
                    next = try await iterator.next()
                } catch {
                    if reserved { releaseSlot(reservation: true) }
                    if !(error is CancellationError) { failedWhileRunning(error) }
                    break accepting
                }
                guard let transport = next else {
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
                            return false
                        }
                        state.open += 1
                    }
                    state.accepted += 1
                    state.peakOpen = max(state.peakOpen, state.open - state.reserved)
                    return true
                }
                guard admitted else {
                    if reserved { releaseSlot(reservation: true) }
                    await transport.close(.shutdown)
                    continue
                }
                connections.addTask {
                    await self.serveConnection(transport)
                    self.releaseSlot()
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

    private func serveConnection(_ transport: Listener.Transport) async {
        var context = ConnectionContext(info: transport.info, shutdown: shutdownSignal,
                                        recordsRequestStartTime: recordsRequestStartTime)
        if !connectionObservers.isEmpty { connectionObservers.connectionWillStart(&context) }
        await protocols.serve(transport, handler: handler, context: context)
        await transport.close(.normal)
        if !connectionObservers.isEmpty { connectionObservers.connectionDidEnd(context) }
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
    private func releaseSlot(reservation: Bool = false) {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            state.open -= 1
            if reservation { state.reserved -= 1 }
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
