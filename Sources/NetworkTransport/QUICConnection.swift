public import HTTPCore
import Dispatch
import Foundation
import Network
import Synchronization

/// A QUIC connection (one `NWConnectionGroup`) as a ``MultiplexedTransport`` (issue #0098,
/// ROADMAP §6 Option A). Server connections come from ``QUICListener``; clients use
/// ``connect(host:port:configuration:)``.
///
/// ## Inbound streams
///
/// `group.newConnectionHandler` hands over every peer stream. Each is started at once (its ID
/// is only known when it is ready) and held until ``inboundStreams`` takes it. At most
/// ``QUICConfiguration/pendingStreamLimit`` are held; a stream beyond that is reset with
/// ``QUICConfiguration/rejectedStreamErrorCode``. Nothing is buffered without bound: the
/// peer can only open as many streams as it has credit for, and credit comes back only when
/// a peer stream finishes.
///
/// ## Stream credit (MAX_STREAMS)
///
/// Network.framework does not replenish stream credit (spike gotcha 5). Each time a
/// peer-initiated stream finishes (is closed or fails), the adapter raises the group's
/// `localMaxStreamsBidirectional` / `localMaxStreamsUnidirectional` by one, so the peer can
/// keep ``QUICConfiguration/maxStreamsBidirectional`` streams open indefinitely.
///
/// ## Close
///
/// ``close(applicationError:)`` sets the group's `applicationError`, resets every stream
/// (including inbound streams never taken; the Network.framework client's implicit stream that
/// never becomes ready is cancelled), then cancels the group: `group.cancel()` alone does nothing while
/// a stream is alive (spike gotcha 6). Whether the code reaches the peer's CONNECTION_CLOSE is
/// unverified (spike Q6, #0104); a Network.framework peer never exposes it.
///
/// Peer close or failure ends ``inboundStreams`` (it throws only for errors other than a reset
/// or close, such as ``TransportError/timedOut``), fails waiting opens, and fails every stream.
///
/// All Network.framework callbacks of the group and its streams run on one serial queue.
public final class QUICConnection: MultiplexedTransport, StreamCreditGranting {
    public typealias Stream = QUICStreamTransport

    let group: NWConnectionGroup
    let queue: DispatchQueue
    let core: Core
    public let configuration: QUICConfiguration

    init(
        group: NWConnectionGroup,
        configuration: QUICConfiguration,
        remote: NWEndpoint?,
        onUsable: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.group = group
        self.configuration = configuration
        let queue = DispatchQueue(label: "sws.quic.connection")
        self.queue = queue
        let core = Core(configuration: configuration, queue: queue, group: group, onUsable: onUsable)
        core.state.withLock { $0.info.remoteAddress = TransportAddress(remote) }
        self.core = core
        // Both handlers before `start` (a client group without `newConnectionHandler` never
        // leaves setup, spike gotcha 3).
        group.stateUpdateHandler = { [core] state in core.handle(state) }
        group.newConnectionHandler = { [core] stream in core.accept(stream) }
    }

    func startGroup() {
        group.start(queue: queue)
    }

    deinit {
        core.abandon()
    }

    // MARK: Client

