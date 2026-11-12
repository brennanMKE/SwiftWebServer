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
/// ## Not yet
///
/// Trailers in responses, `.tunnel` / extended CONNECT (#0111; answered `501`), and abuse
/// limits such as rapid reset (#0104).
public struct HTTP3: MultiplexedConnectionProtocol {
    public var configuration: H3Configuration

    public init(configuration: H3Configuration = H3Configuration()) {
        self.configuration = configuration
    }

    public static var alpnTokens: [String] { ["h3"] }

    public func run<T: MultiplexedTransport, H: HTTPHandler>(
        _ t: T, handler: H, context: ConnectionContext
    ) async where T.Stream: ResettableStream {
        // Every HTTP/3 connection negotiated `h3`; say so even where the transport could not
        // read it back, so the chain can tell HTTP/3 requests apart (``AltSvc``, #0103).
        var context = context
        if context.info.negotiatedALPN == nil { context.info.negotiatedALPN = "h3" }
        let driver = H3ConnectionDriver(transport: t, handler: handler, context: context, configuration: configuration)
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

    init(transport: Transport, handler: Handler, context: ConnectionContext, configuration: H3Configuration) {
        self.transport = transport
        self.handler = handler
        self.context = context
        self.configuration = configuration
        state = Mutex(Shared(machine: H3Connection(configuration: configuration), idleSince: .now))
        credit = transport as? any StreamCreditGranting
    }

    func run() async {
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
        var parser = H3FrameParser(configuration: .init(streamKind: .control, role: .server))
        while true {
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
            buffer.clear()
            guard await receiveCritical(stream, into: &buffer, critical: .control) else { return }
        }
    }

    func readQPACKStream(_ stream: Stream, buffer initial: ByteBuffer, critical: H3Connection.CriticalStream) async {
        var buffer = initial
        var encoderReader = QPACKEncoderStreamReader()
        var decoderReader = QPACKDecoderStreamReader()
        while true {
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
                    buffer.moveReaderIndex(forwardBy: consumed)
                }
            } catch {
                await fail(.qpackFailure(code: error.code.rawValue), stream: nil)
                return
            }
            // A partial instruction (a few bytes at most) stays for the next receive.
            _ = buffer.discardReadBytes()
            guard await receiveCritical(stream, into: &buffer, critical: critical) else { return }
        }
    }

    // MARK: Request streams

    /// Admits the request stream (or rejects it), serves it under its ``H3StreamWatch``, and
    /// reports it closed so stream credit and the drain can follow.
    func serveRequest(_ stream: Stream) async {
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

        if let watch = H3StreamWatch.make(configuration.timeouts) {
            let fired = await withTaskGroup(of: H3StreamWatch.Phase?.self) { group in
                group.addTask {
                    await self.process(stream, watch: watch)
                    watch.finish()
                    return nil
                }
                group.addTask { await watch.run() }
                var fired: H3StreamWatch.Phase?
                for await phase in group {
                    if let phase { fired = phase }
                    // Either the stream finished (stop the watchdog) or a deadline passed
                    // (stop the stream's tasks).
                    group.cancelAll()
                }
                return fired
            }
            if let fired { await timedOut(fired, stream: stream, watch: watch) }
        } else {
            await process(stream, watch: nil)
        }
        await stream.close(.normal)
        requestStreamClosed(served: true)
    }

    func admit(_ streamID: UInt64) async -> H3Connection.Action {
        let action = state.withLock { shared in
            let action = shared.machine.handle(.requestStream(streamID: streamID))
            if action == .serveRequest { shared.idleSince = nil }
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
            if shared.machine.activeRequestStreams == 0 && shared.idleSince == nil { shared.idleSince = .now }
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
                await write(HTTPResponse(status: .requestTimeout), isHead: false, on: stream, watch: nil)
                await fail(.unreadBodyAbandoned, stream: stream)
            }
        case .drain:
            await fail(.unreadBodyAbandoned, stream: stream)
        }
    }

    /// Reads the request head and serves the request, or fails the stream.
    func process(_ stream: Stream, watch: H3StreamWatch?) async {
        let storage = HTTPRequestStorage(bufferCapacity: 512, fieldCapacity: 16)
        var reader = H3RequestReader(configuration: configuration, storage: storage)
        switch await reader.next(from: stream) {
        case .head(let request):
            watch?.enterBody()
            await serve(request, rejection: nil, on: stream, reader: reader, watch: watch)
        case .headError(let error):
            switch error {
            case .malformed:
                await fail(.malformedRequest, stream: stream)
            case .unservableFieldSection:
                await fail(.unservableFieldSection, stream: stream)
            case .fieldSectionTooLarge:
                watch?.enterBody()
                await serve(nil, rejection: .requestHeaderFieldsTooLarge, on: stream, reader: reader, watch: watch)
            case .qpack(let qpack):
                await fail(.qpackFailure(code: qpack.code.rawValue), stream: nil)
            }
        case .streamError(let error):
            await fail(H3Failure(streamError: error), stream: stream)
        case .connectionError(let code):
            await fail(H3Failure(connectionErrorCode: code), stream: nil)
        case .data, .end, .peerReset, .failed:
            // DATA before HEADERS is a connection error, and `end` without HEADERS is a stream
            // error, so neither arrives here; a reset or failed stream has nobody to answer.
            return
        }
    }

    enum StreamOutcome: Sendable {
        case bodyRead(H3RequestReader.Event)
        /// The body grew past ``H3Configuration/maxRequestBodySize``; the reader stopped.
        case bodyTooLarge
        /// The response was written; `bodyDrained` is false when the unread request body hit
        /// ``H3Configuration/maxUnreadBodySize``.
        case responded(bodyDrained: Bool)
    }

    /// Runs the handler for `head` (or answers `rejection` without it) next to the body reader,
    /// and handles the first of: peer reset, malformed body, end of both.
    func serve(_ head: HTTPRequest?, rejection: HTTPStatus?, on stream: Stream, reader: H3RequestReader, watch: H3StreamWatch?) async {
        let channel = H3BodyChannel(capacity: configuration.bodyQueueCapacity, streamID: stream.streamID, watch: watch)
        let declared = reader.machine.contentLength
        var rejection = rejection
        if rejection == nil, let declared, declared > UInt64(configuration.maxRequestBodySize) {
            rejection = .contentTooLarge
        }
        let length = declared.flatMap { Int(exactly: $0) }
        let request = rejection != nil ? nil : head.map { head -> HTTPRequest in
            var request = head
            request.body = HTTPRequestBody(source: channel, request: channel.streamID, length: length)
            return request
        }
        let status = rejection ?? .internalServerError
        let abandonBody = await withTaskGroup(of: StreamOutcome.self) { group -> Bool in
            group.addTask {
                var reader = reader
                return await self.pumpBody(from: stream, reader: &reader, into: channel)
            }
            group.addTask {
                await self.respond(to: request, rejection: status, storage: reader.storage, on: stream, body: channel, watch: watch)
            }
            var abandonBody = false
            for await outcome in group {
                switch outcome {
                case .bodyRead(let end):
                    switch end {
                    case .end:
                        continue
                    case .peerReset, .failed:
                        group.cancelAll()
                    case .streamError(let error):
                        group.cancelAll()
                        await fail(H3Failure(streamError: error), stream: stream)
                    case .connectionError(let code):
                        group.cancelAll()
                        await fail(H3Failure(connectionErrorCode: code), stream: nil)
                    case .head, .headError, .data:
                        continue
                    }
                case .bodyTooLarge:
                    // The handler's read fails with `tooLarge` and it answers `413`; the rest of
                    // the body is not read.
                    abandonBody = true
                case .responded(let bodyDrained):
                    if !bodyDrained {
                        abandonBody = true
                        group.cancelAll()
                    }
                }
            }
            return abandonBody
        }
        if abandonBody { await fail(.unreadBodyAbandoned, stream: stream) }
    }

    /// Feeds DATA payload to `channel` until FIN or an error, and reports how the body ended.
    /// Suspends (and so stops reading the stream) while the channel is full.
    func pumpBody(from stream: Stream, reader: inout H3RequestReader, into channel: H3BodyChannel) async -> StreamOutcome {
        let limit = configuration.maxRequestBodySize
        var received = 0
        while true {
            let event = await reader.next(from: stream)
            switch event {
            case .data(let chunk):
                received += chunk.readableBytes
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
        let response: HTTPResponse
        if let request {
            isHead = request.method == .head
            var requestContext = context.requestContext
            if context.recordsRequestStartTime { requestContext.startTime = .now() }
            do {
                response = try await handler.handle(request, context: requestContext)
                storage.endRequest()
                body.expire()
            } catch {
                storage.endRequest()
                body.expire()
                // Cancelled (peer reset, timeout), or the body turned out malformed: `serve`
                // resets the stream, so nothing is written here.
                guard !Task.isCancelled else { return .responded(bodyDrained: true) }
                if body.isTooLarge {
                    response = HTTPResponse(status: .contentTooLarge)
                } else {
                    guard !body.failed else { return .responded(bodyDrained: true) }
                    response = HTTPResponse(status: .internalServerError)
                }
            }
        } else {
            response = HTTPResponse(status: rejection)
        }
        guard !Task.isCancelled else { return .responded(bodyDrained: true) }
        await write(response, isHead: isHead, on: stream, watch: watch)
        guard !Task.isCancelled else { return .responded(bodyDrained: true) }
        watch?.enterDrain()
        var discarded = 0
        for await chunk in body.queue {
            discarded += chunk.readableBytes
            if discarded > configuration.maxUnreadBodySize { return .responded(bodyDrained: false) }
        }
        return .responded(bodyDrained: true)
    }

    /// Writes `response` as HEADERS and DATA frames, then FIN.
    func write(_ response: HTTPResponse, isHead: Bool, on stream: Stream, watch: H3StreamWatch?) async {
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
                try await stream.send(out, endOfStream: true)

            case .bytes(let bytes):
                if hasContent && bytes.readableBytes > 0 {
                    var sink = ByteBufferSink(buffer: out)
                    try H3FrameEncoder.encodeDataHeader(length: UInt64(bytes.readableBytes), into: &sink)
                    out = sink.buffer
                    out.append(bytes)
                }
                try await stream.send(out, endOfStream: true)

            case .file(let region):
                guard hasContent && region.length > 0 else {
                    try await stream.send(out, endOfStream: true)
                    return
                }
                var sink = ByteBufferSink(buffer: out)
                try H3FrameEncoder.encodeDataHeader(length: UInt64(region.length), into: &sink)
                headSent = true
                try await stream.send(sink.buffer, endOfStream: false)
                // The transport reads the region in bounded chunks (`sendFileByReading`).
                try await stream.sendFile(region)
                try await stream.send(ByteBuffer(), endOfStream: true)

            case .stream(_, let writer):
                headSent = true
                try await stream.send(out, endOfStream: false)
                if hasContent {
                    try await writer(H3DataWriter(stream: stream))
                }
                try await stream.send(ByteBuffer(), endOfStream: true)
            }
        } catch {
            // A peer reset or STOP_SENDING, cancellation, or a failing body writer or file.
            if headSent && !Task.isCancelled {
                await fail(.responseFailed, stream: stream)
            }
        }
    }
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
