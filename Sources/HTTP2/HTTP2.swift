public import HTTPCore
import HPACK
import Synchronization
#if canImport(Darwin)
import Darwin
#endif

/// HTTP/2 (RFC 9113) as a ``ConnectionProtocol``: TLS connections that negotiated ALPN `h2`,
/// and cleartext connections that start with the connection preface (prior knowledge,
/// RFC 9113 §3.3; no `Upgrade: h2c`).
///
/// ```swift
/// let server = Server(configuration: config, listeners: [listener],
///                     protocols: [HTTP2(), HTTP1()], handler: app)
/// ```
///
/// Register it before ``HTTP1`` (HTTP1's sniff also matches `PRI * HTTP/2.0`); a TLS listener
/// then offers `h2, http/1.1` (``ProtocolRegistry/alpnTokens``).
///
/// ## Structure (#0044)
///
/// One call to ``run(_:handler:context:)`` serves one connection:
///
/// - The **reader** (the connection's own task) checks the preface, parses frames with
///   ``HTTP2FrameParser``, joins header blocks with ``HeaderBlockAssembler``, HPACK-decodes
///   every block (also on streams it does not serve), and drives the ``HTTP2Connection`` state
///   machine. Reader end-of-input or a connection error cancels the stream tasks.
/// - One **writer** task is the only code that sends on the transport. It drains the
///   outbound queue and sends everything queued in one `send` per drain.
/// - One **task per request stream** runs the handler and writes the response. Stream tasks,
///   the settings timer and the shutdown watcher are children of one discarding task group;
///   the writer outlives them to flush the last frames (a GOAWAY) and close the transport.
/// - Shared state (``HTTP2Connection``, the HPACK encoder, the outbound queue) lives in one
///   `Mutex` with non-suspending critical sections. A response head is HPACK-encoded and
///   enqueued in one critical section, so the dynamic table follows wire order and its
///   HEADERS + CONTINUATION frames are contiguous. Continuations are resumed outside the lock.
///
/// ## SETTINGS (#0043)
///
/// Our SETTINGS (``HTTP2Configuration/localSettings``) are the first frame, followed by a
/// connection WINDOW_UPDATE up to ``HTTP2Configuration/connectionWindowSize``. They take effect
/// only when acknowledged: until then the parser accepts 16,384-byte frames and the HPACK
/// decoder a 4,096-byte table. Without an ACK within ``HTTP2Configuration/settingsTimeout``
/// the connection ends with `GOAWAY(SETTINGS_TIMEOUT)`. The peer's settings are validated
/// (``HTTP2Settings``), applied (HEADER_TABLE_SIZE to the HPACK encoder, INITIAL_WINDOW_SIZE
/// to the send windows, MAX_FRAME_SIZE to outgoing frames) and acknowledged.
///
/// ## Requests (#0047)
///
/// A request head is validated as ``HTTP2RequestFieldSink`` describes (pseudo-headers through
/// the shared `PseudoHeaderValidator`, connection-specific fields, `te`, `content-length`,
/// `host` against `:authority`); a malformed one is `RST_STREAM(PROTOCOL_ERROR)` on its stream
/// and the connection carries on. Cookie crumbs reach the handler joined with `"; "`.
///
/// ## Request bodies (#0048)
///
/// A request whose HEADERS do not end the stream gets a body (``HTTP2BodyChannel``) that the
/// reader fills with DATA payloads (padding removed) and ends at END_STREAM, with the trailer
/// section if one follows. The bound is the stream's receive window (#0053, see
/// ``HTTP2Connection``): credit (stream and connection WINDOW_UPDATE, each batched at half its
/// window) goes back only as the handler consumes bytes, so a handler that does not read stalls
/// only its own stream. The connection window (``HTTP2Configuration/connectionWindowSize``,
/// 1 MiB) is larger than a stream window (``HTTP2Configuration/initialWindowSize``), so several
/// streams can upload at once. A DATA total that differs from `content-length`, invalid
/// trailers, or DATA past the stream window (`FLOW_CONTROL_ERROR`) reset the stream; DATA past
/// the connection window is a connection `FLOW_CONTROL_ERROR`.
/// DATA the server does not deliver (ignored streams, padding, a body whose handler returned)
/// is credited at once, and a stream still sending when its response ends is reset with
/// `NO_ERROR` (§8.1).
///
/// ## Responses (#0049)
///
/// Each request runs the handler in its own child task, so streams are served concurrently.
/// The response head is HPACK-encoded with `:status` first, lowercase names, the
/// connection-specific fields removed and `content-length` added when the length is known;
/// HEAD, 204 and 304 end the stream on HEADERS. The body becomes DATA frames no larger than the
/// peer's MAX_FRAME_SIZE and both send windows, with END_STREAM on the last. A handler error
/// before HEADERS is a `500`; a body that fails after them is `RST_STREAM(INTERNAL_ERROR)`.
/// `HTTPResponse` has no trailers, so none are sent.
///
/// ## PING and PRIORITY (#0050)
///
/// A PING is answered with a PING ACK carrying the same eight octets, in the priority lane
/// ahead of queued DATA; an ACK for a PING the server did not send is ignored. The server's own
/// PINGs (``HTTP2ConnectionDriver/ping(timeout:)``, for round-trip time and the graceful
/// shutdown) are matched to their ACK by opaque data. PRIORITY frames and the PRIORITY flag on
/// HEADERS are parsed, length-checked and otherwise ignored (SETTINGS_NO_RFC7540_PRIORITIES is
/// 1); a stream that depends on itself is a stream `PROTOCOL_ERROR`.
///
/// ## Resets and cancellation (#0051)
///
/// Each stream task runs its handler as the only child of a small group, so the connection can
/// cancel one stream (``HTTP2StreamTask``). A RST_STREAM from the peer, or a reset the server
/// sends (a malformed body, a flow-control violation), ends the request body (buffered DATA
/// is dropped and its connection credit returned) and cancels the handler, which sees
/// `CancellationError`; flow-control waits end with it. A handler that is cancelled or throws
/// `CancellationError` resets its stream with `CANCEL`, and a body that fails after HEADERS
/// with `INTERNAL_ERROR`; nothing is sent on a stream that is already closed. RST_STREAM on an
/// idle stream is a connection `PROTOCOL_ERROR`. ``HTTP2ConnectionDriver/liveStreamTasks``
/// counts the stream tasks running, for leak tests.
///
/// ## GOAWAY and closing (#0052)
///
/// - A connection error is answered with one `GOAWAY(last stream processed, code, debug
///   data)`; the streams stop, and the connection closes lingering.
/// - Graceful shutdown, when the server drains (`context.shutdown`) or the connection was idle
///   for ``HTTP2Configuration/idleTimeout``: `GOAWAY(2³¹−1, NO_ERROR)`, a PING round trip (at
///   most ``HTTP2Configuration/shutdownPingTimeout``), then the final `GOAWAY(last stream
///   processed, NO_ERROR)`. Streams at or below it finish (or are reset with `CANCEL` after
///   ``HTTP2Configuration/drainTimeout``); new streams above it get
///   `RST_STREAM(REFUSED_STREAM)`. The connection closes after the last stream.
/// - A GOAWAY from the peer is answered with the final GOAWAY, and the connection drains the
///   same way.
/// - Lingering close: after the last frame the writer shuts down its sending side and waits
///   (at most ``HTTP2Configuration/lingerTimeout``) for the peer to close, while the reader
///   keeps reading (discarding input after a connection error, up to
///   ``HTTP2Configuration/maxLingerSize``), so the peer reads the GOAWAY rather than a reset.
///
/// ## Outbound flow control (#0054)
///
/// A DATA frame is the smallest of the chunk, the stream's send window, the connection's send
/// window and the peer's MAX_FRAME_SIZE. A writer that cannot send does not buffer: it waits
/// for its turn (``HTTP2SharedState`` "Fair waiting"). A writer whose stream window is closed
/// waits for that stream's WINDOW_UPDATE (or an INITIAL_WINDOW_SIZE change, which can make
/// windows negative, §6.9.2); writers that need queue space or connection window wait in one
/// FIFO queue, and only the first one that can proceed is woken. A writer that sent a frame and
/// wants to send more while others wait goes to the back, so responses take turns frame by
/// frame. A WINDOW_UPDATE of 0 is a `PROTOCOL_ERROR`, and a window above 2³¹−1 a
/// `FLOW_CONTROL_ERROR` (on the stream, or the connection).
///
/// ## Limits (#0055)
///
/// - A HEADERS frame past SETTINGS_MAX_CONCURRENT_STREAMS gets `RST_STREAM(REFUSED_STREAM)`;
///   its block is still decoded.
/// - A request head over SETTINGS_MAX_HEADER_LIST_SIZE is answered `431` without the handler
///   (`RST_STREAM(PROTOCOL_ERROR)` when a field before the limit was malformed). Blocks are
///   decoded up to ``HTTP2Configuration/headerBlockLimit``; past it the connection closes.
/// - A response head over the peer's SETTINGS_MAX_HEADER_LIST_SIZE becomes a bare `500`.
/// - A request body over ``HTTP2Configuration/maxRequestBodySize`` is answered `413`.
/// - A stream error on an idle stream (a PRIORITY frame that depends on itself) closes the
///   connection, because RST_STREAM must not be sent on an idle stream (§6.4).
///
/// ## Denial of service (#0056)
///
/// ``HTTP2AbuseLimits`` (``HTTP2Configuration/abuseLimits``) rate-limits rapid reset, control,
/// empty, WINDOW_UPDATE and window-limited small DATA frames (`GOAWAY(ENHANCE_YOUR_CALM)`),
/// resets responses stalled on a zero window, and shuts a connection down gracefully after
/// ``HTTP2AbuseLimits/maxStreamsPerConnection`` streams. Handler tasks of reset streams count
/// against twice MAX_CONCURRENT_STREAMS. The CONTINUATION flood, HPACK bomb, reply-queue flood
/// and slow preface are bounded by the header block limits, `maxQueuedControlFrames` and
/// `settingsTimeout`.
///
/// ## Not yet
///
/// Extended CONNECT (#0067: `.tunnel` answers `501`).
public struct HTTP2: ConnectionProtocol {
    public var configuration: HTTP2Configuration

