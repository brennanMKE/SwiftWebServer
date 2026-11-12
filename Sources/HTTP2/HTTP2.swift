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
/// section if one follows. The bound is the stream's receive window: credit (stream and
/// connection WINDOW_UPDATE, batched at half a window) goes back only as the handler consumes
/// bytes, so a handler that does not read stalls only its own stream. A DATA total that differs
/// from `content-length`, invalid trailers, or DATA past the stream window reset the stream.
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
/// ## Not yet
///
/// Per-stream cancellation on RST_STREAM (#0051), the PING round-trip on shutdown and idle
/// timeouts (#0052), the full inbound window policy (#0053), fair window waiting (#0054),
/// extended CONNECT (#0067: `.tunnel` answers `501`).
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
                    if shutdown.isTriggered { self.handle(.shutdown) }
                }
                await runReader(streams: &streams)
                // End of input, a connection error, or the writer closed the transport: end the
                // request bodies and stop the handlers and timers.
                let bodies = state.withLock { shared in
                    defer { shared.bodies.removeAll() }
                    return Array(shared.bodies.values)
                }
                for body in bodies { body.fail(TransportError.closed) }
                streams.cancelAll()
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

    func closeOutbound(_ reason: CloseReason) {
        var wakeups = HTTP2Wakeups()
        state.withLock { $0.close(reason, wakeups: &wakeups) }
        wakeups.resume()
    }

    /// Suspends until the shared state's generation moves past `generation` (queue space or
    /// window became available, or the connection is closing) or the task is cancelled.
    func waitForProgress(since generation: UInt64) async {
        let id = state.withLock { shared -> UInt64 in
            defer { shared.nextWaiterID &+= 1 }
            return shared.nextWaiterID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { shared -> Bool in
                    if shared.generation != generation || !shared.isOpen || Task.isCancelled { return true }
                    shared.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }

    /// Repeats `attempt` (a critical section) until it sends or drops, waiting in between.
    /// Returns the sent length and END_STREAM, or `nil` when dropped or cancelled.
    func enqueue(
        _ attempt: (inout HTTP2SharedState, inout HTTP2Wakeups) -> HTTP2SharedState.StreamStep
    ) async -> (length: Int, endStream: Bool)? {
        while true {
            var wakeups = HTTP2Wakeups()
            let step = state.withLock { attempt(&$0, &wakeups) }
            wakeups.resume()
            switch step {
            case .sent(let length, let endStream):
                return (length, endStream)
            case .dropped:
                return nil
            case .wait(let generation):
                await waitForProgress(since: generation)
                if Task.isCancelled { return nil }
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

    // MARK: Timers

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
        /// Serve a request on a new stream task; `body` feeds its request body.
        case serve(HTTP2StreamID, HTTPRequest, HTTPRequestStorage, body: HTTP2BodyChannel?)
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

    /// The stream receive window the peer may fill before our SETTINGS are acknowledged and
    /// after: the larger of the default and the advertised one.
    var streamReceiveWindow: Int {
        Swift.max(Int(configuration.initialWindowSize), Int(HTTP2Connection.defaultWindowSize))
    }

    /// Reads the preface and then frames until end of input, a transport error, or a
    /// connection error.
    func runReader(streams: inout DiscardingTaskGroup) async {
        var buffer = ByteBuffer(capacity: configuration.receiveSize)
        guard await readPreface(into: &buffer) else { return }

        var parser = HTTP2FrameParser(configuration: .init(role: .server))
        var assembler = HeaderBlockAssembler(configuration: .init(
            maxBlockSize: configuration.maxHeaderListSize, maxContinuationFrames: configuration.maxContinuationFrames))
        // Until our SETTINGS are acknowledged the peer may use the default 4,096-byte table.
        var decoder = HPACKDecoder(
            maxTableSize: Swift.max(configuration.headerTableSize, Int(HTTP2Connection.defaultHeaderTableSize)),
            maxHeaderListSize: configuration.maxHeaderListSize)
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
                    return
                case .serve(let id, let request, let storage, let body):
                    streams.addTask { await self.serve(id, request: request, storage: storage, body: body) }
                }
            }
            buffer.clear()
            do {
                guard try await transport.receive(into: &buffer, maxLength: configuration.receiveSize) > 0 else { return }
            } catch {
                return
            }
        }
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
                let action = assembler.handle(.headers(
                    streamID: id, endStream: endStream, endHeaders: endHeaders, priority: priority, fragment: fragment))
                return headerBlock(action, fragment: fragment, assembler: assembler, decoder: &decoder)
            }
        case .continuation(let id, let endHeaders, let location):
            return parser.withPayload(location, in: input) { fragment in
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
        case .rstStream(let id, let code):
            gate = assembler.handle(.otherFrame(.rstStream, streamID: id))
            machineEvent = .rstStream(streamID: id, code)
        case .settings(let settings):
            gate = assembler.handle(.otherFrame(.settings, streamID: .connection))
            machineEvent = .settings(settings)
        case .settingsAck:
            gate = assembler.handle(.otherFrame(.settings, streamID: .connection))
            machineEvent = .settingsAck
        case .ping(let ack, let data):
            gate = assembler.handle(.otherFrame(.ping, streamID: .connection))
            machineEvent = .ping(ack: ack, opaqueData: data)
        case .goaway(let last, let code, _):
            gate = assembler.handle(.otherFrame(.goaway, streamID: .connection))
            machineEvent = .goaway(lastStreamID: last, code)
        case .windowUpdate(let id, let increment):
            gate = assembler.handle(.otherFrame(.windowUpdate, streamID: id))
            machineEvent = .windowUpdate(streamID: id, increment: increment)
        case .unknown(let header):
            gate = assembler.handle(.otherFrame(header.type, streamID: header.streamID))
            machineEvent = .unknownFrame
        case .streamError(let error):
            gate = assembler.handle(.otherFrame(.priority, streamID: error.streamID ?? .connection))
            machineEvent = .streamError(error)
        }
        if case .connectionError(let code) = gate {
            handle(.connectionError(.connection(code, reason: "frame inside a header block")))
            return .stop
        }
        switch handle(machineEvent) {
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
            bodyConsumed(streamID: target.streamID, length: payload.count, streamIncrement: nil)
            return
        }
        switch body.receive(payload) {
        case .accepted:
            break
        case .malformed:
            // More DATA than `content-length` (RFC 9113 §8.1.1).
            handle(.sendReset(streamID: target.streamID, .protocolError))
        case .flowControlError:
            handle(.sendReset(streamID: target.streamID, .flowControlError))
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
                var sink = HTTP2TrailerFieldSink()
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
        var sink = HTTP2RequestFieldSink(storage: storage)
        try assembler.decode(block, fragment: fragment, with: &decoder, into: &sink)
        guard case .success(let head) = sink.head(endStream: block.endStream) else {
            // Malformed (RFC 9113 §8.1.1): a stream error. The stream was counted as served
            // when it was dispatched.
            handle(.sendReset(streamID: id, .protocolError))
            streamEnded(id)
            return .proceed
        }
        guard !block.endStream else { return .serve(id, head.request, storage, body: nil) }
        let body = HTTP2BodyChannel(
            streamID: id, declaredLength: head.contentLength, window: streamReceiveWindow, credit: self)
        state.withLock { $0.bodies[id.rawValue] = body }
        var request = head.request
        request.body = HTTPRequestBody(source: body, request: body.requestID, length: head.contentLength)
        return .serve(id, request, storage, body: body)
    }

    // MARK: Streams

    /// Runs the handler for one request and writes its response.
    func serve(_ id: HTTP2StreamID, request: HTTPRequest, storage: HTTPRequestStorage, body: HTTP2BodyChannel?) async {
        let isHead = request.method == .head
        var requestContext = context.requestContext
        if context.recordsRequestStartTime { requestContext.startTime = .now() }
        var response: HTTPResponse?
        do {
            response = try await handler.handle(request, context: requestContext)
        } catch {
            if !Task.isCancelled { response = HTTPResponse(status: .internalServerError) }
        }
        storage.endRequest()
        // Body bytes the handler did not read are discarded and credited.
        body?.expire()
        if let response, !Task.isCancelled {
            await write(response, isHead: isHead, on: id)
        }
        streamEnded(id)
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
        let head = await enqueue { shared, wakeups in
            shared.sendHeaders(streamID: id, status: status, headers: headers, contentLength: declaredLength,
                               endStream: bodyless, wakeups: &wakeups)
        }
        guard head != nil, !bodyless else { return }
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
            // The body failed after HEADERS: the response cannot be completed (#0049).
            if !Task.isCancelled { handle(.sendReset(streamID: id, .internalError)) }
        }
    }

    /// Sends `bytes` as DATA frames, waiting for queue space and flow-control window. Returns
    /// false when the stream or connection closed first.
    func sendData(_ bytes: ByteBuffer, endStream: Bool, on id: HTTP2StreamID) async throws -> Bool {
        var remaining = bytes
        while true {
            let chunk = remaining
            guard let (length, ended) = await enqueue({ shared, wakeups in
                shared.sendData(streamID: id, bytes: chunk, endStream: endStream, wakeups: &wakeups)
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
    func bodyConsumed(streamID: HTTP2StreamID, length: Int, streamIncrement: UInt32?) {
        handle(.bodyConsumed(streamID: streamID, length: length, streamIncrement: streamIncrement))
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
