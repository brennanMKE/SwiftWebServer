public import HTTPCore
import AccessLog
import Synchronization

extension ReloadableHandler {
    /// Reopens every live chain's access log file by its path (`SIGHUP`, #0127), so lines
    /// written from now on go to a new file after a log rotator renamed the old one.
    public func reopenAccessLogs() {
        for handler in liveHandlers {
            for case let log as AccessLog in MiddlewareChainInspector.serverComponents(in: handler) {
                log.reopen()
            }
        }
    }
}

extension ServerSettings {
    /// The keys that take effect only at startup, because they configure the listeners, the
    /// protocols or the server itself rather than the handler chain: those whose values differ
    /// between `self` and `other` (#0127).
    public func restartOnlyChanges(comparedTo other: ServerSettings) -> [String] {
        var keys: [String] = []
        if host != other.host { keys.append("host") }
        if port != other.port { keys.append("port") }
        if transport != other.transport { keys.append("transport") }
        if tls != other.tls { keys.append("tls") }
        if http3 != other.http3 { keys.append("http3") }
        if http2 != other.http2 { keys.append("http2") }
        if maxConnections != other.maxConnections { keys.append("maxConnections") }
        if drainTimeout != other.drainTimeout { keys.append("drainTimeout") }
        if timeouts != other.timeouts { keys.append("timeouts") }
        if maxBodySize != other.maxBodySize { keys.append("maxBodySize") }
        return keys
    }
}

/// The non-generic part of a ``ReloadableHandler`` generation: the write-once link to its
/// successor. Non-generic so the request path's atomic load and lock are specialized code, not
/// generic code run through metadata.
@usableFromInline
class ReloadGenerationLink: @unchecked Sendable {
    /// The generation that replaced this one, held strongly; set once.
    private let successorReference = Mutex<ReloadGenerationLink?>(nil)
    /// The same, unretained, for the request path: an acquiring load, no lock. Valid because
    /// ``successorReference`` keeps it alive as long as this link lives. (`AtomicLazyReference`
    /// measured about 90 ns per load here.)
    private let successor = Atomic<Unmanaged<ReloadGenerationLink>?>(nil)

    init() {}

    /// Links `next` as this generation's successor. Once only.
    final func link(_ next: ReloadGenerationLink) {
        successorReference.withLock { $0 = next }
        successor.store(Unmanaged.passUnretained(next), ordering: .releasing)
    }

    /// The newest generation reachable through the successor links: one atomic load when no
    /// swap happened since this one.
    @usableFromInline
    final func latest() -> ReloadGenerationLink {
        var generation = self
        while let next = generation.successor.load(ordering: .acquiring) {
            generation = next.takeUnretainedValue()
        }
        return generation
    }
}

/// The connection's generation in its ``RequestContext``. Not nested in the generic handler: a
/// generic key type would cost a metadata lookup per request. One ``ReloadableHandler`` per
/// chain.
@usableFromInline
enum ReloadGenerationKey: RequestContextKey {
    @usableFromInline static var defaultValue: ReloadGenerationLink? { nil }
}

/// The current generation, for requests without connection state.
@usableFromInline
final class ReloadCurrentGeneration: Sendable {
    let current: Mutex<ReloadGenerationLink>

    init(_ generation: ReloadGenerationLink) {
        current = Mutex(generation)
    }

    @usableFromInline
    func load() -> ReloadGenerationLink {
        current.withLock { $0 }
    }

    func store(_ generation: ReloadGenerationLink) {
        current.withLock { $0 = generation }
    }
}

