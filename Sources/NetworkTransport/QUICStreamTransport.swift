public import HTTPCore
import Dispatch
import Foundation
import Network
import Synchronization

/// One QUIC stream of a ``QUICConnection``: a ``ByteStreamTransport`` over a stream
/// `NWConnection` with its RFC 9000 stream ID (issue #0098). (Not `QUICStream`: macOS 26's
/// Network module declares a type of that name.)
///
/// ## Demand and backpressure
///
/// Each ``receive(into:maxLength:)`` issues exactly one Network.framework receive, so a stream
/// that is not read stops consuming its flow-control window and the peer is pushed back.
/// ``send(_:endOfStream:)`` hands Network.framework at most
/// ``QUICConfiguration/sendChunkSize`` bytes at a time and waits for each chunk's
/// `.contentProcessed` completion, so the adapter never holds more than one chunk beyond what
/// Network.framework accepted (which itself buffers 2–6 MiB per stream, spike Q7).
///
/// ## FIN, reset and STOP_SENDING
///
/// - `send(_:endOfStream: true)` sends the last bytes with `.finalMessage, isComplete: true`
///   (FIN). Every send uses `isComplete: true` (spike gotcha 4). The peer's FIN makes
///   `receive` return 0, sticky.
/// - ``reset(applicationError:)`` sets `streamApplicationErrorCode` and cancels the stream, which
///   sends RESET_STREAM (and STOP_SENDING if the receive side is open) with the code. A peer
///   reset makes `receive` throw ``TransportError/connectionReset``; the code is then in
///   ``receivedResetCode``.
/// - Network.framework has no separate STOP_SENDING call, so a reset aborts both directions
///   of the local end: later local operations throw ``TransportError/closed``. (The in-memory
///   transport keeps the receive side open; HTTP/3 code must not rely on that.)
/// - ``close(_:)``: ``CloseReason/abort`` is `forceCancel()` (RESET_STREAM with code 0); any
///   other reason is `cancel()`, which flushes and finishes the stream.
///
/// Peer-initiated unidirectional streams cannot send (``TransportError/outputShutdown``), and
/// locally opened ones receive end of stream at once.
public final class QUICStreamTransport: ByteStreamTransport, StreamIdentified {
    let connection: NWConnection
    let core: Core
    let chunkSize: Int
    /// True when this side opened the stream.
    public let isLocallyInitiated: Bool

    init(
        connection: NWConnection,
        isLocallyInitiated: Bool,
        chunkSize: Int,
        events: Events
    ) {
        self.connection = connection
        self.isLocallyInitiated = isLocallyInitiated
        self.chunkSize = chunkSize
        let core = Core(events: events)
        self.core = core
        connection.stateUpdateHandler = { [core, weak connection] state in
            core.handle(state, connection: connection)
        }
    }

    deinit {
        // A started stream lives until it is cancelled; repeated cancels are no-ops.
        connection.cancel()
    }

    /// Callbacks into the owning connection, invoked on the connection's queue.
    struct Events: Sendable {
        /// The stream became ready with this ID.
        var ready: @Sendable (UInt64) -> Void
        /// The stream ended (cancelled or failed); the ID is `nil` if it never became ready.
        var finished: @Sendable (UInt64?) -> Void
    }

    func start(queue: DispatchQueue) {
        connection.start(queue: queue)
    }

    // MARK: Identity

    /// The RFC 9000 stream ID. Streams are handed out only once ready, so this is constant.
    public var streamID: UInt64 { core.state.withLock { $0.streamID ?? .max } }

    /// False for the receiving end of a unidirectional stream.
    public var canSend: Bool { !(isUnidirectional && !isLocallyInitiated) }
    /// False for the sending end of a unidirectional stream.
    public var canReceive: Bool { !(isUnidirectional && isLocallyInitiated) }

    /// Addresses and ALPN of the connection, captured when the stream became ready.
    public var info: ConnectionInfo { core.state.withLock { $0.info } }