    /// Opens a QUIC connection to `host:port` and returns once the handshake is done.
    /// Throws ``TransportError/timedOut`` after ``QUICClientConfiguration/connectTimeout``.
    public static func connect(
        host: String,
        port: UInt16,
        configuration: QUICClientConfiguration = QUICClientConfiguration()
    ) async throws -> QUICConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            throw TransportError.failed(code: EINVAL)
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: configuration.makeParameters())
        let connection = QUICConnection(group: group, configuration: configuration.quic, remote: endpoint)
        connection.startGroup()
        let timeout = configuration.connectTimeout
        do {
            let ready = try await withThrowingTaskGroup(of: Bool.self) { tasks in
                tasks.addTask {
                    try await connection.core.waitUntilUsable()
                    return true
                }
                tasks.addTask {
                    try await Task.sleep(for: timeout)
                    return false
                }
                defer { tasks.cancelAll() }
                return try await tasks.next() ?? false
            }
            guard ready else { throw TransportError.timedOut }
        } catch {
            connection.core.abandon()
            throw error
        }
        return connection
    }

    // MARK: MultiplexedTransport

    /// Streams opened by the peer, ready (with an ID), in the order they became ready. One
    /// consumer at a time. Ends when the connection closes; cancelling a waiting `next()` ends
    /// iteration.
    public var inboundStreams: InboundStreams { InboundStreams(core: core) }

    /// Opens a locally initiated unidirectional stream and returns once it is ready (it waits
    /// while the peer's unidirectional stream credit is used up).
    public func openUnidirectionalStream() async throws -> QUICStreamTransport {
        try await core.open(unidirectional: true)
    }

    /// Opens a locally initiated bidirectional stream (clients send requests on these).
    public func openBidirectionalStream() async throws -> QUICStreamTransport {
        try await core.open(unidirectional: false)
    }

    /// Raises the cumulative stream limits the peer may open (MAX_STREAMS) to at least these
    /// values (#0102). The adapter already returns one stream of credit per finished peer
    /// stream; this lets a protocol set a higher concurrency than
    /// ``QUICConfiguration/maxStreamsBidirectional``. Applied on the connection's queue.
    public func raiseMaxStreams(bidirectional: UInt64?, unidirectional: UInt64?) {
        let clamp = { (value: UInt64?) -> Int in value.map { Int(clamping: $0) } ?? 0 }
        let (bidirectional, unidirectional) = (clamp(bidirectional), clamp(unidirectional))
        queue.async { [core] in
            core.raiseAtLeast(bidirectional: bidirectional, unidirectional: unidirectional)
        }
    }

    /// Closes the connection with an application error code. Idempotent: the first close wins.
    /// Returns once the group is cancelled.
    public func close(applicationError: UInt64) async {
        await core.close(applicationError: applicationError)
    }

    // MARK: Observability

    /// ALPN and addresses, known once the connection is usable.
    public var info: ConnectionInfo { core.state.withLock { $0.info } }
    /// The code this side closed the connection with.
    public var closeApplicationError: UInt64? { core.state.withLock { $0.closeApplicationError } }
    /// Why the connection ended, when it was not closed locally.
    public var terminationError: TransportError? { core.state.withLock { $0.terminationError } }
    /// True once the connection is closing, closed or failed.
    public var isClosed: Bool { core.state.withLock { $0.machine.isTerminal } }
    /// Peer streams held for ``inboundStreams`` (opening or ready).
    public var pendingInboundCount: Int { core.state.withLock { $0.pendingCount } }
    /// Peer streams reset because the pending queue was full.
    public var rejectedStreamCount: Int { core.state.withLock { $0.rejected } }
    /// Streams of this connection not yet finished (both directions, any initiator).
    public var liveStreamCount: Int { core.state.withLock { $0.live.count } }
    /// The cumulative number of bidirectional streams the peer may open (MAX_STREAMS).
    public var maxStreamsBidirectional: Int { core.state.withLock { $0.machine.maxStreamsBidirectional } }
    /// The cumulative number of unidirectional streams the peer may open (MAX_STREAMS).
    public var maxStreamsUnidirectional: Int { core.state.withLock { $0.machine.maxStreamsUnidirectional } }

    // MARK: Inbound streams

    /// A demand-driven sequence of peer streams: `next()` takes one from the bounded pending
    /// queue or suspends until one is ready.
    public struct InboundStreams: AsyncSequence, Sendable {
        public typealias Element = QUICStreamTransport
        public typealias Failure = any Error
        let core: Core

        public func makeAsyncIterator() -> Iterator { Iterator(core: core) }

        public struct Iterator: AsyncIteratorProtocol {
            public typealias Element = QUICStreamTransport
            public typealias Failure = any Error
            let core: Core

            public mutating func next() async throws -> QUICStreamTransport? {
                try await core.next()
            }

            public mutating func next(isolation actor: isolated (any Actor)?) async throws -> QUICStreamTransport? {
                try await core.next()
            }
        }
    }
}

