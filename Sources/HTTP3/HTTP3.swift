public import HTTPCore
import QPACK
import Synchronization

/// HTTP/3 (RFC 9114) as a ``MultiplexedConnectionProtocol`` for QUIC connections negotiated
/// with ALPN `h3`.
///
/// ```swift
/// for try await connection in quicListener.connections {
///     group.addTask { await HTTP3().run(connection, handler: app, context: context) }
/// }
/// ```
///
/// ## Structure
///
/// One call to ``run(_:handler:context:)`` serves one connection in a discarding task group:
///
/// - one child task opens our control stream (SETTINGS) and QPACK encoder and decoder streams,
///   then waits for the server to drain or the connection to go idle, and runs the graceful
///   shutdown (GOAWAY, drain, CONNECTION_CLOSE);
/// - one child task per peer stream: unidirectional streams are classified and read
///   (control frames, QPACK instructions) or ignored; each bidirectional stream is one request
///   (``H3RequestStream``) whose handler runs as a child of that stream's task, next to a
///   body reader that feeds the request's `HTTPRequestBody` (``H3BodyChannel``), and, when
///   per-stream ``H3Timeouts`` are set, a watchdog;
/// - connection-level decisions go through ``H3Connection`` in a `Mutex`, with no suspension
///   inside the lock. Request streams share no other state (static-table QPACK).
///
/// ## Graceful shutdown (RFC 9114 §5.2)
///
/// When `context.shutdown` triggers (or the connection was idle for ``H3Timeouts/idle``), the
/// server sends GOAWAY with the next unprocessed client bidirectional stream ID (first one with
/// the largest possible ID when ``H3Timeouts/goawayGrace`` is set). Streams at or above it are
/// reset with `H3_REQUEST_REJECTED`; requests below it run to completion. When the last one
/// finished, or ``H3Timeouts/drain`` passed, the connection closes with `H3_NO_ERROR`: after
/// ``H3Timeouts/closeLinger`` (or as soon as the peer closes), so the peer can read the GOAWAY
/// and the last responses before CONNECTION_CLOSE discards what it has not acknowledged.
///
/// ## Errors and limits
///
/// Every failure is signalled as ``H3Failure`` says (its table lists each code). Limits are in
/// ``H3Configuration``: concurrent request streams (with QUIC stream credit raised as requests
/// finish, through `StreamCreditGranting`), field section size (`431` or
/// `H3_MESSAGE_ERROR`), encoded HEADERS size (`H3_EXCESSIVE_LOAD`), request body size
/// (`413`), how much unread body is drained, and ``H3Timeouts``. A response head larger than
/// the peer's `SETTINGS_MAX_FIELD_SECTION_SIZE` is replaced by a bare `500`.
///
/// ## Cancellation (#0104)
///
/// A peer RESET_STREAM or STOP_SENDING on a request stream cancels that request's tasks: the
/// body reader sees it on its next receive, a response send fails with it, and, for transports
/// that are `PeerAbortObserving`, a watcher notices it while the handler is still computing.
/// The handler then sees `CancellationError` (or `TransportError.connectionReset` from a body
/// read). A request whose handler is cancelled or throws `CancellationError`, or that the peer
/// abandoned, is reset with `H3_REQUEST_CANCELLED`; a response body that fails after its head
/// was sent is reset with `H3_INTERNAL_ERROR`.
///
/// ## Abuse limits (#0104)
///
/// ``H3AbuseLimits`` (in ``H3Configuration/abuseLimits``) bounds rapid stream reset, ignored
/// unidirectional streams, QPACK instruction floods, control-frame and unknown-frame floods and
/// oversized unknown frames (each `H3_EXCESSIVE_LOAD`), the response bytes stalled in sends
/// across a connection (with ``H3Timeouts/send`` resetting a slow reader's streams), and the
/// number of idle connections per ``HTTP3`` value (the longest-idle one is shut down
/// gracefully). ``tracker`` counts live connections, request streams, handlers and body
/// channels.
///
/// ## Extended CONNECT (RFC 9220, #0111)
///
/// When the handler chain holds an ``ExtendedConnectProvider`` (the WebSocket component) or
/// ``H3Configuration/enableConnectProtocol`` is set, SETTINGS carries
/// `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1`; otherwise a request with `:protocol` is malformed.
/// An extended CONNECT reaches the handler like any request, with
/// ``HTTPRequest/connectProtocol`` set. A `2xx` response with a `.tunnel` body sends its
/// HEADERS without FIN and hands the closure the request stream as a ``ByteStreamTransport``
/// (``H3TunnelTransport``): DATA frame payloads in, each send one DATA frame out, its end of
/// stream our FIN. The peer's FIN is the tunnel's end of stream; a peer reset fails its
/// receive with `TransportError.connectionReset` and cancels it. Closing the tunnel normally
/// sends FIN; an abortive close resets the stream with `H3_REQUEST_CANCELLED`. Request body
/// limits do not apply to a tunnel; the response send deadline does. The closure's
/// ``TunnelContext`` carries the server's drain signal. A `.tunnel` body for any other
/// request is answered `501`.
///
/// ## Not yet
///
/// Trailers in responses.
public struct HTTP3: MultiplexedConnectionProtocol {
    public var configuration: H3Configuration
    /// Shared by every connection this value runs: the idle-connection limit and the debug
    /// counters.
    public let tracker: H3ConnectionTracker