    // MARK: Reset codes

    /// The RESET_STREAM code this end sent.
    public var sentResetCode: UInt64? { core.state.withLock { $0.sentResetCode } }
    /// The code of the peer's RESET_STREAM, read from `streamApplicationErrorCode` when a
    /// receive failed with a reset.
    public var receivedResetCode: UInt64? { core.state.withLock { $0.receivedResetCode } }
    /// The peer's code read when a send failed (STOP_SENDING); `nil` if none was observed.
    public var receivedStopSendingCode: UInt64? { core.state.withLock { $0.receivedStopSendingCode } }

    /// True after ``close(_:)`` or ``reset(applicationError:)``, or once the stream ended.
    public var isClosed: Bool {
        core.state.withLock { $0.closedLocally || $0.didCancel }
    }

    // MARK: Ready

    /// Suspends until the stream is ready (it then has an ID), or throws its failure.
    func waitUntilReady() async throws {
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = core.state.withLock { state in
                    if state.streamID != nil { return .success(()) }
                    if let error = state.terminalError { return .failure(error) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.readyWaiter = continuation
                    return nil
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

    // MARK: ByteStreamTransport

    public func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        precondition(maxLength > 0, "maxLength must be positive")
        if try core.beginReceive(canReceive: canReceive) == .endOfStream { return 0 }
        defer { core.state.withLock { $0.receiving = false } }

        while true {
            let outcome = await withTaskCancellationHandler {
                await withUnsafeContinuation { (continuation: UnsafeContinuation<ReceiveOutcome, Never>) in
                    guard core.install(receiver: continuation) else { return }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) {
                        [core, weak connection] data, _, isComplete, error in
                        // A peer reset carries its code in the stream metadata (spike Q5).
                        let code = error == nil ? nil : connection?.quicMetadata.flatMap { quicCode($0.streamApplicationErrorCode) }
                        core.completeReceive(data: data, isComplete: isComplete, error: error, peerCode: code)
                    }
                }
            } onCancel: {
                if core.cancelPending(receiver: true) { connection.forceCancel() }
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
        try core.beginSend(endOfStream: endOfStream, canSend: canSend)
        defer { core.state.withLock { $0.sending = false } }
        let total = bytes.readableBytes
        if total == 0 {
            // A bare FIN: `.finalMessage` with no content (spike Q4).
            if endOfStream { try await sendChunk(nil, final: true) }
            return
        }
        var offset = 0
        while offset < total {
            let count = min(chunkSize, total - offset)
            // NWConnection takes `Data`; this is the one copy on the write path.
            let data = bytes.withUnsafeReadableBytes { raw in
                Data(bytes: raw.baseAddress! + offset, count: count)
            }
            offset += count
            try await sendChunk(data, final: endOfStream && offset == total)
        }
    }

    private func sendChunk(_ content: Data?, final: Bool) async throws {
        let context: NWConnection.ContentContext = final ? .finalMessage : .defaultMessage
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
                guard core.install(sender: continuation) else { return }
                // isComplete must be true for every send: an open message blocks later
                // contexts (spike gotcha 4).
                connection.send(
                    content: content, contentContext: context, isComplete: true,
                    completion: .contentProcessed { [core, weak connection] error in
                        let code = error == nil ? nil : connection?.quicMetadata.flatMap { quicCode($0.streamApplicationErrorCode) }
                        core.completeSend(error: error, peerCode: code)
                    })
            }
        } onCancel: {
            if core.cancelPending(receiver: false) { connection.forceCancel() }
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
            if reason.isAbortive { connection.forceCancel() } else { connection.cancel() }
        }
    }

    // MARK: Reset

    /// Abandons the stream with RESET_STREAM(`applicationError`) (and STOP_SENDING with the
    /// same code if the receive side is still open): sets `streamApplicationErrorCode`, then
    /// cancels (spike gotcha 9). The peer's receive throws ``TransportError/connectionReset``
    /// and reads the code. Local operations afterwards throw ``TransportError/closed``.
    public func reset(applicationError: UInt64) async {
        let first = core.state.withLock { state -> Bool in
            guard state.sentResetCode == nil, !state.didCancel else { return false }
            state.sentResetCode = applicationError
            return true
        }
        guard first else { return }
        connection.quicMetadata?.streamApplicationErrorCode = applicationError
        _ = core.markClosed()
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let done = core.state.withLock { state -> Bool in
                if state.didCancel { return true }
                state.cancelWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() } else { connection.cancel() }
        }
    }

