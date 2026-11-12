public import HTTPCore
import Synchronization

/// An in-memory, QUIC-like ``MultiplexedTransport`` for HTTP/3 tests (docs/ROADMAP.md §4, §6;
/// issue #0099).
///
/// It mimics the Network.framework QUIC semantics recorded in `docs/spikes/quic-spike.md`:
///
/// - **Stream IDs** follow RFC 9000 §2.1: client bidi 0, 4, 8…; server bidi 1, 5, 9…; client
///   uni 2, 6, 10…; server uni 3, 7, 11…. A stream reaches the peer's ``inboundStreams`` when it
///   is opened, so the order of `open` calls is the order of arrival.
/// - **FIN**: `send(_:endOfStream: true)` makes the peer's `receive` return 0 after the data
///   (NW `isComplete`).
/// - **RESET_STREAM** (``Stream/reset(applicationError:)``): the peer's `receive` throws
///   ``TransportError/connectionReset`` and afterwards ``Stream/receivedResetCode`` reads the
///   code (NW: `streamApplicationErrorCode` after `ECONNRESET`). Unread bytes are discarded.
/// - **STOP_SENDING** (``Stream/stopSending(applicationError:)``): the peer's sends throw
///   ``TransportError/connectionReset`` and ``Stream/receivedStopSendingCode`` reads the code.
///   The peer answers with RESET_STREAM carrying the same code (RFC 9000 §3.5).
/// - **Connection close** (``close(applicationError:)``): every stream fails, pending openers
///   fail, and both sides' ``inboundStreams`` end. Operations on the closing side throw
///   ``TransportError/closed``; on the peer, ``TransportError/connectionReset``. Unlike NW, the
///   peer can read the code (``peerCloseApplicationError``) so tests can assert it.
/// - **MAX_STREAMS** is a *cumulative* count per direction type and is not replenished
///   automatically (spike gotcha 5): once a side has opened as many streams as its peer allows,
///   further opens suspend until the peer calls ``raiseMaxStreams(bidirectional:unidirectional:)``.
///
/// Each stream is a pair of ``InMemoryTransport`` endpoints, so per-stream backpressure,
/// receive chunking, delays (``Stream/play(_:)``) and sent-byte capture work exactly as for
/// HTTP/1.1 tests. `inboundStreams` is demand-driven: a stream is handed over only when the
/// consumer asks, and the number waiting is bounded by the stream limit.
///
/// Two modes: ``makePair(client:server:)`` (two connected endpoints) and
/// ``scripted(_:side:finishesInbound:configuration:)`` (a fixed list of inbound streams with
/// scripted traffic; locally opened streams only capture what is sent).
///
/// The connection keeps every stream it created until it is released, so it suits tests, not
/// long-running loads.
public final class InMemoryMultiplexedTransport: MultiplexedTransport {
    /// Which end of the connection a transport or stream endpoint is.
    public enum Side: Sendable, Hashable {
        case client, server

        public var peer: Side { self == .client ? .server : .client }

        var index: Int { self == .client ? 0 : 1 }
    }

    /// Settings for one side of the connection.
    public struct Configuration: Sendable {
        /// Pipe sizing, receive chunking and capture for this side's stream endpoints. Its
        /// `info` is replaced by ``info``.
        public var stream: InMemoryTransport.Configuration
        /// How many bidirectional streams this side lets the peer open in total
        /// (`initial_max_streams_bidi`).
        public var maxStreamsBidirectional: UInt64
        /// How many unidirectional streams this side lets the peer open in total
        /// (`initial_max_streams_uni`).
        public var maxStreamsUnidirectional: UInt64
        /// Reported by the transport and by each of this side's streams.
        public var info: ConnectionInfo

        public static let defaultServerInfo = ConnectionInfo(
            localAddress: TransportAddress(host: "127.0.0.1", port: 443),
            remoteAddress: TransportAddress(host: "127.0.0.1", port: 50000),
            isSecure: true, negotiatedALPN: "h3")