    public init(configuration: HTTP2Configuration = HTTP2Configuration()) {
        self.configuration = configuration
    }

    public static var alpnTokens: [String] { ["h2"] }

    /// Matches the 24-octet connection preface (``HTTP2Preface``): `needMoreBytes` for a proper
    /// prefix, `noMatch` at the first octet that differs.
    public static func matchesCleartextPreface(_ bytes: borrowing ByteBuffer) -> SniffResult {
        HTTP2Preface.match(bytes)
    }

    public func run<T: ByteStreamTransport, H: HTTPHandler>(_ t: T, handler: H, context: ConnectionContext) async {
        if !t.info.isSecure && !configuration.cleartext {
            await t.close(.protocolError)
            return
        }
        let driver = HTTP2ConnectionDriver(transport: t, handler: handler, context: context, configuration: configuration)
        await driver.run()
    }
}

/// Runs one HTTP/2 connection (see ``HTTP2``).
final class HTTP2ConnectionDriver<Transport: ByteStreamTransport, Handler: HTTPHandler>: Sendable {
    let transport: Transport
    let handler: Handler
    let context: ConnectionContext
    let configuration: HTTP2Configuration
    let state: Mutex<HTTP2SharedState>
    /// Stream tasks running (``liveStreamTasks``).
    let liveStreams = Atomic<Int>(0)
    /// Triggers when the reader stopped: the peer closed, the transport failed, or a lingering
    /// close finished discarding. The writer's lingering close waits for it.
    let readerDone = ShutdownSignal()
    /// Receives that returned bytes, counted so a lingering close can tell a quiet peer
    /// (``HTTP2Configuration/lingerQuietTimeout``).
    let receives = Atomic<Int>(0)
    /// Triggers when ``HTTP2AbuseLimits/maxStreamsPerConnection`` streams were dispatched: the
    /// connection shuts down gracefully, so the client moves to a new one (#0056).
    let streamLimit = ShutdownSignal()

    init(transport: Transport, handler: Handler, context: ConnectionContext, configuration: HTTP2Configuration) {
        self.transport = transport
        self.handler = handler
        self.context = context
        self.configuration = configuration
        state = Mutex(HTTP2SharedState(configuration: configuration))
    }