    /// Asks the peer to stop sending with STOP_SENDING(`applicationError`). Network.framework
    /// has no call that sends only STOP_SENDING, so this is ``reset(applicationError:)``: the
    /// whole local end is abandoned with the code.
    public func stopSending(applicationError: UInt64) async {
        await reset(applicationError: applicationError)
    }
}

/// `reset(applicationError:)` and `stopSending(applicationError:)` above are the HTTPCore
/// stream-reset capability HTTP/3 uses for stream errors (#0101).
extension QUICStreamTransport: ResettableStream {}

/// A peer RESET_STREAM or STOP_SENDING moves the stream `NWConnection` to `.failed(ECONNRESET)`
/// even when no receive or send is pending (observed on macOS 27, #0104), so
/// ``waitForPeerAbort()`` returns on the stream failing or ending, or on a receive or send
/// failing with ``TransportError/connectionReset``.
extension QUICStreamTransport: PeerAbortObserving {
    public func waitForPeerAbort() async {
        let id = core.state.withLock { state -> UInt64 in
            defer { state.nextAbortWaiterID &+= 1 }
            return state.nextAbortWaiterID
        }
        await withTaskCancellationHandler {
            await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
                let now = core.state.withLock { state -> Bool in
                    if state.peerAborted || state.failure != nil || state.didCancel || Task.isCancelled { return true }
                    state.abortWaiters[id] = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            core.state.withLock { $0.abortWaiters.removeValue(forKey: id) }?.resume()
        }
    }
}

// MARK: - Core

extension QUICStreamTransport {
    enum ReceiveOutcome: Sendable {
        case data(Data)
        case endOfStream
        case failure(TransportError)
        case cancelled
        case retry
    }

    enum ReceiveStart {
        case proceed
        case endOfStream
    }

    /// Stream state shared by the NW callbacks (on the connection's queue) and the tasks using
    /// the stream. Holds no reference to the `NWConnection`, so its handlers form no cycle.
    final class Core: Sendable {
        struct State {
            var streamID: UInt64?
            var info = ConnectionInfo(isSecure: true)
            var failure: TransportError?
            var receive = QUICStreamState()
            var readyWaiter: UnsafeContinuation<Void, any Error>?
            var receiver: UnsafeContinuation<ReceiveOutcome, Never>?
            var sender: UnsafeContinuation<Void, any Error>?
            var receiving = false
            var sending = false
            var outputShutdown = false
            var closedLocally = false
            var closeCalled = false
            var didCancel = false
            var finishedReported = false
            var cancelWaiters: [UnsafeContinuation<Void, Never>] = []
            var sentResetCode: UInt64?
            var receivedResetCode: UInt64?
            var receivedStopSendingCode: UInt64?
            /// Set once the peer reset the stream or sent STOP_SENDING (a receive or send failed
            /// with a reset, or the stream failed); ``waitForPeerAbort()`` waiters are resumed.
            var peerAborted = false
            var abortWaiters: [UInt64: UnsafeContinuation<Void, Never>] = [:]
            var nextAbortWaiterID: UInt64 = 0

            /// Marks the peer abort and takes the waiters to resume after the lock.
            mutating func takeAbortWaiters() -> [UnsafeContinuation<Void, Never>] {
                peerAborted = true
                guard !abortWaiters.isEmpty else { return [] }
                defer { abortWaiters = [:] }
                return Array(abortWaiters.values)
            }