        public static let defaultClientInfo = ConnectionInfo(
            localAddress: TransportAddress(host: "127.0.0.1", port: 50000),
            remoteAddress: TransportAddress(host: "127.0.0.1", port: 443),
            isSecure: true, negotiatedALPN: "h3")

        public init(
            stream: InMemoryTransport.Configuration = InMemoryTransport.Configuration(),
            maxStreamsBidirectional: UInt64 = 100,
            maxStreamsUnidirectional: UInt64 = 100,
            info: ConnectionInfo = Configuration.defaultServerInfo
        ) {
            self.stream = stream
            self.maxStreamsBidirectional = maxStreamsBidirectional
            self.maxStreamsUnidirectional = maxStreamsUnidirectional
            self.info = info
        }

        /// A client-side configuration (client addresses in ``info``).
        public static func client(
            stream: InMemoryTransport.Configuration = InMemoryTransport.Configuration(),
            maxStreamsBidirectional: UInt64 = 100,
            maxStreamsUnidirectional: UInt64 = 100
        ) -> Configuration {
            Configuration(
                stream: stream, maxStreamsBidirectional: maxStreamsBidirectional,
                maxStreamsUnidirectional: maxStreamsUnidirectional, info: defaultClientInfo)
        }

        var streamConfiguration: InMemoryTransport.Configuration {
            var configuration = stream
            configuration.info = info
            return configuration
        }
    }

    /// One inbound stream of a scripted transport.
    public struct ScriptedStream: Sendable {
        /// A peer-initiated stream ID (RFC 9000 §2.1).
        public var streamID: UInt64
        /// What the peer sends on it.
        public var events: [InMemoryTransport.Event]

        public init(streamID: UInt64, events: [InMemoryTransport.Event]) {
            self.streamID = streamID
            self.events = events
        }

        /// A stream that carries `bytes` and then FIN.
        public init(streamID: UInt64, bytes: ByteBuffer) {
            self.init(streamID: streamID, events: [.bytes(bytes), .endOfStream])
        }
    }

    /// Which end of the connection this transport is.
    public let side: Side
    let connection: Connection

    init(side: Side, connection: Connection) {
        self.side = side
        self.connection = connection
    }

    // MARK: Construction

    /// A connected client/server pair.
    public static func makePair(
        client: Configuration = .client(),
        server: Configuration = Configuration()
    ) -> (client: InMemoryMultiplexedTransport, server: InMemoryMultiplexedTransport) {
        let connection = Connection(mode: .paired, client: client, server: server)
        return (
            InMemoryMultiplexedTransport(side: .client, connection: connection),
            InMemoryMultiplexedTransport(side: .server, connection: connection)
        )
    }

    /// One side of a connection whose peer is a script: ``inboundStreams`` yields `streams` in
    /// order, each receiving its scripted events (a scripted unidirectional stream refuses
    /// sends). After them, iteration ends if `finishesInbound`, otherwise it waits until the
    /// connection closes. Locally opened streams never block, capture what is sent, and
    /// receive end of stream at once.
    public static func scripted(
        _ streams: [ScriptedStream],
        side: Side = .server,
        finishesInbound: Bool = true,
        configuration: Configuration = Configuration()
    ) -> InMemoryMultiplexedTransport {
        let connection = Connection(mode: .scripted, client: configuration, server: configuration)
        connection.prepareScript(streams, side: side, finishesInbound: finishesInbound)
        return InMemoryMultiplexedTransport(side: side, connection: connection)
    }

    // MARK: MultiplexedTransport

    /// Streams opened by the peer, in the order they were opened. Ends when the connection
    /// closes; throws the injected error after ``fail(with:)``.
    public var inboundStreams: InboundStreams { InboundStreams(transport: self) }

    /// Opens a locally initiated unidirectional stream, suspending while the peer's
    /// unidirectional MAX_STREAMS credit is used up.
    public func openUnidirectionalStream() async throws -> Stream {
        try await connection.open(from: side, unidirectional: true)
    }

