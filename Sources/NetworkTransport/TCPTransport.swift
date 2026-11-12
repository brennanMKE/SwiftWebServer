public import HTTPCore
import Dispatch
import Foundation
import Network
import Synchronization

/// A ``ByteStreamTransport`` over a TCP `NWConnection` (issue #0078, docs/ROADMAP.md §5.2).
///
/// ## Demand
///
/// Nothing is read until ``receive(into:maxLength:)`` asks: each call issues exactly one
/// `NWConnection.receive(minimumIncompleteLength: 1, maximumLength: maxLength)` and copies the
/// delivered `Data` straight into the caller's buffer tail. A connection task that stops
/// reading stops the reads, and TCP flow control pushes back on the peer. There is no pump
/// and no intermediate buffer.
///
/// ## Sending
///
/// ``send(_:endOfStream:)`` resumes when Network.framework reports `.contentProcessed` for the
/// bytes. `endOfStream` sends a final message, which shuts down the TCP write side (FIN) while
/// receiving continues.
///
/// ## Lifecycle
///
/// The state, viability and receive handlers are installed before `start(queue:)` (#0010).
/// Every connection runs on its own serial `DispatchQueue` (the one place `DispatchQueue` is
/// allowed, CLAUDE.md). Continuations live in a `Mutex` and are taken out under the lock before
/// they are resumed, so each is resumed exactly once whichever of the NW callback, a state
/// change, ``close(_:)`` or task cancellation gets there first.
///
/// ## Cancellation
///
/// Network.framework cannot cancel one outstanding receive or send. Cancelling the task that
/// waits in `receive` or `send` therefore throws `CancellationError` at once and cancels the
/// connection (its read or write position is undefined from then on); later calls throw
/// ``TransportError/closed``.
public final class TCPTransport: ByteStreamTransport {
    let connection: NWConnection
    let queue: DispatchQueue
    let core: Core
    let executor: QueueTaskExecutor

    /// Wraps `connection` and installs its handlers. The connection is not started yet; call
    /// ``startConnection()``. `onSettled` is called once, on the connection's queue, when the
    /// connection becomes ready (`nil`) or fails before that (the failure; ``TransportError/closed``
    /// when it was cancelled).
    init(connection: NWConnection, failsWhileWaiting: Bool, onSettled: (@Sendable (TransportError?) -> Void)? = nil) {
        self.connection = connection
        self.queue = DispatchQueue(label: "sws.tcp.connection")
        self.executor = QueueTaskExecutor(queue: queue)
        let core = Core(failsWhileWaiting: failsWhileWaiting, onSettled: onSettled)
        self.core = core
        connection.stateUpdateHandler = { [core, weak connection] state in
            core.handle(state, connection: connection)
        }
        connection.viabilityUpdateHandler = { [core] isViable in
            core.state.withLock { $0.isViable = isViable }
        }
    }

    /// Starts the connection on its own queue. Handlers are already installed.
    func startConnection() {
        connection.start(queue: queue)
    }

    deinit {
        // A started NWConnection lives until it is cancelled; cancelling an already cancelled
        // connection is a no-op.
        connection.cancel()
    }

    // MARK: Client