// MARK: - Core

extension QUICConnection {
    /// Connection state shared by the group callbacks (on the queue) and the tasks using the
    /// connection. Critical sections never suspend; continuations resume after the lock.
    final class Core: Sendable {
        struct LiveStream {
            let connection: NWConnection
            let core: QUICStreamTransport.Core
        }

        struct State {
            var machine: QUICConnectionState
            var info = ConnectionInfo(isSecure: true)
            /// Peer streams not yet ready.
            var preparing: [ObjectIdentifier: QUICStreamTransport] = [:]
            /// Ready peer streams not yet taken; `ready[readyHead...]` is the queue.
            var ready: [QUICStreamTransport] = []
            var readyHead = 0
            var consumer: UnsafeContinuation<QUICStreamTransport?, any Error>?
            /// Every stream not yet finished, for close (keyed by its NWConnection).
            var live: [ObjectIdentifier: LiveStream] = [:]
            /// Tasks waiting for the connection to become (more) usable, by waiter ID.
            var waiters: [UInt64: UnsafeContinuation<Void, any Error>] = [:]
            /// Bumped on every usability event, so a waiter never misses one.
            var generation: UInt64 = 0
            var nextWaiterID: UInt64 = 0
            var closeWaiters: [UnsafeContinuation<Void, Never>] = []
            var didCancel = false
            var closeApplicationError: UInt64?
            var terminationError: TransportError?
            var rejected = 0
            var onUsable: (@Sendable (Bool) -> Void)?
            /// A group we can no longer reach after it was cancelled.
            weak var group: NWConnectionGroup?

            var pendingCount: Int { preparing.count + ready.count - readyHead }

            mutating func popReady() -> QUICStreamTransport? {
                guard readyHead < ready.count else { return nil }
                let stream = ready[readyHead]
                readyHead += 1
                if readyHead == ready.count {
                    ready.removeAll(keepingCapacity: true)
                    readyHead = 0
                } else if readyHead >= 32 && readyHead * 2 >= ready.count {
                    ready.removeFirst(readyHead)
                    readyHead = 0
                }
                return stream
            }

            /// The error a new open fails with, or `nil` while the connection is usable.
            var openError: TransportError? {
                switch machine.phase {
                case .setup, .ready: nil
                case .closing, .closed: closeApplicationError != nil ? .closed : (terminationError ?? .closed)
                case .failed(let error): error
                }
            }
        }

        let state: Mutex<State>
        let configuration: QUICConfiguration
        let queue: DispatchQueue
        let uniOptions: NWProtocolQUIC.Options

        init(configuration: QUICConfiguration, queue: DispatchQueue, group: NWConnectionGroup,
             onUsable: (@Sendable (Bool) -> Void)?) {
            self.configuration = configuration
            self.queue = queue
            self.uniOptions = configuration.makeUnidirectionalStreamOptions()
            var initial = State(machine: QUICConnectionState(
                initialMaxStreamsBidirectional: configuration.maxStreamsBidirectional,
                initialMaxStreamsUnidirectional: configuration.maxStreamsUnidirectional))
            initial.group = group
            initial.onUsable = onUsable
            state = Mutex(initial)
        }

        // MARK: Inbound

        /// `group.newConnectionHandler`: admit the stream into the bounded queue or refuse it.
        func accept(_ connection: NWConnection) {
            let key = ObjectIdentifier(connection)
            let admitted = state.withLock { state -> Bool in
                guard !state.machine.isTerminal, state.pendingCount < configuration.effectivePendingStreamLimit else {
                    state.rejected += 1
                    return false
                }
                return true
            }
            guard admitted else {
                connection.quicMetadata?.streamApplicationErrorCode = configuration.rejectedStreamErrorCode
                connection.cancel()
                return
            }
            let stream = QUICStreamTransport(
                connection: connection, isLocallyInitiated: false, chunkSize: configuration.sendChunkSize,
                events: QUICStreamTransport.Events(
                    ready: { [self] _ in self.inboundReady(key) },
                    finished: { [self] id in self.streamFinished(key, streamID: id, locallyInitiated: false) }))
            state.withLock { state in
                state.preparing[key] = stream
                state.live[key] = LiveStream(connection: connection, core: stream.core)
            }
            stream.start(queue: queue)
        }