    /// Opens a locally initiated bidirectional stream, suspending while the peer's
    /// bidirectional MAX_STREAMS credit is used up.
    public func openBidirectionalStream() async throws -> Stream {
        try await connection.open(from: side, unidirectional: false)
    }

    /// Closes the connection with an application error code (CONNECTION_CLOSE). Idempotent:
    /// the first close (or failure) wins.
    public func close(applicationError: UInt64) async {
        await connection.terminate(.closed(by: side, applicationError: applicationError))
    }

    // MARK: Scripting hooks

    /// Grants the peer more stream credit (MAX_STREAMS). Limits only grow; a smaller value is
    /// ignored. Peer openers waiting for credit are resumed in order.
    public func raiseMaxStreams(bidirectional: UInt64? = nil, unidirectional: UInt64? = nil) {
        connection.raiseMaxStreams(grantedBy: side, bidirectional: bidirectional, unidirectional: unidirectional)
    }

    /// Fails the connection (for example an idle timeout): both sides' ``inboundStreams``
    /// throw `error`, pending and later opens throw it, and every stream is reset.
    public func fail(with error: TransportError) async {
        await connection.terminate(.failed(error))
    }

    // MARK: Inspection

    /// True once either side closed the connection or it failed.
    public var isClosed: Bool { connection.state.withLock { $0.termination != nil } }

    /// The application error code this side closed the connection with.
    public var closeApplicationError: UInt64? {
        connection.state.withLock { state in
            if case .closed(let by, let code) = state.termination, by == side { return code }
            return nil
        }
    }

    /// The application error code the peer closed the connection with.
    public var peerCloseApplicationError: UInt64? {
        connection.state.withLock { state in
            if case .closed(let by, let code) = state.termination, by != side { return code }
            return nil
        }
    }

    /// Total bidirectional streams this side lets the peer open.
    public var maxStreamsBidirectional: UInt64 {
        connection.state.withLock { $0.sides[side.peer.index].limit[0] }
    }

    /// Total unidirectional streams this side lets the peer open.
    public var maxStreamsUnidirectional: UInt64 {
        connection.state.withLock { $0.sides[side.peer.index].limit[1] }
    }

    /// Local opens suspended waiting for stream credit.
    public var blockedOpenCount: Int { connection.state.withLock { $0.sides[side.index].openers.count } }

    /// Streams the peer opened that ``inboundStreams`` has not yet handed over.
    public var pendingInboundCount: Int {
        connection.state.withLock { $0.sides[side.index].pending.count }
    }

    /// Streams this side opened, in order (for asserting on what code under test sent, such
    /// as an HTTP/3 control stream).
    public var openedStreams: [Stream] { connection.state.withLock { $0.sides[side.index].opened } }

    /// Reported for the connection; each stream reports the same.
    public var info: ConnectionInfo { connection.configuration(for: side).info }
}

// MARK: - Inbound streams

extension InMemoryMultiplexedTransport {
    /// The demand-driven sequence of peer-opened streams.
    public struct InboundStreams: AsyncSequence, Sendable {
        public typealias Element = Stream
        public typealias Failure = any Error

        let transport: InMemoryMultiplexedTransport

        public struct AsyncIterator: AsyncIteratorProtocol {
            public typealias Element = Stream
            public typealias Failure = any Error

            let transport: InMemoryMultiplexedTransport

            public mutating func next() async throws -> Stream? {
                try await transport.connection.nextInbound(for: transport.side)
            }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(transport: transport)
        }
    }
}

// MARK: - Stream

/// The in-memory stream's `reset(applicationError:)` and `stopSending(applicationError:)`
/// already have QUIC semantics (#0101).
extension InMemoryMultiplexedTransport.Stream: ResettableStream {}

