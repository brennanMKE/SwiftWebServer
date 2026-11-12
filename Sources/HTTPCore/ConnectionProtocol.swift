import Synchronization

// The server-side extension points that protocol targets implement (docs/ROADMAP.md §5.2).
// They live in HTTPCore, not HTTPServer, because protocol targets (HTTP1, HTTP2, HTTP3) and
// transport adapters (NetworkTransport) depend only on HTTPCore.

/// A wire protocol that serves one connection: HTTP/1.1, HTTP/2, or a test protocol.
///
/// The server picks one protocol per connection, by ALPN for TLS or by sniffing the first
/// bytes for cleartext (see `ProtocolRegistry` in HTTPServer), and then calls ``run(_:handler:context:)``
/// once. `run` owns the transport until it returns; the server closes the transport afterwards
/// (closing is idempotent, so a protocol may close it first).
public protocol ConnectionProtocol: Sendable {
    /// ALPN tokens this protocol accepts (`"http/1.1"`, `"h2"`). Empty for none.
    static var alpnTokens: [String] { get }

    /// Whether `bytes` (the first bytes a cleartext client sent, possibly fewer than the
    /// protocol needs) start this protocol's preface.
    static func matchesCleartextPreface(_ bytes: borrowing ByteBuffer) -> SniffResult

    /// Serves the connection until it ends. Must return promptly when the task is cancelled,
    /// and should finish its current exchange and return when `context.shutdown` triggers.
    func run<T: ByteStreamTransport, H: HTTPHandler>(_ t: T, handler: H, context: ConnectionContext) async
}

/// A wire protocol that serves one multiplexed connection (HTTP/3 over QUIC): the
/// ``MultiplexedTransport`` counterpart of ``ConnectionProtocol``.
///
/// Every connection of a QUIC listener negotiated one of ``alpnTokens`` in its handshake, so
/// there is no sniffing. ``run(_:handler:context:)`` owns the connection until it returns and
/// closes it with an application error code before returning.
public protocol MultiplexedConnectionProtocol: Sendable {
    /// ALPN tokens this protocol accepts (`"h3"`).
    static var alpnTokens: [String] { get }

    /// Serves the connection until it ends. Must return promptly when the task is cancelled.
    func run<T: MultiplexedTransport, H: HTTPHandler>(
        _ t: T, handler: H, context: ConnectionContext
    ) async where T.Stream: ResettableStream
}

/// The answer of ``ConnectionProtocol/matchesCleartextPreface(_:)``.
public enum SniffResult: Sendable, Hashable {
    /// The bytes start this protocol's preface.
    case match
    /// The bytes cannot start this protocol's preface.
    case noMatch
    /// The bytes are a prefix of the preface; more are needed to decide.
    case needMoreBytes
}

/// Per-connection information and signals handed to ``ConnectionProtocol/run(_:handler:context:)``.
public struct ConnectionContext: Sendable {
    /// Addresses and security properties of the connection.
    public var info: ConnectionInfo
    /// Triggers when the server starts draining. A protocol finishes the exchange in progress,
    /// stops reading new requests (HTTP/1.1 `Connection: close`, HTTP/2 `GOAWAY`) and returns.
    /// The server cancels connections that are still running at the drain deadline.
    public var shutdown: ShutdownSignal
    /// Whether to stamp ``RequestContext/startTime`` on every request. The server sets it when
    /// the handler chain contains a ``RequestStartTimeConsumer`` (#0083).
    public var recordsRequestStartTime: Bool

    public init(info: ConnectionInfo, shutdown: ShutdownSignal = ShutdownSignal(),
                recordsRequestStartTime: Bool = false) {
        self.info = info
        self.shutdown = shutdown
        self.recordsRequestStartTime = recordsRequestStartTime
    }
}

/// A one-shot signal: it triggers once and stays triggered (docs/ROADMAP.md §5.4: a low-rate
/// signal, so a lock and a list of waiters, not a stream).
///
/// ``trigger()`` is synchronous and never suspends, so it can be called from any context,
/// including a `DispatchSource` signal handler. Triggering again is a no-op, and a ``wait()``
/// that starts after the trigger returns at once (legacy #0005).
public final class ShutdownSignal: Sendable {
    private struct State {
        var triggered = false
        var nextID: UInt64 = 0
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())
    /// Mirrors `state.triggered` so ``isTriggered`` is one atomic load, cheap enough to check
    /// per request. Sequentially consistent, so a connection that publishes its state and then
    /// reads the flag cannot miss a trigger whose waiter reads that state (HTTP/1.1 drain).
    private let flag = Atomic<Bool>(false)

    public init() {}

    /// True once ``trigger()`` has been called. One atomic load, no lock.
    public var isTriggered: Bool { flag.load(ordering: .sequentiallyConsistent) }

    /// Triggers the signal and resumes every waiter. Idempotent.
    public func trigger() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.triggered else { return [] }
            state.triggered = true
            flag.store(true, ordering: .sequentiallyConsistent)
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends until the signal triggers or the calling task is cancelled, whichever comes
    /// first. Check ``isTriggered`` afterwards to tell the two apart.
    public func wait() async {
        let id = state.withLock { state -> UInt64 in
            defer { state.nextID &+= 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.triggered || Task.isCancelled { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }
}

/// A source of accepted connections that a server serves (the listener half of the transport
/// boundary). `NetworkTransport.TCPListener` is the production adapter; `HTTPTestSupport`
/// has an in-memory one.
public protocol TransportListener: Sendable {
    /// The transport of an accepted connection.
    associatedtype Transport: ByteStreamTransport
    /// Accepted connections, demand-driven: `next()` takes one connection, so a consumer that
    /// stops pulling stops accepting (the listener then queues or refuses per its own bound).
    /// Iteration ends after ``close()``.
    associatedtype Connections: AsyncSequence<Transport, any Error>

    /// Binds and starts listening; returns the bound address. Throws when binding fails (for
    /// example, the address is in use).
    func listen() async throws -> TransportAddress

    /// Accepted connections. One consumer at a time.
    var connections: Connections { get }

    /// Stops accepting, drops connections not yet taken, and ends ``connections``. Idempotent.
    /// Only called after ``listen()`` has returned or thrown.
    func close() async
}

/// A source of accepted multiplexed connections (a QUIC listener): the
/// ``MultiplexedTransport`` counterpart of ``TransportListener`` (#0089).
/// `NetworkTransport.QUICListener` is the production adapter.
///
/// A server serves each connection with a ``MultiplexedConnectionProtocol`` (HTTP/3). The
/// connection counts as one connection against the server's limit, however many streams it
/// carries.
public protocol MultiplexedTransportListener: Sendable {
    /// An accepted connection.
    associatedtype Connection: MultiplexedTransport where Connection.Stream: ResettableStream
    /// Accepted connections, demand-driven like ``TransportListener/connections``. Iteration
    /// ends after ``close()``.
    associatedtype Connections: AsyncSequence<Connection, any Error>

    /// Binds and starts listening; returns the bound address. Throws when binding fails.
    func listen() async throws -> TransportAddress

    /// Accepted connections. One consumer at a time.
    var connections: Connections { get }

    /// Stops accepting, closes connections not yet taken, and ends ``connections``.
    /// Idempotent. Only called after ``listen()`` has returned or thrown.
    func close() async

    /// Addresses and security properties of an accepted connection.
    func connectionInfo(_ connection: Connection) -> ConnectionInfo

    /// Closes a connection the server will not serve (over the connection limit, or
    /// arriving while the server drains).
    func refuse(_ connection: Connection) async
}