            var terminalError: TransportError? {
                if closedLocally { return .closed }
                if let failure { return failure }
                if didCancel { return .closed }
                return nil
            }
        }

        let state = Mutex(State())
        let events: Events

        init(events: Events) {
            self.events = events
        }

        // MARK: Receive

        func beginReceive(canReceive: Bool) throws(TransportError) -> ReceiveStart {
            try state.withLock { state throws(TransportError) -> ReceiveStart in
                if state.closedLocally { throw .closed }
                if state.receiving { throw .receiveAlreadyPending }
                if let error = state.receive.inputError { throw error }
                if state.receive.inputEnded || !canReceive { return .endOfStream }
                if let error = state.terminalError { throw error }
                state.receiving = true
                return .proceed
            }
        }

        func install(receiver continuation: UnsafeContinuation<ReceiveOutcome, Never>) -> Bool {
            let immediate: ReceiveOutcome? = state.withLock { state in
                if Task.isCancelled { return .cancelled }
                if let error = state.terminalError { return .failure(error) }
                state.receiver = continuation
                return nil
            }
            guard let immediate else { return true }
            continuation.resume(returning: immediate)
            return false
        }

        func completeReceive(data: Data?, isComplete: Bool, error: NWError?, peerCode: UInt64?) {
            var aborted: [UnsafeContinuation<Void, Never>] = []
            defer { for waiter in aborted { waiter.resume() } }
            let resumed: (UnsafeContinuation<ReceiveOutcome, Never>, ReceiveOutcome)? = state.withLock { state in
                guard let receiver = state.receiver else { return nil }   // cancelled or closed
                state.receiver = nil
                let mapped = error.map { state.closedLocally ? TransportError.closed : TransportError(quic: $0) }
                if mapped == .connectionReset {
                    aborted = state.takeAbortWaiters()
                    if state.receivedResetCode == nil, let peerCode, peerCode != state.sentResetCode {
                        state.receivedResetCode = peerCode
                    }
                }
                let count = data?.count ?? 0
                switch state.receive.handle(.received(byteCount: count, isComplete: isComplete, error: mapped)) {
                case .deliver: return (receiver, .data(data!))
                case .endOfStream: return (receiver, .endOfStream)
                case .fail(let error): return (receiver, .failure(error))
                case .retry: return (receiver, .retry)
                }
            }
            if let (receiver, outcome) = resumed { receiver.resume(returning: outcome) }
        }

        // MARK: Send

        func beginSend(endOfStream: Bool, canSend: Bool) throws(TransportError) {
            try state.withLock { state throws(TransportError) in
                if state.closedLocally { throw .closed }
                if state.outputShutdown || !canSend { throw .outputShutdown }
                if let error = state.terminalError { throw error }
                precondition(!state.sending, "QUICStreamTransport: concurrent send calls")
                state.sending = true
                if endOfStream { state.outputShutdown = true }
            }
        }

        func install(sender continuation: UnsafeContinuation<Void, any Error>) -> Bool {
            let immediate: (any Error)? = state.withLock { state in
                if Task.isCancelled { return CancellationError() }
                if let error = state.terminalError { return error }
                state.sender = continuation
                return nil
            }
            guard let immediate else { return true }
            continuation.resume(throwing: immediate)
            return false
        }

        func completeSend(error: NWError?, peerCode: UInt64?) {
            var aborted: [UnsafeContinuation<Void, Never>] = []
            defer { for waiter in aborted { waiter.resume() } }
            let resumed: (UnsafeContinuation<Void, any Error>, TransportError?)? = state.withLock { state in
                guard let sender = state.sender else { return nil }
                state.sender = nil
                let mapped = error.map { state.closedLocally ? TransportError.closed : TransportError(quic: $0) }
                if mapped == .connectionReset {
                    aborted = state.takeAbortWaiters()
                    if state.receivedStopSendingCode == nil, let peerCode, peerCode != state.sentResetCode {
                        state.receivedStopSendingCode = peerCode
                    }
                }
                return (sender, mapped)
            }
            guard let (sender, error) = resumed else { return }
            if let error { sender.resume(throwing: error) } else { sender.resume() }
        }