/// ``InMemoryMultiplexedTransport/raiseMaxStreams(bidirectional:unidirectional:)`` is the
/// stream-credit API HTTP/3 uses (#0102).
extension InMemoryMultiplexedTransport: StreamCreditGranting {}

extension InMemoryMultiplexedTransport {
    /// One endpoint of a QUIC-like stream: a ``ByteStreamTransport`` with an RFC 9000 stream ID.
    public final class Stream: ByteStreamTransport, StreamIdentified, Sendable {
        public let streamID: UInt64
        /// Which side's endpoint of the stream this is.
        public let side: Side
        /// False for the receiving end of a unidirectional stream (sends throw
        /// ``TransportError/outputShutdown``).
        public let canSend: Bool
        /// False for the sending end of a unidirectional stream (receives return 0).
        public let canReceive: Bool

        let endpoint: InMemoryTransport
        let codes: Codes

        /// RESET_STREAM and STOP_SENDING codes of one stream, shared by both endpoints so each
        /// sees what the other sent.
        final class Codes: Sendable {
            struct Value {
                /// RESET_STREAM codes, by sending side index.
                var reset: [UInt64?] = [nil, nil]
                /// STOP_SENDING codes, by sending side index.
                var stopSending: [UInt64?] = [nil, nil]
            }

            let value = Mutex(Value())

        }

        init(streamID: UInt64, side: Side, endpoint: InMemoryTransport, codes: Codes,
             canSend: Bool, canReceive: Bool) {
            self.streamID = streamID
            self.side = side
            self.endpoint = endpoint
            self.codes = codes
            self.canSend = canSend
            self.canReceive = canReceive
        }

        /// True when this side opened the stream.
        public var isLocallyInitiated: Bool { isClientInitiated == (side == .client) }

        // MARK: ByteStreamTransport

        public func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
            try await endpoint.receive(into: &buffer, maxLength: maxLength)
        }

        public func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws {
            try await endpoint.send(bytes, endOfStream: endOfStream)
        }

        /// ``CloseReason/abort`` resets the sending direction and stops the receiving one with
        /// code 0 (NW `forceCancel`) unless they already finished; other reasons flush and FIN
        /// (NW `cancel()` without a code) and stop reading.
        public func close(_ reason: CloseReason) async {
            if reason.isAbortive && !endpoint.isClosed {
                let (outputOpen, inputOpen) = endpoint.state.withLock { (!$0.outputShutdown, !$0.inputEnded) }
                codes.value.withLock { codes in
                    if canSend && outputOpen && codes.reset[side.index] == nil { codes.reset[side.index] = 0 }
                    if canReceive && inputOpen && codes.stopSending[side.index] == nil {
                        codes.stopSending[side.index] = 0
                    }
                }
            }
            await endpoint.close(reason)
        }

        public var info: ConnectionInfo { endpoint.info }

        // MARK: Reset and STOP_SENDING

        /// Abandons the sending direction with RESET_STREAM(`applicationError`): unread bytes
        /// are discarded, the peer's receive throws ``TransportError/connectionReset``, and
        /// later local sends throw ``TransportError/outputShutdown``. Ignored when this end
        /// cannot send.
        public func reset(applicationError: UInt64) async {
            guard canSend else { return }
            endpoint.state.withLock { $0.outputShutdown = true }
            await Self.applyReset(from: side, code: applicationError, pipe: endpoint.outbound, codes: codes)
        }

        /// Asks the peer to stop sending with STOP_SENDING(`applicationError`). The peer's
        /// sends throw ``TransportError/connectionReset``; it answers with RESET_STREAM of the
        /// same code, so the local receive throws ``TransportError/connectionReset`` too.
        /// Ignored when this end cannot receive.
        public func stopSending(applicationError: UInt64) async {
            guard canReceive else { return }
            await Self.applyStopSending(from: side, code: applicationError, pipe: endpoint.inbound, codes: codes)
        }