    public init(configuration: H3Configuration = H3Configuration(), tracker: H3ConnectionTracker = H3ConnectionTracker()) {
        self.configuration = configuration
        self.tracker = tracker
    }

    public static var alpnTokens: [String] { ["h3"] }

    public func run<T: MultiplexedTransport, H: HTTPHandler>(
        _ t: T, handler: H, context: ConnectionContext
    ) async where T.Stream: ResettableStream {
        // Every HTTP/3 connection negotiated `h3`; say so even where the transport could not
        // read it back, so the chain can tell HTTP/3 requests apart (``AltSvc``, #0103).
        var context = context
        if context.info.negotiatedALPN == nil { context.info.negotiatedALPN = "h3" }
        var configuration = configuration
        if !configuration.enableConnectProtocol
            && !MiddlewareChainInspector.extendedConnectProtocols(in: handler).isEmpty {
            // A component serves extended CONNECT (WebSockets, RFC 9220): advertise it.
            configuration.enableConnectProtocol = true
        }
        let driver = H3ConnectionDriver(
            transport: t, handler: handler, context: context, configuration: configuration, tracker: tracker)
        await driver.run()
    }
}

/// Runs one HTTP/3 connection (see ``HTTP3``).
final class H3ConnectionDriver<Transport: MultiplexedTransport, Handler: HTTPHandler>: Sendable
where Transport.Stream: ResettableStream {
    typealias Stream = Transport.Stream

    struct Shared {
        var machine: H3Connection
        /// Since when the connection has had no open request stream; `nil` while one is open.
        var idleSince: ContinuousClock.Instant?
        var abuse: H3AbuseMonitor
    }

    /// What starts a graceful shutdown.
    enum ShutdownTrigger: Sendable {
        case shutdown
        case idle
    }

    let transport: Transport
    let handler: Handler
    let context: ConnectionContext
    let configuration: H3Configuration
    let state: Mutex<Shared>
    /// Our control and QPACK streams. Kept until the connection ends: releasing a QUIC stream
    /// cancels it, and the peer treats a closed critical stream as a connection error.
    let localStreams = Mutex<[Stream]>([])
    /// The transport's stream-credit API, if it has one (checked once per connection).
    let credit: (any StreamCreditGranting)?
    /// Triggers when the final GOAWAY was sent and every request below it finished.
    let drained = ShutdownSignal()
    /// The peer's `SETTINGS_MAX_FIELD_SECTION_SIZE` (unlimited until its SETTINGS arrive).
    let peerMaxFieldSectionSize = Atomic<UInt64>(.max)
    let tracker: H3ConnectionTracker
    /// This connection's ID in ``tracker``.
    let trackerID: UInt64
    /// Triggered when there are too many idle connections and this one was idle longest.
    let evicted = ShutdownSignal()
    /// ``H3AbuseLimits/maxConnectionSendBuffer``.
    let sendBudget: H3SendBudget?

    init(
        transport: Transport, handler: Handler, context: ConnectionContext, configuration: H3Configuration,
        tracker: H3ConnectionTracker = H3ConnectionTracker()
    ) {
        self.transport = transport
        self.handler = handler
        self.context = context
        self.configuration = configuration
        self.tracker = tracker
        state = Mutex(Shared(
            machine: H3Connection(configuration: configuration), idleSince: .now,
            abuse: H3AbuseMonitor(limits: configuration.abuseLimits)))
        credit = transport as? any StreamCreditGranting
        sendBudget = configuration.abuseLimits.maxConnectionSendBuffer.map { H3SendBudget(capacity: $0) }
        trackerID = tracker.connectionStarted()
    }

    func run() async {
        defer { tracker.connectionEnded(trackerID, sendBufferHighWater: sendBudget?.highWater ?? 0) }
        tracker.becameIdle(trackerID, evict: evicted, limit: configuration.abuseLimits.maxIdleConnections)
        let initialCredit = state.withLock { $0.machine.initialStreamCredit }
        credit?.raiseMaxStreams(bidirectional: initialCredit, unidirectional: nil)
        await withDiscardingTaskGroup { group in
            group.addTask { await self.runControl() }
            do {
                for try await stream in transport.inboundStreams {
                    group.addTask { await self.serve(stream) }
                }
            } catch {
                // The connection failed; every stream fails with it.
            }
            // The connection is closed (by either side): stop handlers and readers.
            group.cancelAll()
        }
        let code = state.withLock { $0.machine.closeCode } ?? HTTP3Error.noError.rawValue
        await transport.close(applicationError: code)
        localStreams.withLock { $0.removeAll() }
    }

    /// Applies `event` to the connection state; closes the connection if it says so.
    @discardableResult
    func handle(_ event: H3Connection.Event) async -> H3Connection.Action {
        let action = state.withLock { $0.machine.handle(event) }
        if case .closeConnection(let code) = action {
            await transport.close(applicationError: code)
        }
        return action
    }

    var isClosing: Bool { state.withLock { $0.machine.isClosing } }

    /// Counts `amount` events of `kind` against ``H3AbuseLimits``; returns `false` when that
    /// went over the limit.
    func countAbuse(_ kind: H3AbuseKind, amount: Int = 1) -> Bool {
        let now = ContinuousClock.now
        return state.withLock { $0.abuse.record(kind, amount: amount, now: now) }
    }

    /// ``countAbuse(_:amount:)``, closing the connection with `H3_EXCESSIVE_LOAD` when over the
    /// limit. Returns `false` then.
    @discardableResult
    func recordAbuse(_ kind: H3AbuseKind, amount: Int = 1) async -> Bool {
        guard !countAbuse(kind, amount: amount) else { return true }
        await fail(.excessiveLoad(kind), stream: nil)
        return false
    }

    /// Signals `failure` as ``H3Failure/signal`` says: on `stream` for a stream error, on the
    /// connection for a connection error.
    func fail(_ failure: H3Failure, stream: Stream?) async {
        switch failure.signal {
        case .resetStream(let code):
            await stream?.reset(applicationError: code)
            await stream?.stopSending(applicationError: code)
        case .resetSending(let code):
            await stream?.reset(applicationError: code)
        case .stopSending(let code):
            await stream?.stopSending(applicationError: code)
        case .closeConnection(let code):
            await handle(.connectionError(code: code))
        }
    }

    // MARK: Local streams and shutdown

    /// Opens our streams, then waits for a shutdown or idle trigger and shuts down gracefully.
    func runControl() async {
        guard await openLocalStreams() else { return }
        guard let trigger = await waitForTrigger(), !Task.isCancelled, !isClosing else { return }
        let timeouts = configuration.timeouts
        if trigger == .shutdown, let grace = timeouts.goawayGrace {
            guard await sendGoaway(final: false) else { return }
            do { try await Task.sleep(for: grace) } catch { return }
        }
        guard await sendGoaway(final: true) else { return }
        var ending: H3Failure = trigger == .idle ? .idleTimeout : .gracefulShutdown
        if !(await waitUntilDrained()) {
            guard !Task.isCancelled else { return }
            ending = .drainTimeout
        }
        if let linger = timeouts.closeLinger {
            // Let the peer read the GOAWAY and the last responses; a peer that closes first
            // ends the connection (and cancels this sleep).
            do { try await Task.sleep(for: linger) } catch { return }
        }
        await fail(ending, stream: nil)
    }

    /// Returns `false` when the streams could not be opened (the connection is closing).
    func openLocalStreams() async -> Bool {
        let prefaces = [
            state.withLock { $0.machine.controlStreamPreface() },
            H3Connection.qpackEncoderStreamPreface,
            H3Connection.qpackDecoderStreamPreface,
        ]
        do {
            for preface in prefaces {
                let stream = try await transport.openUnidirectionalStream()
                localStreams.withLock { $0.append(stream) }
                try await stream.send(ByteBuffer(bytes: preface), endOfStream: false)
            }
            return true
        } catch {
            // The connection closed or failed before our streams were open.
            if !isClosing && !Task.isCancelled {
                await fail(.localStreamFailure, stream: nil)
            }
            return false
        }
    }

    /// Waits for the server to drain or the connection to be idle for ``H3Timeouts/idle``;
    /// `nil` when cancelled.
    func waitForTrigger() async -> ShutdownTrigger? {
        let shutdown = context.shutdown
        let idle = configuration.timeouts.idle
        return await withTaskGroup(of: ShutdownTrigger?.self) { group in
            group.addTask {
                await shutdown.wait()
                return shutdown.isTriggered ? .shutdown : nil
            }
            if let idle {
                group.addTask { await self.waitForIdle(idle) ? .idle : nil }
            }
            let evicted = self.evicted
            group.addTask {
                await evicted.wait()
                return evicted.isTriggered ? .idle : nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Returns `true` once the connection had no open request stream for `limit`.
    func waitForIdle(_ limit: Duration) async -> Bool {
        while true {
            let now = ContinuousClock.now
            let sleep: Duration
            if let since = state.withLock({ $0.idleSince }) {
                let deadline = since.advanced(by: limit)
                if deadline <= now { return true }
                sleep = now.duration(to: deadline)
            } else {
                sleep = limit   // a request is open: look again later
            }
            do {
                try await Task.sleep(for: sleep)
            } catch {
                return false
            }
        }
    }

    /// Sends the provisional or final GOAWAY on our control stream. Returns `false` when the
    /// connection is closing or the send failed.
    func sendGoaway(final: Bool) async -> Bool {
        let action = state.withLock { $0.machine.handle(.beginShutdown(final: final)) }
        guard case .sendGoaway(let id) = action else { return !isClosing }
        guard let control = localStreams.withLock({ $0.first }) else { return false }
        var frame: [UInt8] = []
        // A stream ID is below 2^62, so it always fits a varint.
        try! H3FrameEncoder.encodeGoaway(id: id, into: &frame)
        do {
            try await control.send(ByteBuffer(bytes: frame), endOfStream: false)
            return true
        } catch {
            return false
        }
    }

    /// Waits until every request below the final GOAWAY finished (`true`) or
    /// ``H3Timeouts/drain`` passed or the task was cancelled (`false`).
    func waitUntilDrained() async -> Bool {
        if state.withLock({ $0.machine.isDrained }) { return true }
        let drained = self.drained
        guard let limit = configuration.timeouts.drain else {
            await drained.wait()
            return drained.isTriggered
        }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await drained.wait()
                return drained.isTriggered
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first || drained.isTriggered
        }
    }

    // MARK: Peer streams

    func serve(_ stream: Stream) async {
        if stream.isUnidirectional {
            guard stream.isClientInitiated else { return }
            await serveUnidirectional(stream)
        } else {
            await serveRequest(stream)
        }
    }

    func serveUnidirectional(_ stream: Stream) async {
        var buffer = ByteBuffer(capacity: 256)
        var classifier = UniStreamClassifier()
        var type: H3UniStreamType?
        while type == nil {
            do {
                guard try await stream.receive(into: &buffer, maxLength: configuration.receiveSize) > 0 else { return }
            } catch {
                return
            }
            let result = buffer.withUnsafeReadableBytes { classifier.classify($0) }
            switch result {
            case .classified(let classified, let consumed):
                buffer.moveReaderIndex(forwardBy: consumed)
                type = classified
            case .needsMoreData:
                buffer.clear()
            }
        }
        switch await handle(.uniStream(type!)) {
        case .readControlStream:
            await readControlStream(stream, buffer: buffer)
        case .readQPACKEncoderStream:
            await readQPACKStream(stream, buffer: buffer, critical: .qpackEncoder)
        case .readQPACKDecoderStream:
            await readQPACKStream(stream, buffer: buffer, critical: .qpackDecoder)
        case .ignoreStream:
            await fail(.unknownStreamType, stream: stream)
            await recordAbuse(.ignoredUniStreams)
        case .none, .serveRequest, .rejectRequest, .closeConnection, .grantStreamCredit, .sendGoaway, .drained:
            return
        }
    }

    /// Receives more bytes of a critical stream. Returns `false` when it ended or failed,
    /// after reporting that (unless the connection is already closing).
    func receiveCritical(_ stream: Stream, into buffer: inout ByteBuffer, critical: H3Connection.CriticalStream) async -> Bool {
        let received: Int
        do {
            received = try await stream.receive(into: &buffer, maxLength: configuration.receiveSize)
        } catch {
            if !Task.isCancelled { await handle(.criticalStreamClosed(critical)) }
            return false
        }
        if received == 0 {
            await handle(.criticalStreamClosed(critical))
            return false
        }
        return true
    }

    func readControlStream(_ stream: Stream, buffer initial: ByteBuffer) async {
        var buffer = initial
        var parser = H3FrameParser(configuration: .init(
            streamKind: .control, role: .server, maxUnknownFrameLength: configuration.abuseLimits.maxUnknownFrameLength))
        var counted = 0
        while true {
            var frames = 0
            while buffer.readableBytes > 0 {
                let output: H3FrameParser.Output
                do throws(HTTP3Error) {
                    let bytes = buffer
                    output = try bytes.withUnsafeReadableBytes { (input) throws(HTTP3Error) in try parser.parse(input) }
                } catch {
                    await fail(.protocolViolation(error), stream: nil)
                    return
                }
                buffer.moveReaderIndex(forwardBy: output.consumed)
                if output.event != .needsMoreData { frames += 1 }
                let frame: H3Connection.ControlFrame
                switch output.event {
                case .settings(let settings): frame = .settings(settings)
                case .goaway(let id): frame = .goaway(id: id)
                case .maxPushID(let id): frame = .maxPushID(id)
                case .cancelPush(let id): frame = .cancelPush(pushID: id)
                case .needsMoreData, .dataHeader, .data, .headers, .pushPromise: continue
                }
                if case .closeConnection = await handle(.controlFrame(frame)) { return }
                if case .settings(let settings) = frame, let limit = settings.maxFieldSectionSize {
                    peerMaxFieldSectionSize.store(limit, ordering: .relaxed)
                }
            }
            // Every frame counts toward the control-frame flood limit, skipped ones included.
            frames += parser.skippedFrameCount - counted
            counted = parser.skippedFrameCount
            guard await recordAbuse(.controlFrames, amount: frames) else { return }
            buffer.clear()
            guard await receiveCritical(stream, into: &buffer, critical: .control) else { return }
        }
    }

    func readQPACKStream(_ stream: Stream, buffer initial: ByteBuffer, critical: H3Connection.CriticalStream) async {
        var buffer = initial
        var encoderReader = QPACKEncoderStreamReader()
        var decoderReader = QPACKDecoderStreamReader()
        while true {
            var instructions = 0
            do throws(QPACKError) {
                while buffer.readableBytes > 0 {
                    let bytes = buffer
                    let consumed = try bytes.withUnsafeReadableBytes { (input) throws(QPACKError) -> Int in
                        if critical == .qpackEncoder {
                            guard case .instruction(_, let consumed) = try encoderReader.next(input) else { return 0 }
                            return consumed
                        }
                        guard case .instruction(_, let consumed) = try decoderReader.next(input) else { return 0 }
                        return consumed
                    }
                    if consumed == 0 { break }
                    instructions += 1
                    buffer.moveReaderIndex(forwardBy: consumed)
                }
            } catch {
                await fail(.qpackFailure(code: error.code.rawValue), stream: nil)
                return
            }
            guard await recordAbuse(.qpackInstructions, amount: instructions) else { return }
            // A partial instruction (a few bytes at most) stays for the next receive.
            _ = buffer.discardReadBytes()
            guard await receiveCritical(stream, into: &buffer, critical: critical) else { return }
        }
    }

    // MARK: Request streams

    /// How a request stream's processing ended, which decides what is still to be signalled.
    enum RequestEnd: Sendable {
        /// The response is complete (or a rejection was answered).
        case completed
        /// A failure was already signalled (``fail(_:stream:)``).
        case signalled
        /// The peer reset the stream or sent STOP_SENDING before the response was complete.
        case peerAborted
        /// The request's tasks were cancelled, or the handler threw `CancellationError`.
        case cancelled
    }

    /// What a watched request stream's two tasks report.
    enum Watched: Sendable {
        case processed(RequestEnd)
        case fired(H3StreamWatch.Phase?)
    }

    /// Admits the request stream (or rejects it), serves it under its ``H3StreamWatch``, and
    /// reports it closed so stream credit and the drain can follow.
    func serveRequest(_ stream: Stream) async {
        tracker.requestStreamStarted()
        defer { tracker.requestStreamEnded() }
        switch await admit(stream.streamID) {
        case .serveRequest:
            break
        case .rejectRequest(let code):
            // After GOAWAY or beyond the concurrency limit (H3Failure.rejected*).
            await stream.reset(applicationError: code)
            await stream.stopSending(applicationError: code)
            requestStreamClosed(served: false)
            return
        default:
            requestStreamClosed(served: false)
            return
        }

        let end: RequestEnd
        if let watch = H3StreamWatch.make(configuration.timeouts) {
            let (processed, fired) = await withTaskGroup(of: Watched.self) { group in
                group.addTask {
                    let end = await self.process(stream, watch: watch)
                    watch.finish()
                    return .processed(end)
                }
                group.addTask { .fired(await watch.run()) }
                var processed = RequestEnd.cancelled
                var fired: H3StreamWatch.Phase?
                for await outcome in group {
                    switch outcome {
                    case .processed(let end): processed = end
                    case .fired(let phase): if let phase { fired = phase }
                    }
                    // Either the stream finished (stop the watchdog) or a deadline passed
                    // (stop the stream's tasks).
                    group.cancelAll()
                }
                return (processed, fired)
            }
            if let fired {
                await timedOut(fired, stream: stream, watch: watch)
                end = .signalled
            } else {
                end = processed
            }
        } else {
            end = await process(stream, watch: nil)
        }
        await signal(end, on: stream)
        await stream.close(.normal)
        requestStreamClosed(served: true)
    }

    /// Resets a request that the peer abandoned or whose handler was cancelled with
    /// `H3_REQUEST_CANCELLED`; a peer abort also counts toward the rapid-reset limit.
    func signal(_ end: RequestEnd, on stream: Stream) async {
        switch end {
        case .completed, .signalled:
            return
        case .peerAborted:
            // While the connection is being torn down, its streams fail too: not an abuse.
            guard !Task.isCancelled, !isClosing else { return }
            await fail(.requestCancelled, stream: stream)
            await recordAbuse(.abortedRequests)
        case .cancelled:
            // The whole connection is going away: CONNECTION_CLOSE ends the stream anyway.
            guard !Task.isCancelled, !isClosing else { return }
            await fail(.requestCancelled, stream: stream)
        }
    }

    func admit(_ streamID: UInt64) async -> H3Connection.Action {
        let action = state.withLock { shared in
            let action = shared.machine.handle(.requestStream(streamID: streamID))
            if action == .serveRequest {
                if shared.idleSince != nil { tracker.becameBusy(trackerID) }
                shared.idleSince = nil
            }
            return action
        }
        if case .closeConnection(let code) = action {
            await transport.close(applicationError: code)
        }
        return action
    }

    func requestStreamClosed(served: Bool) {
        let action = state.withLock { shared in
            let action = shared.machine.handle(.requestStreamClosed(served: served))
            if shared.machine.activeRequestStreams == 0 && shared.idleSince == nil {
                shared.idleSince = .now
                // Under the lock, so the tracker sees idle and busy in the connection's order.
                tracker.becameIdle(trackerID, evict: evicted, limit: configuration.abuseLimits.maxIdleConnections)
            }
            return action
        }
        switch action {
        case .grantStreamCredit(let total):
            credit?.raiseMaxStreams(bidirectional: total, unidirectional: nil)
        case .drained:
            drained.trigger()
        default:
            break
        }
    }

    /// A per-stream deadline passed; the stream's tasks have ended.
    func timedOut(_ phase: H3StreamWatch.Phase, stream: Stream, watch: H3StreamWatch) async {
        switch phase {
        case .head:
            await fail(.headerTimeout, stream: stream)
        case .body:
            if watch.responseStarted {
                await fail(.bodyTimeout, stream: stream)
            } else {
                _ = await write(HTTPResponse(status: .requestTimeout), isHead: false, on: stream, watch: nil)
                await fail(.unreadBodyAbandoned, stream: stream)
            }
        case .drain:
            await fail(.unreadBodyAbandoned, stream: stream)
        case .send:
            await fail(.sendTimeout, stream: stream)
        }
    }

    /// Reads the request head and serves the request, or fails the stream.
    func process(_ stream: Stream, watch: H3StreamWatch?) async -> RequestEnd {
        let storage = HTTPRequestStorage(bufferCapacity: 512, fieldCapacity: 16)
        var reader = H3RequestReader(configuration: configuration, storage: storage) { [self] skipped in
            countAbuse(.unknownRequestFrames, amount: skipped)
        }
        switch await reader.next(from: stream) {
        case .head(let request):
            watch?.enterBody()
            return await serve(request, rejection: nil, on: stream, reader: reader, watch: watch)
        case .headError(let error):
            switch error {
            case .malformed:
                await fail(.malformedRequest, stream: stream)
            case .unservableFieldSection:
                await fail(.unservableFieldSection, stream: stream)
            case .fieldSectionTooLarge:
                watch?.enterBody()
                return await serve(nil, rejection: .requestHeaderFieldsTooLarge, on: stream, reader: reader, watch: watch)
            case .qpack(let qpack):
                await fail(.qpackFailure(code: qpack.code.rawValue), stream: nil)
            }
            return .signalled
        case .streamError(let error):
            await fail(H3Failure(streamError: error), stream: stream)
            // Opening a stream and ending it without a request costs as much as a reset.
            await recordAbuse(.abortedRequests)
            return .signalled
        case .connectionError(let code):
            await fail(H3Failure(connectionErrorCode: code), stream: nil)
            return .signalled
        case .peerReset:
            return .peerAborted
        case .failed:
            return .cancelled
        case .data, .end:
            // DATA before HEADERS is a connection error, and `end` without HEADERS is a stream
            // error, so neither arrives here.
            return .signalled
        }
    }

    enum StreamOutcome: Sendable {
        case bodyRead(H3RequestReader.Event)
        /// The body grew past ``H3Configuration/maxRequestBodySize``; the reader stopped.
        case bodyTooLarge
        /// The response was written; `bodyDrained` is false when the unread request body hit
        /// ``H3Configuration/maxUnreadBodySize``.
        case responded(bodyDrained: Bool)
        /// The response was not completed.
        case responseEnded(RequestEnd)
        /// The peer reset the stream or sent STOP_SENDING (``PeerAbortObserving``).
        case peerAborted
        /// The abort watcher was stopped.
        case watcherStopped
    }

    /// Runs the handler for `head` (or answers `rejection` without it) next to the body reader
    /// and, when the stream can report it, a peer-abort watcher; handles the first of: peer
    /// abort, malformed body, end of both.
    func serve(_ head: HTTPRequest?, rejection: HTTPStatus?, on stream: Stream, reader: H3RequestReader, watch: H3StreamWatch?) async -> RequestEnd {
        let channel = H3BodyChannel(capacity: configuration.bodyQueueCapacity, streamID: stream.streamID, watch: watch, tracker: tracker)
        let declared = reader.machine.contentLength
        // An extended CONNECT's DATA is a tunnel's byte stream, not a body to bound.
        let isExtendedConnect = head.map { $0.method == .connect && !$0.connectProtocol.isEmpty } ?? false
        let bodyLimit = isExtendedConnect ? Int.max : configuration.maxRequestBodySize
        var rejection = rejection
        if rejection == nil, let declared, declared > UInt64(bodyLimit) {
            rejection = .contentTooLarge
        }
        let length = declared.flatMap { Int(exactly: $0) }
        let request = rejection != nil ? nil : head.map { head -> HTTPRequest in
            var request = head
            request.body = HTTPRequestBody(source: channel, request: channel.streamID, length: length)
            return request
        }
        let status = rejection ?? .internalServerError
        let observer = stream as? any PeerAbortObserving
        let (end, abandonBody) = await withTaskGroup(of: StreamOutcome.self) { group -> (RequestEnd, Bool) in
            group.addTask {
                var reader = reader
                return await self.pumpBody(from: stream, reader: &reader, into: channel, limit: bodyLimit)
            }
            group.addTask {
                await self.respond(to: request, rejection: status, storage: reader.storage, on: stream, body: channel, watch: watch)
            }
            if let observer {
                group.addTask {
                    await observer.waitForPeerAbort()
                    return Task.isCancelled ? .watcherStopped : .peerAborted
                }
            }
            var abandonBody = false
            var responded = false
            var signalled = false
            var aborted = false
            var cancelled = false
            for await outcome in group {
                switch outcome {
                case .bodyRead(let end):
                    switch end {
                    case .end, .head, .headError, .data:
                        continue
                    case .peerReset:
                        aborted = true
                        // A running tunnel sees the reset in its receive and ends itself (a
                        // WebSocket reports 1006); anything else is cancelled.
                        if !channel.isTunnelling { group.cancelAll() }
                    case .failed:
                        cancelled = true
                        group.cancelAll()
                    case .streamError(let error):
                        group.cancelAll()
                        await fail(H3Failure(streamError: error), stream: stream)
                        signalled = true
                    case .connectionError(let code):
                        group.cancelAll()
                        await fail(H3Failure(connectionErrorCode: code), stream: nil)
                        signalled = true
                    }
                case .bodyTooLarge:
                    // The handler's read fails with `tooLarge` and it answers `413`; the rest of
                    // the body is not read.
                    abandonBody = true
                case .responded(let bodyDrained):
                    responded = true
                    if !bodyDrained { abandonBody = true }
                    // The body reader is done (or abandoned); this also stops the watcher.
                    group.cancelAll()
                case .responseEnded(let end):
                    switch end {
                    case .peerAborted: aborted = true
                    case .signalled: signalled = true
                    case .cancelled, .completed: cancelled = true
                    }
                    group.cancelAll()
                case .peerAborted:
                    aborted = true
                    if !channel.isTunnelling { group.cancelAll() }
                case .watcherStopped:
                    continue
                }
            }
            let end: RequestEnd = responded ? .completed
                : signalled ? .signalled
                : aborted ? .peerAborted
                : cancelled ? .cancelled : .completed
            return (end, abandonBody)
        }
        if abandonBody && end == .completed {
            await fail(.unreadBodyAbandoned, stream: stream)
            return .signalled
        }
        return end
    }

    /// Feeds DATA payload to `channel` until FIN or an error, and reports how the body ended.
    /// Suspends (and so stops reading the stream) while the channel is full.
    func pumpBody(from stream: Stream, reader: inout H3RequestReader, into channel: H3BodyChannel, limit: Int) async -> StreamOutcome {
        var received = 0
        while true {
            let event = await reader.next(from: stream)
            switch event {
            case .data(let chunk):
                received &+= chunk.readableBytes
                if received > limit {
                    channel.fail(HTTPRequestBodyError.tooLarge)
                    return .bodyTooLarge
                }
                do {
                    try await channel.queue.send(chunk)
                } catch {
                    // Cancelled: the stream is being torn down.
                    channel.fail(TransportError.closed)
                    return .bodyRead(.failed)
                }
            case .end:
                channel.finish(trailers: reader.trailers)
                return .bodyRead(.end)
            case .streamError:
                channel.fail(HTTPRequestBodyError.malformed)
                return .bodyRead(event)
            case .connectionError(let code):
                channel.fail(code == HTTP3Error.frameError.rawValue ? HTTPRequestBodyError.truncated : HTTPRequestBodyError.malformed)
                return .bodyRead(event)
            case .peerReset:
                channel.fail(TransportError.connectionReset)
                return .bodyRead(event)
            case .failed, .head, .headError:
                channel.fail(TransportError.closed)
                return .bodyRead(.failed)
            }
        }
    }

    /// Calls the handler (or answers `rejection` when `request` is `nil`) and writes its
    /// response; then reads and discards any body the handler left unread, within
    /// ``H3Configuration/maxUnreadBodySize`` and ``H3Timeouts/unreadBody``, so the reader can
    /// reach FIN.
    func respond(
        to request: HTTPRequest?, rejection: HTTPStatus, storage: HTTPRequestStorage, on stream: Stream,
        body: H3BodyChannel, watch: H3StreamWatch?
    ) async -> StreamOutcome {
        var isHead = false
        var isConnect = false
        let response: HTTPResponse
        if let request {
            isHead = request.method == .head
            isConnect = request.method == .connect
            var requestContext = context.requestContext
            if context.recordsRequestStartTime { requestContext.startTime = .now() }
            tracker.handlerStarted()
            do {
                response = try await handler.handle(request, context: requestContext)
                tracker.handlerEnded()
                storage.endRequest()
                body.expire()
            } catch {
                tracker.handlerEnded()
                storage.endRequest()
                body.expire()
                // Cancelled (peer abort, timeout, connection closing) or the handler gave up by
                // itself: `serve` resets the stream with H3_REQUEST_CANCELLED.
                if Task.isCancelled || error is CancellationError { return .responseEnded(.cancelled) }
                if body.isTooLarge {
                    response = HTTPResponse(status: .contentTooLarge)
                } else {
                    // A malformed, truncated or reset body: the body reader's outcome decides.
                    guard !body.failed else { return .responseEnded(.cancelled) }
                    response = HTTPResponse(status: .internalServerError)
                }
            }
        } else {
            response = HTTPResponse(status: rejection)
        }
        guard !Task.isCancelled else { return .responseEnded(.cancelled) }
        if isConnect, case .tunnel(let tunnel) = response.body, (200..<300).contains(response.status.code) {
            return await runTunnel(response, tunnel, on: stream, body: body, watch: watch)
        }
        let written = await write(response, isHead: isHead, on: stream, watch: watch)
        guard written == .completed else { return .responseEnded(written) }
        guard !Task.isCancelled else { return .responded(bodyDrained: true) }
        watch?.enterDrain()
        var discarded = 0
        for await chunk in body.queue {
            discarded += chunk.readableBytes
            if discarded > configuration.maxUnreadBodySize { return .responded(bodyDrained: false) }
        }
        return .responded(bodyDrained: true)
    }

    /// Answers an extended CONNECT with `response`'s HEADERS (no FIN) and runs its tunnel over
    /// the request stream (RFC 9220 §3); see ``HTTP3`` "Extended CONNECT".
    func runTunnel(
        _ response: HTTPResponse, _ tunnel: @Sendable (any ByteStreamTransport, TunnelContext) async -> Void,
        on stream: Stream, body: H3BodyChannel, watch: H3StreamWatch?
    ) async -> StreamOutcome {
        let sink = H3ResponseSink(stream: stream, budget: sendBudget, watch: watch)
        var encoder = H3ResponseHeadEncoder()
        var out = ByteBuffer(capacity: 256)
        encoder.encode(status: response.status, headers: response.headers, contentLength: nil, into: &out)
        if UInt64(encoder.fieldSectionSize) > peerMaxFieldSectionSize.load(ordering: .relaxed) {
            // As in ``write(_:isHead:on:watch:)``: the peer would refuse the head.
            let written = await write(HTTPResponse(status: .internalServerError), isHead: false, on: stream, watch: watch)
            return written == .completed ? .responded(bodyDrained: false) : .responseEnded(written)
        }
        watch?.markResponseStarted()
        do {
            try await sink.send(out, endOfStream: false)
        } catch {
            if Task.isCancelled || error is CancellationError { return .responseEnded(.cancelled) }
            if let error = error as? TransportError, error == .connectionReset { return .responseEnded(.peerAborted) }
            return .responseEnded(.cancelled)
        }
        let transport = H3TunnelTransport(sink: sink, stream: stream, channel: body)
        body.beginTunnel()
        await tunnel(transport, TunnelContext(shutdown: context.shutdown))
        switch await transport.finish() {
        case .finished:
            return .responded(bodyDrained: true)
        case .reset:
            return .responseEnded(.signalled)
        case .failed:
            if Task.isCancelled { return .responseEnded(.cancelled) }
            return body.failure.map { ($0 as? TransportError) == .connectionReset } == true
                ? .responseEnded(.peerAborted) : .responseEnded(.cancelled)
        }
    }

    /// Writes `response` as HEADERS and DATA frames, then FIN, through the connection's send
    /// budget and the stream's send deadline (``H3ResponseSink``).
    func write(_ response: HTTPResponse, isHead: Bool, on stream: Stream, watch: H3StreamWatch?) async -> RequestEnd {
        let sink = H3ResponseSink(stream: stream, budget: sendBudget, watch: watch)
        var status = response.status
        var headers = response.headers
        var body = response.body
        if case .tunnel = body {
            // Extended CONNECT arrives with #0111.
            status = .notImplemented
            headers = HTTPFields()
            body = .empty
        }
        let hasContent = !isHead && !status.forbidsContent
        let declaredLength: Int?
        switch body {
        case .empty, .tunnel: declaredLength = hasContent ? 0 : nil
        case .bytes(let bytes): declaredLength = status.forbidsContent ? nil : bytes.readableBytes
        case .file(let region): declaredLength = status.forbidsContent ? nil : Int(region.length)
        case .stream(let length, _): declaredLength = status.forbidsContent ? nil : length
        }
        var encoder = H3ResponseHeadEncoder()
        var out = ByteBuffer(capacity: 256)
        encoder.encode(status: status, headers: headers, contentLength: declaredLength, into: &out)
        if UInt64(encoder.fieldSectionSize) > peerMaxFieldSectionSize.load(ordering: .relaxed) {
            // The peer would refuse this head (RFC 9114 §4.2.2): send a bare `500` instead.
            out.clear()
            encoder.encode(status: .internalServerError, headers: HTTPFields(), contentLength: isHead ? nil : 0, into: &out)
            body = .empty
        }
        watch?.markResponseStarted()
        var headSent = false
        do {
            switch body {
            case .empty, .tunnel:
                try await sink.send(out, endOfStream: true)

            case .bytes(let bytes):
                if hasContent && bytes.readableBytes > 0 {
                    var frame = ByteBufferSink(buffer: out)
                    try H3FrameEncoder.encodeDataHeader(length: UInt64(bytes.readableBytes), into: &frame)
                    out = frame.buffer
                    out.append(bytes)
                }
                try await sink.send(out, endOfStream: true)

            case .file(let region):
                guard hasContent && region.length > 0 else {
                    try await sink.send(out, endOfStream: true)
                    return .completed
                }
                var frame = ByteBufferSink(buffer: out)
                try H3FrameEncoder.encodeDataHeader(length: UInt64(region.length), into: &frame)
                headSent = true
                try await sink.send(frame.buffer, endOfStream: false)
                // Read in bounded chunks, each through the send budget.
                try await sink.sendFile(region)
                try await sink.send(ByteBuffer(), endOfStream: true)

            case .stream(_, let writer):
                headSent = true
                try await sink.send(out, endOfStream: false)
                if hasContent {
                    try await writer(H3DataWriter(stream: sink))
                }
                try await sink.send(ByteBuffer(), endOfStream: true)
            }
            return .completed
        } catch {
            if Task.isCancelled || error is CancellationError { return .cancelled }
            // The peer reset the stream or sent STOP_SENDING.
            if let error = error as? TransportError, error == .connectionReset { return .peerAborted }
            // A failing body writer or file, or the stream closed under us.
            guard headSent else { return .cancelled }
            await fail(.responseFailed, stream: stream)
            return .signalled
        }
    }
}

/// The send side of a request stream for the response: every send waits for its share of the
/// connection's ``H3SendBudget`` and runs under the stream's ``H3Timeouts/send`` deadline, so a
/// client that does not read holds a bounded number of bytes, for a bounded time (#0104).
struct H3ResponseSink<Stream: ByteStreamTransport>: ByteStreamTransport {
    let stream: Stream
    let budget: H3SendBudget?
    let watch: H3StreamWatch?

    func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws {
        watch?.armSend()
        defer { watch?.disarmSend() }
        let held = try await budget?.acquire(bytes.readableBytes) ?? 0
        defer { budget?.release(held) }
        try await stream.send(bytes, endOfStream: endOfStream)
    }

    func sendFile(_ region: FileRegion) async throws {
        try await sendFileByReading(region, chunkSize: FileRegion.defaultChunkSize)
    }

    func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        try await stream.receive(into: &buffer, maxLength: maxLength)
    }

    func close(_ reason: CloseReason) async {
        await stream.close(reason)
    }

    var info: ConnectionInfo { stream.info }
}

/// The ``HTTPBodyWriter`` for `.stream` responses: each write is one DATA frame, sent with
/// the transport's backpressure.
struct H3DataWriter<Stream: ByteStreamTransport>: HTTPBodyWriter {
    let stream: Stream

    func write(_ bytes: ByteBuffer) async throws {
        guard bytes.readableBytes > 0 else { return }
        var sink = ByteBufferSink(buffer: ByteBuffer(capacity: bytes.readableBytes + 9))
        try H3FrameEncoder.encodeDataHeader(length: UInt64(bytes.readableBytes), into: &sink)
        var frame = sink.buffer
        frame.append(bytes)
        try await stream.send(frame, endOfStream: false)
    }
}