        // MARK: Cancellation and close

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

        /// Marks the stream closed locally and fails operations in progress with
        /// ``TransportError/closed``. Returns false if `close` already ran.
        func markClosed() -> Bool {
            let taken = state.withLock { state -> (UnsafeContinuation<ReceiveOutcome, Never>?, UnsafeContinuation<Void, any Error>?, UnsafeContinuation<Void, any Error>?)? in
                if state.closeCalled { return nil }
                state.closeCalled = true
                state.closedLocally = true
                defer { state.receiver = nil; state.sender = nil; state.readyWaiter = nil }
                return (state.receiver, state.sender, state.readyWaiter)
            }
            guard let taken else { return false }
            taken.0?.resume(returning: .failure(.closed))
            taken.1?.resume(throwing: TransportError.closed)
            taken.2?.resume(throwing: TransportError.closed)
            return true
        }

        // MARK: State

        func handle(_ newState: NWConnection.State, connection: NWConnection?) {
            switch newState {
            case .ready:
                guard let connection else { return }
                let metadata = connection.quicMetadata
                let id = metadata?.streamIdentifier ?? .max
                let info = ConnectionInfo(
                    localAddress: TransportAddress(connection.currentPath?.localEndpoint),
                    remoteAddress: TransportAddress(connection.currentPath?.remoteEndpoint ?? connection.endpoint),
                    isSecure: true,
                    negotiatedALPN: metadata?.negotiatedALPN)
                let waiter = state.withLock { state -> UnsafeContinuation<Void, any Error>?? in
                    guard state.streamID == nil else { return nil }
                    state.streamID = id
                    state.info = info
                    defer { state.readyWaiter = nil }
                    return .some(state.readyWaiter)
                }
                guard let waiter else { return }
                events.ready(id)
                waiter?.resume()
            case .failed(let error):
                fail(TransportError(quic: error))
                connection?.cancel()
            case .cancelled:
                finishCancelled()
                connection?.stateUpdateHandler = nil
            case .setup, .preparing, .waiting:
                // A stream waiting for stream credit or for the group stays here; the group's
                // state decides the connection's fate.
                break
            @unknown default:
                break
            }
        }

        /// The connection ended: operations in progress and later ones fail with `error`
        /// (``TransportError/closed`` if this end was already closed).
        func terminate(with error: TransportError) {
            fail(error)
        }

        private func fail(_ error: TransportError) {
            let taken = state.withLock { state in
                if state.failure == nil { state.failure = error }
                let error = state.closedLocally ? TransportError.closed : error
                defer { state.readyWaiter = nil; state.receiver = nil; state.sender = nil }
                return (error, state.readyWaiter, state.receiver, state.sender, state.takeAbortWaiters())
            }
            for waiter in taken.4 { waiter.resume() }
            taken.1?.resume(throwing: taken.0)
            taken.2?.resume(returning: .failure(taken.0))
            taken.3?.resume(throwing: taken.0)
        }

        private func finishCancelled() {
            let taken = state.withLock { state in
                state.didCancel = true
                let report = !state.finishedReported
                state.finishedReported = true
                let aborted = state.abortWaiters.values
                state.abortWaiters = [:]
                defer { state.readyWaiter = nil; state.receiver = nil; state.sender = nil; state.cancelWaiters = [] }
                return (state.readyWaiter, state.receiver, state.sender, state.cancelWaiters, report, state.streamID, Array(aborted))
            }
            for waiter in taken.6 { waiter.resume() }
            taken.0?.resume(throwing: TransportError.closed)
            taken.1?.resume(returning: .failure(.closed))
            taken.2?.resume(throwing: TransportError.closed)
            for waiter in taken.3 { waiter.resume() }
            if taken.4 { events.finished(taken.5) }
        }
    }
}