        /// Behaves as if the peer sent RESET_STREAM(`applicationError`) (works in scripted mode).
        public func injectPeerReset(applicationError: UInt64) async {
            guard canReceive else { return }
            await Self.applyReset(from: side.peer, code: applicationError, pipe: endpoint.inbound, codes: codes)
        }

        /// Behaves as if the peer sent STOP_SENDING(`applicationError`): local sends throw
        /// ``TransportError/connectionReset`` (works in scripted mode).
        public func injectPeerStopSending(applicationError: UInt64) async {
            guard canSend else { return }
            await Self.applyStopSending(from: side.peer, code: applicationError, pipe: endpoint.outbound, codes: codes)
        }

        /// RESET_STREAM from `from` on the direction carried by `pipe`.
        private static func applyReset(
            from: Side, code: UInt64, pipe: InMemoryTransport.Pipe, codes: Codes
        ) async {
            codes.value.withLock { if $0.reset[from.index] == nil { $0.reset[from.index] = code } }
            pipe.state.withLock { $0.reset = true }
            await pipe.drainAsync()
        }

        /// STOP_SENDING from `from` on the direction carried by `pipe` (toward `from`), plus
        /// the RESET_STREAM response.
        private static func applyStopSending(
            from: Side, code: UInt64, pipe: InMemoryTransport.Pipe, codes: Codes
        ) async {
            codes.value.withLock {
                if $0.stopSending[from.index] == nil { $0.stopSending[from.index] = code }
                if $0.reset[from.peer.index] == nil { $0.reset[from.peer.index] = code }
            }
            pipe.state.withLock {
                $0.readerClosed = true
                $0.reset = true
            }
            await pipe.drainAsync()
        }

        /// Connection termination: both directions fail.
        func resetBothDirections() async {
            for pipe in [endpoint.outbound, endpoint.inbound] {
                pipe.state.withLock {
                    $0.reset = true
                    $0.readerClosed = true
                }
                await pipe.drainAsync()
            }
        }

        // MARK: Inspection

        /// The RESET_STREAM code this end sent.
        public var sentResetCode: UInt64? { codes.value.withLock { $0.reset[side.index] } }
        /// The RESET_STREAM code the peer sent (NW `streamApplicationErrorCode` after a reset).
        public var receivedResetCode: UInt64? { codes.value.withLock { $0.reset[side.peer.index] } }
        /// The STOP_SENDING code this end sent.
        public var sentStopSendingCode: UInt64? { codes.value.withLock { $0.stopSending[side.index] } }
        /// The STOP_SENDING code the peer sent.
        public var receivedStopSendingCode: UInt64? { codes.value.withLock { $0.stopSending[side.peer.index] } }

        /// Every byte this end's sends have had accepted, in order.
        public var sentBytes: ByteBuffer { endpoint.sentBytes }
        /// True after ``close(_:)`` (or after this side closed the connection).
        public var isClosed: Bool { endpoint.isClosed }
        /// Bytes held by the pipe this end reads from.
        public var inboundBufferedBytes: Int { endpoint.inboundBufferedBytes }
        /// The most bytes the pipe this end reads from has held at once.
        public var inboundHighWaterMark: Int { endpoint.inboundHighWaterMark }
        /// Peer senders suspended on the pipe this end reads from (backpressure).
        public var suspendedPeerSenders: Int { endpoint.suspendedPeerSenders }

        /// Sends `events` in order with backpressure (bytes, delays, errors, end of stream),
        /// as ``InMemoryTransport/play(_:)``.
        public func play(_ events: [InMemoryTransport.Event]) async throws {
            try await endpoint.play(events)
        }

        /// Makes the next send throw `error` without sending anything.
        public func failNextSend(with error: TransportError) {
            endpoint.failNextSend(with: error)
        }
    }
}

// MARK: - Connection

extension InMemoryMultiplexedTransport {
    /// State shared by both sides of one connection. Critical sections never suspend;
    /// continuations are resumed after the lock is released.
    final class Connection: Sendable {
        enum Mode: Sendable { case paired, scripted }