        private func inboundReady(_ key: ObjectIdentifier) {
            var action = QUICConnectionState.Action.none
            let work = state.withLock { state -> (UnsafeContinuation<QUICStreamTransport?, any Error>?, QUICStreamTransport?, [UnsafeContinuation<Void, any Error>], (@Sendable (Bool) -> Void)?) in
                guard let stream = state.preparing.removeValue(forKey: key) else { return (nil, nil, [], nil) }
                action = state.machine.handle(.inboundStreamReady)
                state.info.merge(stream.info)
                state.generation &+= 1
                let waiters = Array(state.waiters.values)
                state.waiters = [:]
                var onUsable: (@Sendable (Bool) -> Void)?
                if action == .becomeUsable {
                    onUsable = state.onUsable
                    state.onUsable = nil
                }
                if let consumer = state.consumer {
                    state.consumer = nil
                    return (consumer, stream, waiters, onUsable)
                }
                state.ready.append(stream)
                return (nil, nil, waiters, onUsable)
            }
            if let consumer = work.0 { consumer.resume(returning: work.1) }
            for waiter in work.2 { waiter.resume() }
            work.3?(true)
        }

        /// A stream ended. Peer streams return their credit (MAX_STREAMS).
        private func streamFinished(_ key: ObjectIdentifier, streamID: UInt64?, locallyInitiated: Bool) {
            let (action, group) = state.withLock { state -> (QUICConnectionState.Action, NWConnectionGroup?) in
                state.live.removeValue(forKey: key)
                state.preparing.removeValue(forKey: key)
                guard !locallyInitiated, let streamID, streamID != .max else { return (.none, nil) }
                return (state.machine.handle(.peerStreamFinished(unidirectional: streamID & 0x2 != 0)), state.group)
            }
            if case .raiseMaxStreams(let bidirectional, let unidirectional) = action {
                Self.grant(group, bidirectional: bidirectional, unidirectional: unidirectional)
            }
        }

        /// A protocol's credit grant (on the queue): raises the group's limits, never lowers them.
        func raiseAtLeast(bidirectional: Int, unidirectional: Int) {
            let group = state.withLock { $0.machine.isTerminal ? nil : $0.group }
            Self.grant(group, bidirectional: bidirectional, unidirectional: unidirectional)
        }

        /// Raises the cumulative stream limits the peer may open (never lowers them).
        private static func grant(_ group: NWConnectionGroup?, bidirectional: Int, unidirectional: Int) {
            guard let metadata = group?.quicMetadata else { return }   // applied on group ready
            if metadata.localMaxStreamsBidirectional < bidirectional {
                metadata.localMaxStreamsBidirectional = bidirectional
            }
            if metadata.localMaxStreamsUnidirectional < unidirectional {
                metadata.localMaxStreamsUnidirectional = unidirectional
            }
        }

        func next() async throws -> QUICStreamTransport? {
            try await withTaskCancellationHandler {
                try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<QUICStreamTransport?, any Error>) in
                    let immediate: Result<QUICStreamTransport?, any Error>? = state.withLock { state in
                        if let stream = state.popReady() { return .success(stream) }
                        if state.machine.isTerminal { return Self.endOfInbound(state.terminationError) }
                        if Task.isCancelled { return .success(nil) }
                        precondition(state.consumer == nil, "QUICConnection.inboundStreams: concurrent next() calls")
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
                consumer?.resume(returning: nil)
            }
        }

        /// Inbound iteration ends quietly on close or peer close, and throws other failures.
        private static func endOfInbound(_ error: TransportError?) -> Result<QUICStreamTransport?, any Error> {
            switch error {
            case nil, .closed?, .connectionReset?: .success(nil)
            case let error?: .failure(error)
            }
        }

        // MARK: Open