    /// Opens a TCP connection to `host:port` and returns once it is ready; with `tls`, once the
    /// TLS handshake is done (``info`` then carries the negotiated ALPN and version).
    ///
    /// Network.framework parks a connection that cannot be established (refused, unreachable)
    /// in `.waiting` and retries when the path changes; this method treats `.waiting` as a
    /// failure and throws instead of hanging. Cancelling the calling task cancels the attempt.
    public static func connect(
        host: String,
        port: UInt16,
        configuration: TCPConfiguration = TCPConfiguration(),
        tls: TLSClientConfiguration? = nil
    ) async throws -> TCPTransport {
        guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            throw TransportError.failed(code: EINVAL)
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: nwPort, using: configuration.makeParameters(tls: tls?.makeOptions()))
        let transport = TCPTransport(connection: connection, failsWhileWaiting: true)
        transport.startConnection()
        try await transport.waitUntilReady()
        return transport
    }

    /// Suspends until the connection is ready, or throws its failure.
    func waitUntilReady() async throws {
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = core.state.withLock { state in
                    switch state.phase {
                    case .ready: return .success(())
                    case .failed(let error): return .failure(error)
                    case .closed: return .failure(TransportError.closed)
                    case .setup:
                        if Task.isCancelled { return .failure(CancellationError()) }
                        state.readyWaiter = continuation
                        return nil
                    }
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let waiter = core.state.withLock { state in
                defer { state.readyWaiter = nil }
                return state.readyWaiter
            }
            waiter?.resume(throwing: CancellationError())
            connection.forceCancel()
        }
    }

    /// A task executor that runs jobs on this connection's serial queue. Wrapping a
    /// connection's work in `withTaskExecutorPreference(transport.taskExecutor)` makes
    /// resumptions from Network.framework callbacks continue on that queue instead of hopping
    /// to the cooperative pool (experimental; see docs/notes/nw-transport.md).
    public var taskExecutor: any TaskExecutor { executor }

    // MARK: Observability

    /// Addresses of the connection, captured when it became ready.
    public var info: ConnectionInfo { core.state.withLock { $0.info } }

    /// When the listener handed this connection over and when it became ready, in
    /// `CLOCK_UPTIME_RAW` nanoseconds (zero for outbound connections). For `sws-bench accept`.
    @_spi(Benchmark) public var acceptTimestamps: (handedOver: UInt64, ready: UInt64) {
        core.state.withLock { ($0.handedOverAt, $0.readyAt) }
    }

    /// The last viability reported by Network.framework (false while the path is unusable).
    public var isViable: Bool { core.state.withLock { $0.isViable } }

    // MARK: ByteStreamTransport

    public func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        precondition(maxLength > 0, "maxLength must be positive")
        if try core.beginReceive() == .endOfStream { return 0 }
        defer { core.state.withLock { $0.receiving = false } }

        while true {
            let outcome = await withTaskCancellationHandler {
                await withUnsafeContinuation { (continuation: UnsafeContinuation<ReceiveOutcome, Never>) in
                    guard core.install(receiver: continuation) else { return }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) {
                        [core] data, _, isComplete, error in
                        core.completeReceive(data: data, isComplete: isComplete, error: error)
                    }
                }
            } onCancel: {
                if core.cancelPending(receiver: true) { connection.cancel() }
            }
            switch outcome {
            case .data(let data):
                buffer.append(contentsOf: data)
                return data.count
            case .endOfStream:
                return 0
            case .failure(let error):
                throw error
            case .cancelled:
                throw CancellationError()
            case .retry:
                continue
            }
        }
    }

    public func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws {
        try core.beginSend(endOfStream: endOfStream)
        defer { core.state.withLock { $0.sending = false } }
        if bytes.isEmpty && !endOfStream { return }
        // NWConnection takes `Data`; this is the one copy on the write path.
        let content: Data? = bytes.isEmpty ? nil : bytes.makeData()
        let context: NWConnection.ContentContext = endOfStream ? .finalMessage : .defaultMessage
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
                guard core.install(sender: continuation) else { return }
                // isComplete must be true for every send: an open message blocks later
                // contexts (docs/spikes/quic-spike.md, gotcha 4).
                connection.send(
                    content: content, contentContext: context, isComplete: true,
                    completion: .contentProcessed { [core] error in core.completeSend(error: error) })
            }
        } onCancel: {
            if core.cancelPending(receiver: false) { connection.cancel() }
        }
    }

    public func close(_ reason: CloseReason) async {
        guard core.markClosed() else { return }
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let done = core.state.withLock { state -> Bool in
                if state.didCancel { return true }
                state.cancelWaiters.append(continuation)
                return false
            }
            if done {
                continuation.resume()
                return
            }
            // `cancel()` disconnects gracefully (FIN after the bytes already accepted);
            // `forceCancel()` discards them and resets the connection.
            if reason.isAbortive { connection.forceCancel() } else { connection.cancel() }
        }
    }
}

// MARK: - Core

extension TCPTransport {
    enum Phase {
        case setup
        case ready
        case failed(TransportError)
        case closed
    }

    enum ReceiveOutcome: Sendable {
        case data(Data)
        case endOfStream
        case failure(TransportError)
        case cancelled
        /// An empty, incomplete delivery: issue another receive.
        case retry
    }

    enum ReceiveStart {
        case proceed
        case endOfStream
    }