        enum Termination: Sendable {
            case closed(by: Side, applicationError: UInt64)
            case failed(TransportError)

            func error(for side: Side) -> TransportError {
                switch self {
                case .closed(let by, _): by == side ? .closed : .connectionReset
                case .failed(let error): error
                }
            }
        }

        struct Opener {
            let id: UInt64
            let unidirectional: Bool
            let continuation: CheckedContinuation<Stream, any Error>
        }

        struct Consumer {
            let id: UInt64
            let continuation: CheckedContinuation<Stream?, any Error>
        }

        struct SideState {
            let configuration: Configuration
            /// Streams this side has opened, by kind (0 = bidi, 1 = uni).
            var openedCount: [UInt64] = [0, 0]
            /// Streams this side may open in total, by kind: the peer's MAX_STREAMS credit.
            var limit: [UInt64]
            var openers: [Opener] = []
            /// Peer-opened streams not yet handed to the consumer.
            var pending: [Stream] = []
            var consumer: Consumer?
            /// Scripted mode: iteration ends once `pending` is drained.
            var inboundFinished = false
            var opened: [Stream] = []
        }

        struct State {
            let mode: Mode
            var sides: [SideState]
            var termination: Termination?
            /// Every stream endpoint, for connection termination.
            var all: [Stream] = []
            var nextWaiterID: UInt64 = 0

            mutating func makeID() -> UInt64 {
                nextWaiterID &+= 1
                return nextWaiterID
            }

            func canOpen(_ side: Side, unidirectional: Bool) -> Bool {
                let kind = unidirectional ? 1 : 0
                return sides[side.index].openedCount[kind] < sides[side.index].limit[kind]
            }

            /// Allocates the next stream of a kind for `opener` and announces it to the peer.
            /// Returns the opener's endpoint and, if the peer's consumer was waiting, the
            /// hand-off to perform after the lock.
            mutating func allocate(
                _ opener: Side, unidirectional: Bool
            ) -> (Stream, (CheckedContinuation<Stream?, any Error>, Stream)?) {
                let kind = unidirectional ? 1 : 0
                let index = sides[opener.index].openedCount[kind]
                sides[opener.index].openedCount[kind] += 1
                let streamID = index << 2 | (unidirectional ? 0x2 : 0) | (opener == .server ? 0x1 : 0)
                let codes = Stream.Codes()

                switch mode {
                case .scripted:
                    let endpoint = InMemoryTransport.scripted(
                        [], configuration: sides[opener.index].configuration.streamConfiguration)
                    if unidirectional { endpoint.state.withLock { $0.inputEnded = true } }
                    let stream = Stream(
                        streamID: streamID, side: opener, endpoint: endpoint, codes: codes,
                        canSend: true, canReceive: !unidirectional)
                    sides[opener.index].opened.append(stream)
                    all.append(stream)
                    return (stream, nil)

                case .paired:
                    let (client, server) = InMemoryTransport.makePair(
                        client: sides[0].configuration.streamConfiguration,
                        server: sides[1].configuration.streamConfiguration)
                    let (local, remote) = opener == .client ? (client, server) : (server, client)
                    if unidirectional {
                        local.state.withLock { $0.inputEnded = true }
                        remote.state.withLock { $0.outputShutdown = true }
                    }
                    let localStream = Stream(
                        streamID: streamID, side: opener, endpoint: local, codes: codes,
                        canSend: true, canReceive: !unidirectional)
                    let remoteStream = Stream(
                        streamID: streamID, side: opener.peer, endpoint: remote, codes: codes,
                        canSend: !unidirectional, canReceive: true)
                    sides[opener.index].opened.append(localStream)
                    all.append(localStream)
                    all.append(remoteStream)
                    let peer = opener.peer.index
                    if let consumer = sides[peer].consumer {
                        assert(sides[peer].pending.isEmpty)
                        sides[peer].consumer = nil
                        return (localStream, (consumer.continuation, remoteStream))
                    }
                    sides[peer].pending.append(remoteStream)
                    return (localStream, nil)
                }
            }
        }