        func open(unidirectional: Bool) async throws -> QUICStreamTransport {
            var connection: NWConnection?
            while connection == nil {
                try Task.checkCancellation()
                let (group, generation, groupReady) = try state.withLock { state throws(TransportError) in
                    if let error = state.openError { throw error }
                    return (state.group, state.generation, state.group?.state == .ready)
                }
                guard let group else { throw TransportError.closed }
                // `NWConnection(from:)` returns nil until the group can open streams.
                connection = NWConnection(from: group, using: unidirectional ? uniOptions : nil)
                if connection == nil {
                    if groupReady { throw TransportError.failed(code: EINVAL) }
                    try await waitForChange(after: generation)
                }
            }
            let nwConnection = connection!
            let key = ObjectIdentifier(nwConnection)
            let stream = QUICStreamTransport(
                connection: nwConnection, isLocallyInitiated: true, chunkSize: configuration.sendChunkSize,
                events: QUICStreamTransport.Events(
                    ready: { _ in },
                    finished: { [self] id in self.streamFinished(key, streamID: id, locallyInitiated: true) }))
            let failure = state.withLock { state -> TransportError? in
                if let error = state.openError { return error }
                state.live[key] = LiveStream(connection: nwConnection, core: stream.core)
                return nil
            }
            if let failure {
                nwConnection.cancel()
                throw failure
            }
            stream.start(queue: queue)
            try await stream.waitUntilReady()
            return stream
        }

        /// Suspends until the next usability event after `generation` (group ready, a peer
        /// stream ready, or termination, which throws).
        func waitForChange(after generation: UInt64) async throws {
            let id = state.withLock { state in
                state.nextWaiterID &+= 1
                return state.nextWaiterID
            }
            try await withTaskCancellationHandler {
                try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
                    let immediate: Result<Void, any Error>? = state.withLock { state in
                        if let error = state.openError { return .failure(error) }
                        if state.generation != generation { return .success(()) }
                        if Task.isCancelled { return .failure(CancellationError()) }
                        state.waiters[id] = continuation
                        return nil
                    }
                    if let immediate { continuation.resume(with: immediate) }
                }
            } onCancel: {
                let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
                waiter?.resume(throwing: CancellationError())
            }
        }

        /// Suspends until the connection is usable (client connect).
        func waitUntilUsable() async throws {
            while true {
                let generation = try state.withLock { state throws(TransportError) -> UInt64? in
                    if let error = state.openError { throw error }
                    return state.machine.phase == .ready ? nil : state.generation
                }
                guard let generation else { return }
                try await waitForChange(after: generation)
            }
        }

        // MARK: Group state

        func handle(_ newState: NWConnectionGroup.State) {
            switch newState {
            case .ready:
                let alpn = state.withLock { $0.group }?.quicMetadata?.negotiatedALPN
                let work = state.withLock { state in
                    let action = state.machine.handle(.groupReady)
                    if state.info.negotiatedALPN == nil { state.info.negotiatedALPN = alpn }
                    state.generation &+= 1
                    let waiters = Array(state.waiters.values)
                    state.waiters = [:]
                    var onUsable: (@Sendable (Bool) -> Void)?
                    if action == .becomeUsable {
                        onUsable = state.onUsable
                        state.onUsable = nil
                    }
                    return (action, waiters, onUsable, state.group)
                }
                for waiter in work.1 { waiter.resume() }
                if case .raiseMaxStreams(let bidirectional, let unidirectional) = work.0 {
                    Self.grant(work.3, bidirectional: bidirectional, unidirectional: unidirectional)
                }
                work.2?(true)
            case .waiting:
                // Every group reports `waiting(ENETDOWN)` first (spike gotcha 7): not a failure.
                // A client whose verify block refuses the server's certificate also just stays
                // here (no TLS error is reported), so `connect` relies on its timeout.
                break
            case .failed(let error):
                let mapped = TransportError(quic: error)
                let action = state.withLock { $0.machine.handle(.groupFailed(mapped)) }
                if case .tearDown(let error) = action { tearDown(error) }
            case .cancelled:
                let action = state.withLock { $0.machine.handle(.groupCancelled) }
                if case .tearDown(let error) = action { tearDown(error) }
                finishCancelled()
            case .setup:
                break
            @unknown default:
                break
            }
        }