    func run() async {
        handle(.start)
        await withDiscardingTaskGroup { connection in
            connection.addTask { await self.runWriter() }
            await withDiscardingTaskGroup { streams in
                if let timeout = configuration.settingsTimeout {
                    streams.addTask { await self.runSettingsTimer(timeout) }
                }
                let shutdown = context.shutdown
                streams.addTask {
                    await shutdown.wait()
                    if shutdown.isTriggered { await self.shutDownGracefully() }
                }
                if let idle = configuration.idleTimeout {
                    streams.addTask {
                        if await self.waitForIdle(idle) { await self.shutDownGracefully() }
                    }
                }
                if configuration.abuseLimits.maxStreamsPerConnection != nil {
                    let limit = streamLimit
                    streams.addTask {
                        await limit.wait()
                        if limit.isTriggered { await self.shutDownGracefully() }
                    }
                }
                if let stall = configuration.abuseLimits.windowStallTimeout {
                    streams.addTask { await self.runWindowStallWatchdog(stall) }
                }
                await runReader(streams: &streams)
                readerDone.trigger()
                // End of input, a connection error, or the writer closed the transport.
                stopStreams(&streams)
            }
            // Nothing will be enqueued any more: the writer flushes and closes the transport.
            closeOutbound(.normal)
        }
    }

    // MARK: Shared state

    /// Feeds `event` to the shared state; resumes whatever it woke.
    @discardableResult
    func handle(_ event: HTTP2Connection.Event) -> HTTP2Connection.Action {
        var wakeups = HTTP2Wakeups()
        let action = state.withLock { $0.handle(event, wakeups: &wakeups) }
        wakeups.resume()
        return action
    }

    /// ``handle(_:)`` after counting the frame as `kind` (#0056), in one critical section.
    /// Over the limit the connection closes and the event is not handled.
    func handle(_ event: HTTP2Connection.Event, counting kind: HTTP2AbuseKind?) -> HTTP2Connection.Action {
        guard let kind else { return handle(event) }
        var wakeups = HTTP2Wakeups()
        let action = state.withLock { shared -> HTTP2Connection.Action in
            if let flood = shared.recordAbuse(kind, wakeups: &wakeups) { return flood }
            return shared.handle(event, wakeups: &wakeups)
        }
        wakeups.resume()
        return action
    }

    /// Counts one frame as `kind` (#0056). Returns false when that closed the connection.
    func countAbuse(_ kind: HTTP2AbuseKind) -> Bool {
        var wakeups = HTTP2Wakeups()
        let flood = state.withLock { $0.recordAbuse(kind, wakeups: &wakeups) }
        wakeups.resume()
        return flood == nil
    }

    func closeOutbound(_ reason: CloseReason) {
        var wakeups = HTTP2Wakeups()
        state.withLock { $0.close(reason, wakeups: &wakeups) }
        wakeups.resume()
    }