        let state: Mutex<State>

        init(mode: Mode, client: Configuration, server: Configuration) {
            let unlimited: [UInt64] = [.max, .max]
            let clientState = SideState(
                configuration: client,
                limit: mode == .scripted
                    ? unlimited : [server.maxStreamsBidirectional, server.maxStreamsUnidirectional])
            let serverState = SideState(
                configuration: server,
                limit: mode == .scripted
                    ? unlimited : [client.maxStreamsBidirectional, client.maxStreamsUnidirectional])
            state = Mutex(State(mode: mode, sides: [clientState, serverState]))
        }

        func configuration(for side: Side) -> Configuration {
            state.withLock { $0.sides[side.index].configuration }
        }

        func prepareScript(_ scripted: [ScriptedStream], side: Side, finishesInbound: Bool) {
            state.withLock { state in
                let configuration = state.sides[side.index].configuration.streamConfiguration
                for item in scripted {
                    let peerInitiated = (item.streamID & 0x1 == 0) == (side == .server)
                    precondition(peerInitiated, "scripted stream \(item.streamID) is not peer-initiated")
                    let unidirectional = item.streamID & 0x2 != 0
                    let endpoint = InMemoryTransport.scripted(item.events, configuration: configuration)
                    if unidirectional { endpoint.state.withLock { $0.outputShutdown = true } }
                    let stream = Stream(
                        streamID: item.streamID, side: side, endpoint: endpoint,
                        codes: Stream.Codes(), canSend: !unidirectional, canReceive: true)
                    state.sides[side.index].pending.append(stream)
                    state.all.append(stream)
                }
                state.sides[side.index].inboundFinished = finishesInbound
            }
        }

        // MARK: Opening

        enum OpenAction {
            case opened(Stream, handOff: (CheckedContinuation<Stream?, any Error>, Stream)?)
            case suspended
            case fail(any Error)
        }

        func open(from side: Side, unidirectional: Bool) async throws -> Stream {
            try Task.checkCancellation()
            let id = state.withLock { $0.makeID() }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Stream, any Error>) in
                    let action: OpenAction = state.withLock { state in
                        if let termination = state.termination { return .fail(termination.error(for: side)) }
                        let queued = state.sides[side.index].openers.contains { $0.unidirectional == unidirectional }
                        if !queued && state.canOpen(side, unidirectional: unidirectional) {
                            let (stream, handOff) = state.allocate(side, unidirectional: unidirectional)
                            return .opened(stream, handOff: handOff)
                        }
                        if Task.isCancelled { return .fail(CancellationError()) }
                        state.sides[side.index].openers.append(
                            Opener(id: id, unidirectional: unidirectional, continuation: continuation))
                        return .suspended
                    }
                    switch action {
                    case .opened(let stream, let handOff):
                        if let (consumer, remote) = handOff { consumer.resume(returning: remote) }
                        continuation.resume(returning: stream)
                    case .suspended:
                        break
                    case .fail(let error):
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                let opener: Opener? = state.withLock { state in
                    guard let index = state.sides[side.index].openers.firstIndex(where: { $0.id == id }) else {
                        return nil
                    }
                    return state.sides[side.index].openers.remove(at: index)
                }
                opener?.continuation.resume(throwing: CancellationError())
            }
        }