        /// The connection ended without a local close: fail everything, cancel every stream,
        /// then the group.
        private func tearDown(_ error: TransportError) {
            let work = state.withLock { state in
                state.terminationError = error
                defer {
                    state.consumer = nil; state.waiters = [:]; state.onUsable = nil
                    state.preparing = [:]; state.ready = []; state.readyHead = 0
                }
                return (state.consumer, Array(state.waiters.values), state.onUsable, Array(state.live.values), state.group)
            }
            work.0?.resume(with: Self.endOfInbound(error))
            for waiter in work.1 { waiter.resume(throwing: error) }
            work.2?(false)
            for stream in work.3 {
                stream.core.terminate(with: error)
                stream.connection.forceCancel()
            }
            work.4?.cancel()
        }

        private func finishCancelled() {
            let waiters = state.withLock { state in
                state.didCancel = true
                defer { state.closeWaiters = [] }
                return state.closeWaiters
            }
            for waiter in waiters { waiter.resume() }
            // Drop the handlers so nothing retains this core through the group.
            if let group = state.withLock({ $0.group }) {
                group.stateUpdateHandler = nil
                group.newConnectionHandler = nil
            }
        }

        // MARK: Close

        func close(applicationError: UInt64) async {
            beginClose(applicationError: applicationError)
            await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
                let done = state.withLock { state -> Bool in
                    if state.didCancel || state.group == nil { return true }
                    state.closeWaiters.append(continuation)
                    return false
                }
                if done { continuation.resume() }
            }
        }

        /// Closes without waiting (deinit, failed connect).
        func abandon() {
            beginClose(applicationError: 0)
        }

        private func beginClose(applicationError: UInt64) {
            let work = state.withLock { state -> (UnsafeContinuation<QUICStreamTransport?, any Error>?, [UnsafeContinuation<Void, any Error>], (@Sendable (Bool) -> Void)?, [LiveStream], NWConnectionGroup?)? in
                guard state.machine.handle(.closeRequested) == .beginClose else { return nil }
                state.closeApplicationError = applicationError
                defer {
                    state.consumer = nil; state.waiters = [:]; state.onUsable = nil
                    state.preparing = [:]; state.ready = []; state.readyHead = 0
                }
                return (state.consumer, Array(state.waiters.values), state.onUsable, Array(state.live.values), state.group)
            }
            guard let work else { return }
            work.0?.resume(returning: nil)
            for waiter in work.1 { waiter.resume(throwing: TransportError.closed) }
            work.2?(false)
            if let group = work.4 {
                // The reason must not be nil: the setter crashes (SIGSEGV) without one.
                group.quicMetadata?.applicationError = NWProtocolQUIC.ApplicationError(code: applicationError, reason: "")
            }
            // Every stream first, then the group (spike gotcha 6). Each ready stream is reset
            // (`forceCancel`, RESET_STREAM 0): a plain `cancel()` can look like FIN to the peer
            // (gotcha 9), which would make a truncated response look complete. Setting
            // `streamApplicationErrorCode` here instead made a spurious server-initiated
            // stream (ID 1) appear at a Network.framework peer. A stream that never became
            // ready (the NW client's implicit stream, gotcha 8) is only cancelled.
            for stream in work.3 {
                _ = stream.core.markClosed()
                if stream.core.state.withLock({ $0.streamID != nil }) {
                    stream.connection.forceCancel()
                } else {
                    stream.connection.cancel()
                }
            }
            work.4?.cancel()
        }
    }
}

extension ConnectionInfo {
    /// Fills fields that are still unknown from `other`.
    mutating func merge(_ other: ConnectionInfo) {
        if localAddress == nil { localAddress = other.localAddress }
        if remoteAddress == nil { remoteAddress = other.remoteAddress }
        if negotiatedALPN == nil { negotiatedALPN = other.negotiatedALPN }
        isSecure = isSecure || other.isSecure
    }
}