    /// Connection state shared by the NW callbacks (on the connection's queue) and the tasks
    /// calling into the transport. Holds no reference to the `NWConnection`, so the
    /// connection's handlers do not form a cycle with it.
    final class Core: Sendable {
        struct State {
            var phase: Phase = .setup
            var info = ConnectionInfo()
            var isViable = true
            var readyWaiter: UnsafeContinuation<Void, any Error>?
            var receiver: UnsafeContinuation<ReceiveOutcome, Never>?
            var sender: UnsafeContinuation<Void, any Error>?
            var receiving = false
            var sending = false
            /// The peer finished sending; sticky.
            var inputEnded = false
            /// An error delivered together with the last bytes; thrown by the next receive.
            var inputError: TransportError?
            var outputShutdown = false
            /// `close(_:)` was called, or a cancelled receive/send cancelled the connection.
            var closedLocally = false
            /// `close(_:)` was called (it runs once).
            var closeCalled = false
            /// NW reported `.cancelled`.
            var didCancel = false
            var cancelWaiters: [UnsafeContinuation<Void, Never>] = []
            var onSettled: (@Sendable (TransportError?) -> Void)?
            /// `CLOCK_UPTIME_RAW` nanoseconds when the listener handed the connection over, and
            /// when it became ready (#0113, `sws-bench accept`). Zero when not recorded.
            var handedOverAt: UInt64 = 0
            var readyAt: UInt64 = 0
            /// The listener's handshake timer reset this connection (#0087).
            var handshakeTimedOut = false
        }

        let state: Mutex<State>
        let failsWhileWaiting: Bool

        init(failsWhileWaiting: Bool, onSettled: (@Sendable (TransportError?) -> Void)?) {
            self.failsWhileWaiting = failsWhileWaiting
            var initial = State()
            initial.onSettled = onSettled
            state = Mutex(initial)
        }

        /// The error a new operation fails with, or `nil` when the connection is usable.
        private static func terminalError(_ state: State) -> TransportError? {
            if state.closedLocally { return .closed }
            switch state.phase {
            case .failed(let error): return error
            case .closed: return .closed
            case .setup, .ready: return nil
            }
        }

        // MARK: Receive

        func beginReceive() throws(TransportError) -> ReceiveStart {
            try state.withLock { state throws(TransportError) -> ReceiveStart in
                if state.closedLocally { throw .closed }
                if state.receiving { throw .receiveAlreadyPending }
                if let error = state.inputError { throw error }
                if state.inputEnded { return .endOfStream }
                if let error = Self.terminalError(state) { throw error }
                state.receiving = true
                return .proceed
            }
        }

        /// Stores the receive continuation, or resumes it at once (and returns false) when the
        /// task is already cancelled or the connection is finished.
        func install(receiver continuation: UnsafeContinuation<ReceiveOutcome, Never>) -> Bool {
            let immediate: ReceiveOutcome? = state.withLock { state in
                if Task.isCancelled { return .cancelled }
                if let error = Self.terminalError(state) { return .failure(error) }
                state.receiver = continuation
                return nil
            }
            guard let immediate else { return true }
            continuation.resume(returning: immediate)
            return false
        }

        func completeReceive(data: Data?, isComplete: Bool, error: NWError?) {
            let resumed: (UnsafeContinuation<ReceiveOutcome, Never>, ReceiveOutcome)? = state.withLock { state in
                guard let receiver = state.receiver else { return nil }   // cancelled or closed
                state.receiver = nil
                let mapped = error.map { state.closedLocally ? TransportError.closed : TransportError($0) }
                if let data, !data.isEmpty {
                    if isComplete {
                        state.inputEnded = true
                    } else if let mapped {
                        state.inputError = mapped
                    }
                    return (receiver, .data(data))
                }
                if isComplete && error == nil {
                    state.inputEnded = true
                    return (receiver, .endOfStream)
                }
                if let mapped {
                    state.inputError = mapped
                    return (receiver, .failure(mapped))
                }
                if isComplete {
                    state.inputEnded = true
                    return (receiver, .endOfStream)
                }
                return (receiver, .retry)
            }
            if let (receiver, outcome) = resumed { receiver.resume(returning: outcome) }
        }

        // MARK: Send

        func beginSend(endOfStream: Bool) throws(TransportError) {
            try state.withLock { state throws(TransportError) in
                if state.closedLocally { throw .closed }
                if state.outputShutdown { throw .outputShutdown }
                if let error = Self.terminalError(state) { throw error }
                precondition(!state.sending, "TCPTransport: concurrent send calls")
                state.sending = true
                if endOfStream { state.outputShutdown = true }
            }
        }

        func install(sender continuation: UnsafeContinuation<Void, any Error>) -> Bool {
            let immediate: (any Error)? = state.withLock { state in
                if Task.isCancelled { return CancellationError() }
                if let error = Self.terminalError(state) { return error }
                state.sender = continuation
                return nil
            }
            guard let immediate else { return true }
            continuation.resume(throwing: immediate)
            return false
        }

        func completeSend(error: NWError?) {
            let resumed: (UnsafeContinuation<Void, any Error>, TransportError?)? = state.withLock { state in
                guard let sender = state.sender else { return nil }
                state.sender = nil
                return (sender, error.map { state.closedLocally ? TransportError.closed : TransportError($0) })
            }
            guard let (sender, error) = resumed else { return }
            if let error { sender.resume(throwing: error) } else { sender.resume() }
        }