        func raiseMaxStreams(grantedBy granter: Side, bidirectional: UInt64?, unidirectional: UInt64?) {
            let opener = granter.peer
            let resumed: [(CheckedContinuation<Stream, any Error>, Stream, (CheckedContinuation<Stream?, any Error>, Stream)?)] =
                state.withLock { state in
                    guard state.mode == .paired, state.termination == nil else { return [] }
                    if let bidirectional { state.sides[opener.index].limit[0] = max(state.sides[opener.index].limit[0], bidirectional) }
                    if let unidirectional { state.sides[opener.index].limit[1] = max(state.sides[opener.index].limit[1], unidirectional) }
                    var resumed: [(CheckedContinuation<Stream, any Error>, Stream, (CheckedContinuation<Stream?, any Error>, Stream)?)] = []
                    var remaining: [Opener] = []
                    for waiter in state.sides[opener.index].openers {
                        let blockedAhead = remaining.contains { $0.unidirectional == waiter.unidirectional }
                        if !blockedAhead && state.canOpen(opener, unidirectional: waiter.unidirectional) {
                            let (stream, handOff) = state.allocate(opener, unidirectional: waiter.unidirectional)
                            resumed.append((waiter.continuation, stream, handOff))
                        } else {
                            remaining.append(waiter)
                        }
                    }
                    state.sides[opener.index].openers = remaining
                    return resumed
                }
            for (continuation, stream, handOff) in resumed {
                if let (consumer, remote) = handOff { consumer.resume(returning: remote) }
                continuation.resume(returning: stream)
            }
        }

        // MARK: Accepting

        enum NextAction {
            case deliver(Stream)
            case end
            case fail(any Error)
            case suspended
        }

        func nextInbound(for side: Side) async throws -> Stream? {
            let id = state.withLock { $0.makeID() }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Stream?, any Error>) in
                    let action: NextAction = state.withLock { state in
                        if !state.sides[side.index].pending.isEmpty {
                            return .deliver(state.sides[side.index].pending.removeFirst())
                        }
                        switch state.termination {
                        case .failed(let error): return .fail(error)
                        case .closed: return .end
                        case nil: break
                        }
                        if state.sides[side.index].inboundFinished || Task.isCancelled { return .end }
                        precondition(state.sides[side.index].consumer == nil, "inboundStreams supports one consumer at a time")
                        state.sides[side.index].consumer = Consumer(id: id, continuation: continuation)
                        return .suspended
                    }
                    switch action {
                    case .deliver(let stream): continuation.resume(returning: stream)
                    case .end: continuation.resume(returning: nil)
                    case .fail(let error): continuation.resume(throwing: error)
                    case .suspended: break
                    }
                }
            } onCancel: {
                let consumer: Consumer? = state.withLock { state in
                    guard let consumer = state.sides[side.index].consumer, consumer.id == id else { return nil }
                    state.sides[side.index].consumer = nil
                    return consumer
                }
                consumer?.continuation.resume(returning: nil)
            }
        }

        // MARK: Termination

        func terminate(_ termination: Termination) async {
            let work: (openers: [(Opener, Side)], consumers: [Consumer], streams: [Stream])? = state.withLock { state in
                guard state.termination == nil else { return nil }
                state.termination = termination
                var openers: [(Opener, Side)] = []
                var consumers: [Consumer] = []
                for side in [Side.client, .server] {
                    openers += state.sides[side.index].openers.map { ($0, side) }
                    state.sides[side.index].openers = []
                    if let consumer = state.sides[side.index].consumer { consumers.append(consumer) }
                    state.sides[side.index].consumer = nil
                    state.sides[side.index].pending = []   // unaccepted streams die with the connection
                }
                return (openers, consumers, state.all)
            }
            guard let work else { return }
            for (opener, side) in work.openers {
                opener.continuation.resume(throwing: termination.error(for: side))
            }
            for consumer in work.consumers {
                if case .failed(let error) = termination {
                    consumer.continuation.resume(throwing: error)
                } else {
                    consumer.continuation.resume(returning: nil)
                }
            }
            let closedBy: Side? = if case .closed(let by, _) = termination { by } else { nil }
            // Close the closing side's endpoints first so its pending operations report
            // `.closed` rather than the reset the peer sees.
            for stream in work.streams where stream.side == closedBy {
                await stream.endpoint.close(.abort)
            }
            for stream in work.streams {
                await stream.resetBothDirections()
            }
        }
    }
}