    /// Suspends until it is `ticket`'s turn (``HTTP2SharedState/grantNext(_:)``), its stream
    /// window opened or closed, the connection is closing, or the task is cancelled.
    func waitForTurn(_ ticket: UInt64) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let waiting = state.withLock { shared -> Bool in
                    !Task.isCancelled && shared.parkWaiter(ticket, continuation)
                }
                if !waiting { continuation.resume() }
            }
        } onCancel: {
            cancelWaiter(ticket)
        }
    }

    /// Forgets `ticket` and passes its turn on, if it had one.
    func cancelWaiter(_ ticket: UInt64) {
        var wakeups = HTTP2Wakeups()
        state.withLock { $0.cancelWaiter(ticket, wakeups: &wakeups) }
        wakeups.resume()
    }

    /// Repeats `attempt` (a critical section) until it sends or drops, waiting for its turn in
    /// between (#0054). Returns the sent length and END_STREAM, or `nil` when dropped or
    /// cancelled.
    func enqueue(
        _ attempt: (inout HTTP2SharedState, UInt64?, inout HTTP2Wakeups) -> HTTP2SharedState.StreamStep
    ) async -> (length: Int, endStream: Bool)? {
        var ticket: UInt64?
        while true {
            var wakeups = HTTP2Wakeups()
            let step = state.withLock { attempt(&$0, ticket, &wakeups) }
            wakeups.resume()
            switch step {
            case .sent(let length, let endStream):
                return (length, endStream)
            case .dropped:
                return nil
            case .wait(let next):
                ticket = next
                await waitForTurn(next)
                if Task.isCancelled {
                    cancelWaiter(next)
                    return nil
                }
            }
        }
    }

    // MARK: Writer

    /// The only sender: drains the outbound queue, one `send` per batch, until the queue is
    /// closed and empty; then closes the transport.
    func runWriter() async {
        while true {
            switch await nextWriterStep() {
            case .send(let batch):
                do {
                    try await transport.send(batch, endOfStream: false)
                } catch {
                    var wakeups = HTTP2Wakeups()
                    state.withLock { $0.writerFailed(wakeups: &wakeups) }
                    wakeups.resume()
                    await transport.close(.abort)
                    return
                }
            case .close(let reason):
                if !reason.isAbortive { await linger() }
                await transport.close(reason)
                return
            case .wait:
                continue
            }
        }
    }

    func nextWriterStep() async -> HTTP2SharedState.WriterStep {
        // The connection ends the writer by closing the queue, so the final GOAWAY is flushed;
        // only a cancelled connection (the server's drain deadline) stops it early.
        if Task.isCancelled { return .close(.abort) }
        var wakeups = HTTP2Wakeups()
        let step = state.withLock { $0.nextWriterStep(wakeups: &wakeups) }
        wakeups.resume()
        guard case .wait = step else { return step }
        // Nothing queued: wait for a frame, the close, or cancellation.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let waiting = state.withLock { shared -> Bool in
                    !Task.isCancelled && shared.registerWriter(continuation)
                }
                // Something arrived between the two critical sections: look again.
                if !waiting { continuation.resume() }
            }
        } onCancel: {
            let writer = state.withLock { shared in
                defer { shared.writer = nil }
                return shared.writer
            }
            writer?.resume()
        }
        return .wait
    }

    /// Lingering close (the writer's half): everything is flushed, so shut down the sending
    /// side (the peer reads end of stream after the GOAWAY) and wait for the reader to see the
    /// peer close, for at most ``HTTP2Configuration/lingerTimeout``. Closing at once could make
    /// TCP reset the connection over unread input and destroy the GOAWAY in flight.
    ///
    /// A peer that sends nothing for ``HTTP2Configuration/lingerQuietTimeout`` has no unread
    /// input to provoke a reset, so the connection closes then. That matters where the
    /// half-close does not reach the peer (Network.framework TLS sends no close_notify for it),
    /// which would otherwise wait for the full timeout; h2spec's 5.4.1/1 waits 2 s (#0061).
    func linger() async {
        guard let limit = configuration.lingerTimeout, !readerDone.isTriggered else { return }
        do {
            try await transport.send(ByteBuffer(), endOfStream: true)
        } catch {
            return
        }
        let readerDone = self.readerDone
        let quiet = configuration.lingerQuietTimeout
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await readerDone.wait() }
            group.addTask { try? await Task.sleep(for: limit) }
            if let quiet {
                group.addTask { await self.waitForQuietInput(quiet) }
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Returns once a whole `quiet` period passed without a receive returning bytes (or on
    /// cancellation).
    func waitForQuietInput(_ quiet: Duration) async {
        while !Task.isCancelled {
            let before = receives.load(ordering: .relaxed)
            do {
                try await Task.sleep(for: quiet)
            } catch {
                return
            }
            if receives.load(ordering: .relaxed) == before { return }
        }
    }

    // MARK: Shutdown

    /// Graceful shutdown (RFC 9113 §6.8), for a draining server or an idle connection:
    /// GOAWAY with the largest stream identifier, a PING round trip (so streams the client
    /// opened before it saw that GOAWAY arrive first), then the final GOAWAY with the last
    /// stream processed. Streams at or below it finish; later ones are refused. After
    /// ``HTTP2Configuration/drainTimeout`` the streams still running are cancelled. The
    /// connection closes when the last stream ends.
    func shutDownGracefully() async {
        guard case .gracefulGoaway = handle(.shutdown) else { return }
        _ = await ping(timeout: configuration.shutdownPingTimeout)
        guard !Task.isCancelled else { return }
        handle(.finishShutdown)
        guard let limit = configuration.drainTimeout else { return }
        do {
            try await Task.sleep(for: limit)
        } catch {
            return
        }
        // Each cancelled stream resets itself with CANCEL; the last one to end closes the
        // connection.
        for task in state.withLock({ $0.runningTasks }) { task.cancel() }
    }

    /// Returns `true` once no stream has run for `limit`; `false` when cancelled.
    func waitForIdle(_ limit: Duration) async -> Bool {
        while true {
            let now = ContinuousClock.now
            let sleep: Duration
            if let since = state.withLock({ $0.idleSince }) {
                let deadline = since.advanced(by: limit)
                if deadline <= now { return true }
                sleep = now.duration(to: deadline)
            } else {
                sleep = limit  // A stream is running: look again later.
            }
            do {
                try await Task.sleep(for: sleep)
            } catch {
                return false
            }
        }
    }

    // MARK: PING

    /// Sends a PING and waits up to `timeout` for its ACK (RFC 9113 §6.7). Returns the round
    /// trip, or `nil` when no ACK came in time, the connection closed, or the task was
    /// cancelled.
    func ping(timeout: Duration) async -> Duration? {
        let data = state.withLock { shared -> UInt64 in
            shared.lastPingData &+= 1
            return shared.lastPingData
        }
        let start = ContinuousClock.now
        let acknowledged = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.awaitPingAck(data) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard acknowledged else {
            handle(.pingAbandoned(opaqueData: data))
            return nil
        }
        return ContinuousClock.now - start
    }

    /// Sends the PING with `data` and suspends until its ACK (`true`), or until the connection
    /// closes or the task is cancelled (`false`).
    func awaitPingAck(_ data: UInt64) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                var wakeups = HTTP2Wakeups()
                let sent = state.withLock { shared -> Bool in
                    guard shared.isOpen, !Task.isCancelled,
                          case .sendPing = shared.handle(.sendPing(opaqueData: data), wakeups: &wakeups)
                    else { return false }
                    shared.pingWaiters[data] = continuation
                    return true
                }
                wakeups.resume()
                if !sent { continuation.resume(returning: false) }
            }
        } onCancel: {
            state.withLock { $0.pingWaiters.removeValue(forKey: data) }?.resume(returning: false)
        }
    }

    // MARK: Timers

    /// Zero-window stall (#0056): every quarter of `limit`, resets streams (or closes the
    /// connection) whose response waited longer than `limit` for send window.
    func runWindowStallWatchdog(_ limit: Duration) async {
        while true {
            do {
                try await Task.sleep(for: limit / 4)
            } catch {
                return
            }
            var wakeups = HTTP2Wakeups()
            let cutoff = ContinuousClock.now - limit
            let open = state.withLock { shared -> Bool in
                shared.expireStalledWriters(before: cutoff, wakeups: &wakeups)
                return shared.isOpen
            }
            wakeups.resume()
            if !open { return }
        }
    }

    func runSettingsTimer(_ timeout: Duration) async {
        do {
            try await Task.sleep(for: timeout)
        } catch {
            return
        }
        handle(.settingsTimeout)
    }

    // MARK: Reader

    /// What the reader does after handling one parser event.
    enum ReadStep {
        case proceed
        /// Serve a request on a new stream task; `body` feeds its request body, and `task`
        /// cancels it. With a `rejection` status the handler is not called (#0055: `431`,
        /// `413`) and there is no request.
        case serve(HTTP2StreamID, HTTPRequest?, rejection: HTTPStatus?, HTTPRequestStorage, body: HTTP2BodyChannel?,
                   task: HTTP2StreamTask)
        /// A connection error was answered (or the peer is gone): stop reading.
        case stop
    }

    /// The DATA frame whose payload the reader is passing on.
    struct DataTarget {
        var streamID: HTTP2StreamID
        /// The payload belongs to the stream's request body (``HTTP2Connection/Action/acceptData(connectionIncrement:)``).
        var accepted: Bool
        /// The body, while its handler runs; accepted bytes without one are credited at once.
        var body: HTTP2BodyChannel?
        var remaining: Int
        var endStream: Bool
    }

    /// Reads the preface and then frames until end of input, a transport error, or a
    /// connection error.
    func runReader(streams: inout DiscardingTaskGroup) async {
        var buffer = ByteBuffer(capacity: configuration.receiveSize)
        guard await readPreface(into: &buffer) else {
            if state.withLock({ $0.machine.isFailed }) { await discardInput(streams: &streams, buffer: &buffer) }
            return
        }

        var parser = HTTP2FrameParser(configuration: .init(role: .server))
        var assembler = HeaderBlockAssembler(configuration: .init(
            maxBlockSize: configuration.headerBlockLimit, maxContinuationFrames: configuration.maxContinuationFrames))
        // Until our SETTINGS are acknowledged the peer may use the default 4,096-byte table.
        // Lists up to the hard limit are decoded so an oversized head can be answered `431`;
        // the advertised limit is enforced by the field sinks.
        var decoder = HPACKDecoder(
            maxTableSize: Swift.max(configuration.headerTableSize, Int(HTTP2Connection.defaultHeaderTableSize)),
            maxHeaderListSize: configuration.headerBlockLimit)
        var data: DataTarget?

        while true {
            while buffer.readableBytes > 0 {
                var step = ReadStep.proceed
                let consumed = buffer.withUnsafeReadableBytes { input -> Int in
                    let output: HTTP2FrameParser.Output
                    do throws(HTTP2Error) {
                        output = try parser.parse(input)
                    } catch {
                        handle(.connectionError(error))
                        step = .stop
                        return input.count
                    }
                    step = process(output.event, input: input, parser: &parser, assembler: &assembler,
                                   decoder: &decoder, data: &data)
                    return output.consumed
                }
                buffer.moveReaderIndex(forwardBy: consumed)
                switch step {
                case .proceed:
                    break
                case .stop:
                    await discardInput(streams: &streams, buffer: &buffer)
                    return
                case .serve(let id, let request, let rejection, let storage, let body, let task):
                    streams.addTask {
                        await self.runStream(id, request: request, rejection: rejection, storage: storage, body: body, task: task)
                    }
                }
            }
            buffer.clear()
            do {
                guard try await transport.receive(into: &buffer, maxLength: configuration.receiveSize) > 0 else { return }
                receives.add(1, ordering: .relaxed)
            } catch {
                return
            }
        }
    }

    /// Ends every request body and cancels the handlers and timers.
    func stopStreams(_ streams: inout DiscardingTaskGroup) {
        let bodies = state.withLock { shared in
            defer { shared.bodies.removeAll() }
            return Array(shared.bodies.values)
        }
        for body in bodies { body.fail(TransportError.closed) }
        streams.cancelAll()
    }

    /// Lingering close (the reader's half), after a connection error was answered with
    /// GOAWAY: the streams stop, and input is read and discarded until the peer closes, the
    /// writer closes the transport (``HTTP2Configuration/lingerTimeout``), or
    /// ``HTTP2Configuration/maxLingerSize`` bytes were discarded.
    func discardInput(streams: inout DiscardingTaskGroup, buffer: inout ByteBuffer) async {
        stopStreams(&streams)
        guard configuration.lingerTimeout != nil else { return }
        var discarded = 0
        while discarded <= configuration.maxLingerSize {
            buffer.clear()
            guard let count = try? await transport.receive(into: &buffer, maxLength: configuration.receiveSize),
                  count > 0 else { break }
            receives.add(1, ordering: .relaxed)
            discarded += count
        }
        buffer.clear()
    }

    /// Reads and checks the 24-octet client preface. On a mismatch the connection ends with
    /// `GOAWAY(PROTOCOL_ERROR)` (RFC 9113 §3.4). Bytes after it stay in `buffer`.
    func readPreface(into buffer: inout ByteBuffer) async -> Bool {
        while true {
            switch HTTP2Preface.match(buffer) {
            case .match:
                buffer.moveReaderIndex(forwardBy: HTTP2Preface.count)
                return true
            case .noMatch:
                handle(.connectionError(.connection(.protocolError, reason: "invalid connection preface")))
                return false
            case .needMoreBytes:
                do {
                    let wanted = Swift.max(HTTP2Preface.count - buffer.readableBytes, 1)
                    guard try await transport.receive(into: &buffer, maxLength: Swift.max(wanted, configuration.receiveSize)) > 0
                    else { return false }
                } catch {
                    return false
                }
            }
        }
    }

    /// Handles one parser event: header-block sequencing, HPACK, request bodies, and the state
    /// machine.
    func process(
        _ event: HTTP2FrameParser.Event, input: UnsafeRawBufferPointer, parser: inout HTTP2FrameParser,
        assembler: inout HeaderBlockAssembler, decoder: inout HPACKDecoder, data: inout DataTarget?
    ) -> ReadStep {
        // Every frame passes the assembler first: nothing may interrupt a header block.
        let gate: HeaderBlockAssembler.Action
        let machineEvent: HTTP2Connection.Event
        // Frames that cost work without carrying a request count toward a flood limit (#0056).
        var abuse: HTTP2AbuseKind?
        switch event {
        case .needsMoreData:
            return .proceed
        case .data(let range):
            guard var target = data else { return .proceed }
            let payload = UnsafeRawBufferPointer(rebasing: input[range])
            target.remaining -= payload.count
            data = target.remaining > 0 ? target : nil
            if target.accepted { deliver(payload, to: target) }
            if target.remaining == 0 { endOfData(target) }
            return .proceed
        case .dataHeader(let frame):
            if case .connectionError(let code) = assembler.handle(.otherFrame(.data, streamID: frame.streamID)) {
                handle(.connectionError(.connection(code, reason: "frame inside a header block")))
                return .stop
            }
            // A DATA frame with no payload (padding at most) that does not end the stream does
            // nothing but cost a frame.
            if frame.dataLength == 0 && !frame.endStream && !countAbuse(.emptyFrames) { return .stop }
            var target = DataTarget(
                streamID: frame.streamID, accepted: false, body: nil, remaining: frame.dataLength, endStream: frame.endStream)
            switch receiveData(frame, body: &target.body) {
            case .acceptData: target.accepted = true
            case .goaway: return .stop
            default: break
            }
            if target.remaining == 0 {
                endOfData(target)
            } else {
                data = target
            }
            return .proceed
        case .headers(let id, let endStream, let endHeaders, let priority, let location):
            return parser.withPayload(location, in: input) { fragment in
                if fragment.isEmpty && !endHeaders && !countAbuse(.emptyFrames) { return .stop }
                let action = assembler.handle(.headers(
                    streamID: id, endStream: endStream, endHeaders: endHeaders, priority: priority, fragment: fragment))
                return headerBlock(action, fragment: fragment, assembler: assembler, decoder: &decoder)
            }
        case .continuation(let id, let endHeaders, let location):
            return parser.withPayload(location, in: input) { fragment in
                if fragment.isEmpty && !endHeaders && !countAbuse(.emptyFrames) { return .stop }
                let action = assembler.handle(.continuation(streamID: id, endHeaders: endHeaders, fragment: fragment))
                return headerBlock(action, fragment: fragment, assembler: assembler, decoder: &decoder)
            }
        case .pushPromise(let id, _, _, _):
            // The server-role parser rejects PUSH_PROMISE; keep the switch total.
            gate = assembler.handle(.otherFrame(.pushPromise, streamID: id))
            machineEvent = .connectionError(.connection(.protocolError, reason: "client sent PUSH_PROMISE"))
        case .priority(let id, _):
            gate = assembler.handle(.otherFrame(.priority, streamID: id))
            machineEvent = .priority(streamID: id)
            abuse = .controlFrames
        case .rstStream(let id, let code):
            gate = assembler.handle(.otherFrame(.rstStream, streamID: id))
            machineEvent = .rstStream(streamID: id, code)
        case .settings(let settings):
            gate = assembler.handle(.otherFrame(.settings, streamID: .connection))
            machineEvent = .settings(settings)
            abuse = .controlFrames
        case .settingsAck:
            gate = assembler.handle(.otherFrame(.settings, streamID: .connection))
            machineEvent = .settingsAck
        case .ping(let ack, let data):
            gate = assembler.handle(.otherFrame(.ping, streamID: .connection))
            machineEvent = .ping(ack: ack, opaqueData: data)
            if !ack { abuse = .controlFrames }
        case .goaway(let last, let code, _):
            gate = assembler.handle(.otherFrame(.goaway, streamID: .connection))
            machineEvent = .goaway(lastStreamID: last, code)
        case .windowUpdate(let id, let increment):
            gate = assembler.handle(.otherFrame(.windowUpdate, streamID: id))
            machineEvent = .windowUpdate(streamID: id, increment: increment)
            abuse = .windowUpdates
        case .unknown(let header):
            gate = assembler.handle(.otherFrame(header.type, streamID: header.streamID))
            machineEvent = .unknownFrame
            abuse = .controlFrames
        case .streamError(let error):
            gate = assembler.handle(.otherFrame(.priority, streamID: error.streamID ?? .connection))
            machineEvent = .streamError(error)
        }
        if case .connectionError(let code) = gate {
            handle(.connectionError(.connection(code, reason: "frame inside a header block")))
            return .stop
        }
        switch handle(machineEvent, counting: abuse) {
        case .goaway:
            return .stop
        case .applyLocalSettings(let settings):
            // Our SETTINGS are acknowledged: the larger frame size and the table size limit
            // apply from the next frame and block.
            if let size = settings.maxFrameSize { parser.maxFrameSize = Int(size) }
            if let size = settings.headerTableSize { decoder.setMaxTableSizeLimit(Int(size)) }
            return .proceed
        default:
            return .proceed
        }
    }

    // MARK: Request bodies

    /// Feeds the start of a DATA frame to the state machine; when its payload is accepted,
    /// also returns the stream's body (in the same critical section).
    func receiveData(_ frame: HTTP2FrameParser.DataFrame, body: inout HTTP2BodyChannel?) -> HTTP2Connection.Action {
        var wakeups = HTTP2Wakeups()
        let event = HTTP2Connection.Event.data(
            streamID: frame.streamID, dataLength: frame.dataLength, flowControlledLength: frame.flowControlledLength,
            endStream: frame.endStream)
        let (action, channel) = state.withLock { shared -> (HTTP2Connection.Action, HTTP2BodyChannel?) in
            let action = shared.handle(event, wakeups: &wakeups)
            guard case .acceptData = action else { return (action, nil) }
            return (action, shared.bodies[frame.streamID.rawValue])
        }
        wakeups.resume()
        body = channel
        return action
    }

    /// Passes accepted DATA payload to the stream's body, or credits it when nobody reads it.
    func deliver(_ payload: UnsafeRawBufferPointer, to target: DataTarget) {
        guard let body = target.body else {
            bodyConsumed(streamID: target.streamID, length: payload.count)
            return
        }
        switch body.receive(payload) {
        case .accepted:
            break
        case .malformed:
            // More DATA than `content-length` (RFC 9113 §8.1.1).
            handle(.sendReset(streamID: target.streamID, .protocolError))
        }
    }

    /// The end of a DATA frame's payload: END_STREAM completes the body.
    func endOfData(_ target: DataTarget) {
        guard target.accepted, target.endStream, let body = target.body else { return }
        finish(body, trailers: nil)
    }

    /// Completes `body` (END_STREAM), checking the DATA total against `content-length`.
    func finish(_ body: HTTP2BodyChannel, trailers: HTTPFields?) {
        state.withLock { _ = $0.bodies.removeValue(forKey: body.streamID.rawValue) }
        if body.finish(trailers: trailers) == .malformed {
            handle(.sendReset(streamID: body.streamID, .protocolError))
        }
    }

    // MARK: Header blocks

    /// Decodes a complete header block (always, to keep HPACK in step) and decides whether its
    /// stream is served.
    func headerBlock(
        _ action: HeaderBlockAssembler.Action, fragment: UnsafeRawBufferPointer, assembler: HeaderBlockAssembler,
        decoder: inout HPACKDecoder
    ) -> ReadStep {
        let block: HeaderBlockAssembler.HeaderBlock
        switch action {
        case .proceed, .needsContinuation:
            return .proceed
        case .connectionError(let code):
            handle(.connectionError(.connection(code, reason: "invalid header block sequence")))
            return .stop
        case .decode(let complete):
            block = complete
        }
        let decision = handle(.headers(streamID: block.streamID, endStream: block.endStream, trailers: block.kind == .trailers))
        do throws(HTTP2Error) {
            switch decision {
            case .dispatch(let id, _):
                return try dispatch(id, block: block, fragment: fragment, assembler: assembler, decoder: &decoder)
            case .acceptTrailers(let id):
                var sink = HTTP2TrailerFieldSink(maxListSize: configuration.maxHeaderListSize)
                try assembler.decode(block, fragment: fragment, with: &decoder, into: &sink)
                guard let body = state.withLock({ $0.bodies[id.rawValue] }) else { return .proceed }
                if sink.failure != nil {
                    state.withLock { _ = $0.bodies.removeValue(forKey: id.rawValue) }
                    body.fail(HTTPRequestBodyError.malformed)
                    handle(.sendReset(streamID: id, .protocolError))
                } else {
                    finish(body, trailers: sink.fields)
                }
                return .proceed
            case .goaway:
                return .stop
            default:
                var sink = HTTP2DiscardingFieldSink()
                try assembler.decode(block, fragment: fragment, with: &decoder, into: &sink)
                return .proceed
            }
        } catch {
            handle(.connectionError(error))
            return .stop
        }
    }

    /// Decodes a request head on a dispatched stream and serves it, or resets a malformed one.
    func dispatch(
        _ id: HTTP2StreamID, block: HeaderBlockAssembler.HeaderBlock, fragment: UnsafeRawBufferPointer,
        assembler: HeaderBlockAssembler, decoder: inout HPACKDecoder
    ) throws(HTTP2Error) -> ReadStep {
        let storage = HTTPRequestStorage(bufferCapacity: Swift.max(block.size * 2, 256), fieldCapacity: 16)
        var sink = HTTP2RequestFieldSink(storage: storage, maxListSize: configuration.maxHeaderListSize)
        try assembler.decode(block, fragment: fragment, with: &decoder, into: &sink)
        // A stream that depends on itself (the deprecated PRIORITY flag, RFC 9113 §5.3.1) is a
        // stream PROTOCOL_ERROR; otherwise the priority fields are ignored.
        let selfDependent = block.priority?.dependency == id
        let task = HTTP2StreamTask()
        let head: HTTP2RequestHead
        switch sink.head(endStream: block.endStream) {
        case .success(let valid) where !selfDependent:
            head = valid
        case .failure(.fieldSectionTooLarge) where !selfDependent:
            // Over our SETTINGS_MAX_HEADER_LIST_SIZE with no malformed field before the limit:
            // `431` without the handler (#0055).
            return reject(id, .requestHeaderFieldsTooLarge, storage: storage, task: task)
        default:
            // Malformed (RFC 9113 §8.1.1): a stream error. The stream was counted as served
            // when it was dispatched.
            handle(.sendReset(streamID: id, .protocolError))
            streamEnded(id)
            return .proceed
        }
        if let declared = head.contentLength, declared > configuration.maxRequestBodySize {
            return reject(id, .contentTooLarge, storage: storage, task: task)
        }
        var request = head.request
        var body: HTTP2BodyChannel?
        if !block.endStream {
            let channel = HTTP2BodyChannel(
                streamID: id, declaredLength: head.contentLength, maxSize: configuration.maxRequestBodySize, credit: self)
            request.body = HTTPRequestBody(source: channel, request: channel.requestID, length: head.contentLength)
            body = channel
        }
        // Registered before any later frame on the stream is read, so a reset finds them.
        let limitReached = state.withLock { shared -> Bool in
            shared.tasks[id.rawValue] = task
            if let body { shared.bodies[id.rawValue] = body }
            return shared.streamLimitReached
        }
        if limitReached { streamLimit.trigger() }
        return .serve(id, request, rejection: nil, storage, body: body, task: task)
    }

    /// Answers `status` on a dispatched stream without calling the handler. DATA the peer
    /// still sends has no body and is credited at once; the stream is reset with `NO_ERROR`
    /// once the response ends (§8.1).
    func reject(_ id: HTTP2StreamID, _ status: HTTPStatus, storage: HTTPRequestStorage, task: HTTP2StreamTask) -> ReadStep {
        let limitReached = state.withLock { shared -> Bool in
            shared.tasks[id.rawValue] = task
            return shared.streamLimitReached
        }
        if limitReached { streamLimit.trigger() }
        return .serve(id, nil, rejection: status, storage, body: nil, task: task)
    }

    // MARK: Streams

    /// The number of stream tasks running (a debug counter for leak tests: it must return to
    /// zero once every stream ended, however it ended).
    var liveStreamTasks: Int { liveStreams.load(ordering: .relaxed) }

    /// One stream's task: runs ``serve(_:request:rejection:storage:body:)`` as the only child of
    /// a group that ``HTTP2StreamTask/cancel()`` cancels when the stream is reset (#0051).
    func runStream(
        _ id: HTTP2StreamID, request: HTTPRequest?, rejection: HTTPStatus?, storage: HTTPRequestStorage,
        body: HTTP2BodyChannel?, task: HTTP2StreamTask
    ) async {
        liveStreams.add(1, ordering: .relaxed)
        await withDiscardingTaskGroup { group in
            group.addTask {
                await self.serve(id, request: request, rejection: rejection, storage: storage, body: body)
                task.finish()
            }
            await task.wait()
            if task.isCancelled { group.cancelAll() }
        }
        streamEnded(id)
        liveStreams.subtract(1, ordering: .relaxed)
    }

    /// Runs the handler for one request and writes its response.
    ///
    /// Cancellation (a reset of the stream, or of the connection) reaches the handler as
    /// `CancellationError`. A handler that ends because of it, or throws `CancellationError`, and
    /// a response cut short by it, reset the stream with `CANCEL`; the state machine drops the
    /// reset when the stream is already closed (the peer reset it, or the server did).
    ///
    /// With a `rejection` (#0055) the handler is not called and the response is that status.
    /// A body that grew past ``HTTP2Configuration/maxRequestBodySize`` makes a handler that
    /// throws `HTTPRequestBodyError.tooLarge` answer `413` instead of `500`.
    func serve(
        _ id: HTTP2StreamID, request: HTTPRequest?, rejection: HTTPStatus?, storage: HTTPRequestStorage,
        body: HTTP2BodyChannel?
    ) async {
        var response: HTTPResponse?
        var cancelled = false
        var isHead = false
        if let request {
            isHead = request.method == .head
            var requestContext = context.requestContext
            if context.recordsRequestStartTime { requestContext.startTime = .now() }
            do {
                response = try await handler.handle(request, context: requestContext)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    cancelled = true
                } else if (error as? HTTPRequestBodyError) == .tooLarge || body?.isTooLarge == true {
                    response = HTTPResponse(status: .contentTooLarge)
                } else {
                    response = HTTPResponse(status: .internalServerError)
                }
            }
        } else {
            response = HTTPResponse(status: rejection ?? .internalServerError)
        }
        storage.endRequest()
        // Body bytes the handler did not read are discarded and credited.
        body?.expire()
        if let response, !Task.isCancelled {
            await write(response, isHead: isHead, on: id)
        }
        // Dropping the response here closes a `.file` body's descriptor.
        response = nil
        if cancelled || Task.isCancelled { handle(.sendReset(streamID: id, .cancel)) }
    }

    /// A dispatched stream is done: reset it if the peer is still sending, and finish a
    /// graceful drain after the last one.
    func streamEnded(_ id: HTTP2StreamID) {
        var wakeups = HTTP2Wakeups()
        state.withLock { $0.streamEnded(id, wakeups: &wakeups) }
        wakeups.resume()
    }

    /// Writes `response` as HEADERS (+ CONTINUATION) and DATA frames.
    func write(_ response: HTTPResponse, isHead: Bool, on id: HTTP2StreamID) async {
        var status = response.status
        var headers = response.headers
        var body = response.body
        if case .tunnel = body {
            // Extended CONNECT arrives with #0067.
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
        let bodyless: Bool
        switch body {
        case .empty, .tunnel: bodyless = true
        case .bytes(let bytes): bodyless = !hasContent || bytes.readableBytes == 0
        case .file(let region): bodyless = !hasContent || region.length == 0
        case .stream: bodyless = !hasContent
        }
        let head = await enqueue { shared, ticket, wakeups in
            shared.sendHeaders(streamID: id, status: status, headers: headers, contentLength: declaredLength,
                               endStream: bodyless, ticket: ticket, wakeups: &wakeups)
        }
        // A head that ended the stream (bodyless, or replaced by a bare 500 because the peer's
        // MAX_HEADER_LIST_SIZE refuses it) has no body.
        guard let head, !head.endStream else { return }
        do {
            switch body {
            case .empty, .tunnel:
                break
            case .bytes(let bytes):
                guard try await sendData(bytes, endStream: true, on: id) else { return }
            case .file(let region):
                guard try await sendFile(region, on: id) else { return }
            case .stream(_, let writer):
                try await writer(HTTP2DataWriter(driver: self, streamID: id))
                guard try await sendData(ByteBuffer(), endStream: true, on: id) else { return }
            }
        } catch {
            // The body failed after HEADERS: the response cannot be completed (#0049). A
            // cancelled stream is reset with CANCEL by `serve`.
            if !Task.isCancelled && !(error is CancellationError) {
                handle(.sendReset(streamID: id, .internalError))
            }
        }
    }

    /// Sends `bytes` as DATA frames, waiting for queue space and flow-control window. Returns
    /// false when the stream or connection closed first.
    func sendData(_ bytes: ByteBuffer, endStream: Bool, on id: HTTP2StreamID) async throws -> Bool {
        var remaining = bytes
        while true {
            let chunk = remaining
            guard let (length, ended) = await enqueue({ shared, ticket, wakeups in
                shared.sendData(streamID: id, bytes: chunk, endStream: endStream, ticket: ticket, wakeups: &wakeups)
            }) else {
                try Task.checkCancellation()
                return false
            }
            remaining.moveReaderIndex(forwardBy: length)
            if ended || (!endStream && remaining.readableBytes == 0) { return true }
        }
    }

    /// Sends a file region as DATA frames, reading at most ``HTTP2Configuration/fileChunkSize``
    /// bytes at a time into one reused buffer.
    func sendFile(_ region: FileRegion, on id: HTTP2StreamID) async throws -> Bool {
        var remaining = region.length
        var offset = region.offset
        let fd = region.file.rawValue
        let chunkSize = configuration.fileChunkSize
        var buffer = ByteBuffer(capacity: Int(Swift.min(Int64(chunkSize), remaining)))
        while remaining > 0 {
            try Task.checkCancellation()
            let want = Int(Swift.min(Int64(chunkSize), remaining))
            buffer.clear()
            let result: Int = buffer.withUnsafeMutableWritableBytes(minimumWritableBytes: want) { tail in
                while true {
                    let n = pread(fd, tail.baseAddress, want, off_t(offset))
                    if n >= 0 { return n }
                    if errno != EINTR { return -Int(errno) }
                }
            }
            if result < 0 { throw TransportError.fileReadFailed(errno: Int32(-result)) }
            if result == 0 { throw TransportError.unexpectedEndOfFile }
            buffer.commitWritten(result)
            offset += Int64(result)
            remaining -= Int64(result)
            guard try await sendData(buffer, endStream: remaining == 0, on: id) else { return false }
        }
        return true
    }
}

extension HTTP2ConnectionDriver: HTTP2ReceiveCredit {
    func bodyConsumed(streamID: HTTP2StreamID, length: Int) {
        handle(.bodyConsumed(streamID: streamID, length: length))
    }
}

/// The ``HTTPBodyWriter`` for `.stream` responses: each write becomes DATA frames, sent with
/// the connection's queue and flow-control backpressure.
struct HTTP2DataWriter<Transport: ByteStreamTransport, Handler: HTTPHandler>: HTTPBodyWriter {
    let driver: HTTP2ConnectionDriver<Transport, Handler>
    let streamID: HTTP2StreamID

    func write(_ bytes: ByteBuffer) async throws {
        guard bytes.readableBytes > 0 else { return }
        guard try await driver.sendData(bytes, endStream: false, on: streamID) else {
            throw TransportError.closed
        }
    }
}