        // MARK: Cancellation and close

        /// Resumes the pending receive (or send) with cancellation. Returns true when there was
        /// one, in which case the caller cancels the connection: the NW operation is still
        /// outstanding and the stream position is now undefined.
        func cancelPending(receiver: Bool) -> Bool {
            if receiver {
                let taken = state.withLock { state -> UnsafeContinuation<ReceiveOutcome, Never>? in
                    guard let pending = state.receiver else { return nil }
                    state.receiver = nil
                    state.closedLocally = true
                    return pending
                }
                taken?.resume(returning: .cancelled)
                return taken != nil
            } else {
                let taken = state.withLock { state -> UnsafeContinuation<Void, any Error>? in
                    guard let pending = state.sender else { return nil }
                    state.sender = nil
                    state.closedLocally = true
                    return pending
                }
                taken?.resume(throwing: CancellationError())
                return taken != nil
            }
        }

        /// Marks the transport closed and fails any receive or send in progress with
        /// ``TransportError/closed``. Returns false if it was already closed by `close(_:)`.
        func markClosed() -> Bool {
            let taken = state.withLock { state -> (UnsafeContinuation<ReceiveOutcome, Never>?, UnsafeContinuation<Void, any Error>?)? in
                if state.closeCalled { return nil }
                state.closeCalled = true
                state.closedLocally = true
                defer { state.receiver = nil; state.sender = nil }
                return (state.receiver, state.sender)
            }
            guard let taken else { return false }
            taken.0?.resume(returning: .failure(.closed))
            taken.1?.resume(throwing: TransportError.closed)
            return true
        }

        // MARK: State

        func handle(_ newState: NWConnection.State, connection: NWConnection?) {
            switch newState {
            case .ready:
                var info = ConnectionInfo(
                    localAddress: TransportAddress(connection?.currentPath?.localEndpoint),
                    remoteAddress: TransportAddress(connection?.currentPath?.remoteEndpoint ?? connection?.endpoint))
                if let tls = connection?.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                    // #0087/#0088: the handshake is done, so ALPN and the version are final.
                    let metadata = tls.securityProtocolMetadata
                    info.isSecure = true
                    info.negotiatedALPN = sec_protocol_metadata_get_negotiated_protocol(metadata).map { String(cString: $0) }
                    info.tlsVersion = TLSVersion(rawValue: sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata).rawValue)
                }
                let (waiter, settled) = state.withLock { state in
                    guard case .setup = state.phase else { return (nil, nil) as (UnsafeContinuation<Void, any Error>?, (@Sendable (TransportError?) -> Void)?) }
                    state.phase = .ready
                    state.info = info
                    state.readyAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    defer { state.readyWaiter = nil; state.onSettled = nil }
                    return (state.readyWaiter, state.onSettled)
                }
                waiter?.resume()
                settled?(nil)
            case .waiting(let error):
                guard failsWhileWaiting else { return }
                fail(TransportError(error))
                connection?.cancel()
            case .failed(let error):
                fail(TransportError(error))
            case .cancelled:
                finishCancelled()
                connection?.stateUpdateHandler = nil
                connection?.viabilityUpdateHandler = nil
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }

        private func fail(_ error: TransportError) {
            let taken = state.withLock { state in
                if case .setup = state.phase { state.phase = .failed(error) }
                else if case .ready = state.phase { state.phase = .failed(error) }
                let error = state.closedLocally ? TransportError.closed : error
                defer {
                    state.readyWaiter = nil; state.receiver = nil; state.sender = nil; state.onSettled = nil
                }
                return (error, state.readyWaiter, state.receiver, state.sender, state.onSettled)
            }
            taken.1?.resume(throwing: taken.0)
            taken.2?.resume(returning: .failure(taken.0))
            taken.3?.resume(throwing: taken.0)
            taken.4?(taken.0)
        }

        private func finishCancelled() {
            let taken = state.withLock { state in
                switch state.phase {
                case .setup, .ready: state.phase = .closed
                case .failed, .closed: break
                }
                state.didCancel = true
                defer {
                    state.readyWaiter = nil; state.receiver = nil; state.sender = nil
                    state.onSettled = nil; state.cancelWaiters = []
                }
                return (state.readyWaiter, state.receiver, state.sender, state.onSettled, state.cancelWaiters)
            }
            taken.0?.resume(throwing: TransportError.closed)
            taken.1?.resume(returning: .failure(.closed))
            taken.2?.resume(throwing: TransportError.closed)
            taken.3?(.closed)
            for waiter in taken.4 { waiter.resume() }
        }
    }
}