/// A handler chain that can be replaced while the server runs (#0127): `SIGHUP` builds a new
/// chain from the reloaded `http-config.json` and ``replace(with:)`` swaps it in for new
/// requests, while requests already running finish on the chain they started with.
///
/// The server sees one handler that is also a ``ConnectionObserver``, a ``ServerComponent``
/// and a ``RequestStartTimeConsumer``, and forwards each role to the chains inside it:
///
/// - **Requests** run on the chain that is current when the request starts: the generation
///   the connection was opened with (a lookup in its ``RequestContext``), followed through its
///   write-once successor links (one atomic load each; one in total until a swap). No lock and
///   no allocation; only a request without connection state (a runner driven without
///   ``ConnectionObservers``) takes the lock.
/// - **Connections** are opened and closed with the observers (an access log's buffers) of
///   the chain that was current when they opened.
/// - **Components** (an access log's writer, a proxy's pool) of each chain run as child tasks
///   of ``run(server:)``. An old chain is retired, and its components cancelled (an access log
///   writes what it still holds), once it is no longer current and every connection opened
///   while it or an older chain was current has closed: a request on such a connection may
///   still be running on it.
///
/// Start time is stamped for every request because a reloaded chain may add an access log.
/// Use at most one per chain: the connection's generation is kept under one context key.
public final class ReloadableHandler<Handler: HTTPHandler>: HTTPHandler, ConnectionObserver, ServerComponent,
    RequestStartTimeConsumer, Sendable
{
    /// One chain and what the server would have found in it.
    @usableFromInline
    final class Generation: ReloadGenerationLink, @unchecked Sendable {
        @usableFromInline let number: UInt64
        @usableFromInline let handler: Handler
        let components: [any ServerComponent]
        let observers: ConnectionObservers
        /// Triggers when the generation is retired.
        let retired = ShutdownSignal()

        init(number: UInt64, handler: Handler) {
            self.number = number
            self.handler = handler
            self.components = MiddlewareChainInspector.serverComponents(in: handler)
            self.observers = ConnectionObservers(chain: handler)
            super.init()
        }
    }

    @usableFromInline
    struct State {
        /// Live generations, oldest first; the last is current.
        @usableFromInline var generations: [Generation]
        /// Open connections per live generation number.
        var connections: [UInt64: Int] = [:]
        /// Generations not yet started by ``run(server:)``.
        var pending: [Generation] = []
        var waiter: CheckedContinuation<Void, Never>?
    }

    let state: Mutex<State>
    @usableFromInline let currentGeneration: ReloadCurrentGeneration

    /// Serves `handler` until the first ``replace(with:)``.
    public init(_ handler: Handler) {
        let first = Generation(number: 0, handler: handler)
        state = Mutex(State(generations: [first], pending: [first]))
        currentGeneration = ReloadCurrentGeneration(first)
    }

    /// The chain new requests run on.
    public var current: Handler { state.withLock { $0.generations.last! }.handler }

    /// Chains not yet retired, oldest first (the last is ``current``).
    public var liveHandlers: [Handler] { state.withLock { $0.generations.map(\.handler) } }

    /// Makes `handler` the chain for new requests and connections. Its components start at
    /// once (when ``run(server:)`` is running); the previous chain retires when its
    /// connections have closed.
    public func replace(with handler: Handler) {
        let (waiter, retired) = state.withLock { state -> (CheckedContinuation<Void, Never>?, [Generation]) in
            let previous = state.generations.last!
            let next = Generation(number: previous.number &+ 1, handler: handler)
            state.generations.append(next)
            state.pending.append(next)
            previous.link(next)
            currentGeneration.store(next)
            let waiter = state.waiter
            state.waiter = nil
            return (waiter, Self.retireIdle(&state))
        }
        for generation in retired { generation.retired.trigger() }
        waiter?.resume()
    }

    /// Removes the oldest generations that are not current and have no open connections.
    static func retireIdle(_ state: inout State) -> [Generation] {
        var retired: [Generation] = []
        while state.generations.count > 1, state.connections[state.generations[0].number, default: 0] == 0 {
            let generation = state.generations.removeFirst()
            state.connections[generation.number] = nil
            retired.append(generation)
        }
        return retired
    }

    // MARK: HTTPHandler

    @inlinable
    public func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        try await generation(for: context).handler.handle(request, context: context)
    }

    /// The current generation: from the connection's, through the successor links.
    /// Inlinable so the caller specializes the chain's `handle`.
    @inlinable
    func generation(for context: RequestContext) -> Generation {
        let link = context[ReloadGenerationKey.self]?.latest() ?? currentGeneration.load()
        // Every link in this handler is one of its generations.
        return unsafeDowncast(link, to: Generation.self)
    }

    // MARK: ConnectionObserver

    public func connectionWillStart(_ connection: inout ConnectionContext) {
        let generation = state.withLock { state -> Generation in
            let generation = state.generations.last!
            state.connections[generation.number, default: 0] += 1
            return generation
        }
        connection.requestContext[ReloadGenerationKey.self] = generation
        generation.observers.connectionWillStart(&connection)
    }

    public func connectionDidEnd(_ connection: ConnectionContext) {
        guard let link = connection.requestContext[ReloadGenerationKey.self] else { return }
        let generation = unsafeDowncast(link, to: Generation.self)
        generation.observers.connectionDidEnd(connection)
        let retired = state.withLock { state -> [Generation] in
            state.connections[generation.number, default: 1] -= 1
            return Self.retireIdle(&state)
        }
        for generation in retired { generation.retired.trigger() }
    }

    // MARK: ServerComponent

    /// Runs every generation's components until cancelled: the current ones, and each new
    /// chain's as it is swapped in. A retired chain's components are cancelled. A component
    /// error shuts the server down as it would without reloading.
    public func run(server: ServerHandle) async throws {
        try await withThrowingDiscardingTaskGroup { group in
            while !Task.isCancelled {
                let started = state.withLock { state -> [Generation] in
                    defer { state.pending = [] }
                    return state.pending
                }
                for generation in started where !generation.components.isEmpty {
                    group.addTask {
                        try await Self.run(generation, server: server)
                    }
                }
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let resumeNow = state.withLock { state -> Bool in
                            if !state.pending.isEmpty || Task.isCancelled { return true }
                            state.waiter = continuation
                            return false
                        }
                        if resumeNow { continuation.resume() }
                    }
                } onCancel: {
                    let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                        defer { state.waiter = nil }
                        return state.waiter
                    }
                    waiter?.resume()
                }
            }
        }
    }

    /// One generation's components, until it retires or the server cancels them.
    static func run(_ generation: Generation, server: ServerHandle) async throws {
        try await withThrowingTaskGroup { group in
            for component in generation.components {
                group.addTask { try await component.run(server: server) }
            }
            group.addTask {
                await generation.retired.wait()
                throw CancellationError()
            }
            do {
                // The first to finish: a component error, or the retirement.
                while try await group.next() != nil {}
            } catch is CancellationError {
                group.cancelAll()
                // Let the components finish their shutdown work (a log flush).
                while (try? await group.next()) != nil {}
            }
        }
    }
}
