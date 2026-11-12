public import HTTPCore
import Synchronization

/// Settings for HTTP/1.1 connections.
public struct HTTP1Configuration: Sendable, Hashable {
    /// Request-head limits (414, 431, 501 on overflow).
    public var parserLimits: HTTP1ParserLimits
    /// Most bytes asked for per receive. The receive buffer starts at this size and, because
    /// it is compacted after every batch, stays within about this plus one head.
    public var receiveSize: Int
    /// The output buffer is sent early, before the pipelined batch ends, once it holds this
    /// many bytes, so a long pipeline of large responses does not grow it without bound.
    public var flushThreshold: Int
    /// The largest request body accepted (legacy #0011): a larger `Content-Length` is answered
    /// with `413 Content Too Large` before the handler runs, and a chunked body that grows
    /// past it fails the handler's read and is answered with `413`. Either way the connection
    /// closes.
    public var maxBodySize: Int
    /// The most body bytes read and discarded when a handler returns without reading the whole
    /// body. A longer rest (or a malformed body) closes the connection instead.
    public var maxDrainSize: Int
    /// Chunk-size, extension and trailer limits for chunked request bodies.
    public var chunkedLimits: ChunkedDecoderLimits
    /// Header, idle, body, send and linger limits (#0082).
    public var timeouts: HTTP1Timeouts
    /// The most input bytes a lingering close reads and discards before closing.
    public var maxLingerSize: Int

    public static let defaultReceiveSize = 16 * 1024
    public static let defaultFlushThreshold = 64 * 1024
    public static let defaultMaxBodySize = 10 * 1024 * 1024
    public static let defaultMaxDrainSize = 64 * 1024
    public static let defaultMaxLingerSize = 1024 * 1024

    public init(
        parserLimits: HTTP1ParserLimits = HTTP1ParserLimits(),
        receiveSize: Int = HTTP1Configuration.defaultReceiveSize,
        flushThreshold: Int = HTTP1Configuration.defaultFlushThreshold,
        maxBodySize: Int = HTTP1Configuration.defaultMaxBodySize,
        maxDrainSize: Int = HTTP1Configuration.defaultMaxDrainSize,
        chunkedLimits: ChunkedDecoderLimits = ChunkedDecoderLimits(),
        timeouts: HTTP1Timeouts = HTTP1Timeouts(),
        maxLingerSize: Int = HTTP1Configuration.defaultMaxLingerSize
    ) {
        precondition(receiveSize > 0 && flushThreshold > 0, "HTTP1Configuration sizes must be positive")
        precondition(maxBodySize >= 0 && maxDrainSize >= 0 && maxLingerSize >= 0,
                     "HTTP1Configuration limits must not be negative")
        self.parserLimits = parserLimits
        self.receiveSize = receiveSize
        self.flushThreshold = flushThreshold
        self.maxBodySize = maxBodySize
        self.maxDrainSize = maxDrainSize
        self.chunkedLimits = chunkedLimits
        self.timeouts = timeouts
        self.maxLingerSize = maxLingerSize
    }
}

/// HTTP/1.1 as a ``ConnectionProtocol``: register it with the server's protocol registry.
///
/// ```swift
/// let server = Server(configuration: config, listeners: [listener],
///                     protocols: [HTTP1()], handler: app)
/// ```
///
/// ## The hot loop (docs/ROADMAP.md §5.3)
///
/// One connection is one call to ``run(_:handler:context:)``, which owns the receive buffer,
/// the parser, the serializer, the output buffer and the ``HTTP1Connection`` state machine as
/// locals: no actor, no per-request task, no lock. Per batch of pipelined requests:
///
/// 1. one `receive` into the reused receive buffer (the request storage's arena);
/// 2. parse every complete head it holds; for each, call the handler and serialize the
///    response into the one output buffer, in request order;
/// 3. one `send` of the output buffer.
///
/// After each batch the consumed bytes are discarded, so the buffer does not grow across
/// requests (legacy #0007). `.file` bodies are sent with ``ByteStreamTransport/sendFile(_:)``
/// after the head is flushed.
///
/// ## Errors
///
/// - An invalid head is answered with its ``HTTP1ParseError/status`` and `connection: close`.
/// - A handler that throws gets `500` and `connection: close` (legacy #0009). Responses already
///   serialized for earlier pipelined requests are sent first.
/// - A receive or send error ends the connection with no further response (legacy #0008).
/// - End of stream between requests or in the middle of a head closes quietly.
///
/// ## Bodies (#0081)
///
/// - Request bodies are read by the handler through ``HTTPRequest/body``, on demand, by an
///   ``HTTP1RequestBodyReader`` that borrows this loop's transport and receive buffer while
///   the handler runs. `Expect: 100-continue` gets `100 Continue` when the handler first reads.
///   A body the handler did not finish is drained up to ``HTTP1Configuration/maxDrainSize``
///   before the response, or the response says `close`. Limits: see
///   ``HTTP1Configuration/maxBodySize``.
/// - `.stream` responses: the head is sent, then the writer's bytes, each write one `send`
///   (backpressure) through an ``HTTP1ResponseBodyWriter``: with `Content-Length` when the
///   length is known (a mismatch aborts the connection), chunked when it is not, and for
///   HTTP/1.0 delimited by closing the connection. A writer that throws after the head was
///   sent aborts the connection.
/// - HEAD, `204` and `304` responses never carry body bytes, whatever the body kind; the
///   serializer keeps their headers (#0016, #0018) and the writer or file is not run.
///
/// ## Timeouts and draining (#0082)
///
/// `run` supervises the loop with two more child tasks of one task group per connection (never
/// a task per request): a timer, and a waiter on the shutdown signal. They share one atomic
/// word with the loop (``HTTP1Watchdog``) that says which phase it is in and until when; see
/// ``HTTP1Timeouts`` for the limits.
///
/// - An incomplete head or a stalled body past its limit gets `408 Request Timeout` and
///   `connection: close`, sent by the supervisor while the loop still waits in `receive`
///   (cancelling a TCP receive cancels the whole connection), then a lingering close.
/// - The idle limit closes silently; a send past its limit resets the connection.
/// - When the server drains, a connection between requests (idle, or part of a head) closes
///   at once. An exchange in flight finishes and its response says `connection: close`;
///   pipelined requests not yet started get no response.
/// - Lingering close: when the connection closes with request bytes possibly unread (an error
///   response, an unread body, dropped pipelined requests, a `408`), the output is half-closed
///   and input is discarded for at most ``HTTP1Timeouts/linger`` (and
///   ``HTTP1Configuration/maxLingerSize`` bytes), so the client reads the response rather
///   than a reset.
///
/// ## Hooks
///
/// - `.tunnel` responses (#0108): the head (`101` from the handler) is flushed, then the byte
///   stream is handed to the closure, replaying any bytes buffered after the request. No
///   HTTP/1.1 limit applies to a tunnel.
public struct HTTP1: ConnectionProtocol {
    public var configuration: HTTP1Configuration

    public init(configuration: HTTP1Configuration = HTTP1Configuration()) {
        self.configuration = configuration
    }

    public static var alpnTokens: [String] { ["http/1.1"] }

    /// Matches bytes that start like a request line: optional empty lines, then a method token
    /// followed by a space. The HTTP/2 preface (`PRI * HTTP/2.0`) also matches, so register
    /// HTTP/2 before HTTP/1.1 when both serve cleartext.
    public static func matchesCleartextPreface(_ bytes: borrowing ByteBuffer) -> SniffResult {
        bytes.withReadableSpan { span in
            var methodLength = 0
            for i in span.indices {
                let byte = span[i]
                if methodLength == 0 && (byte == 0x0D || byte == 0x0A) { continue }
                if byte == UInt8(ascii: " ") { return methodLength > 0 ? .match : .noMatch }
                guard ASCII.isTokenCharacter(byte) else { return .noMatch }
                methodLength &+= 1
                if methodLength > 24 { return .noMatch }
            }
            return .needMoreBytes
        }
    }

    public func run<T: ByteStreamTransport, H: HTTPHandler>(_ t: T, handler: H, context: ConnectionContext) async {
        let reason = await Self.supervise(t, handler: handler, context: context, configuration: configuration)
        await t.close(reason)
    }

    enum SupervisorEvent: Sendable {
        case driverEnded(HTTP1Ending)
        /// The timer's expired word, or `nil` when it stopped.
        case timer(UInt64?)
        case shutdown
        /// The supervisor's `408` was sent (true), or the send failed.
        case errorSent(Bool)
    }

    /// Runs the connection loop under its timer and the shutdown signal; returns how to close
    /// the transport.
    static func supervise<T: ByteStreamTransport, H: HTTPHandler>(
        _ t: T, handler: H, context: ConnectionContext, configuration: HTTP1Configuration
    ) async -> CloseReason {
        let watchdog = HTTP1Watchdog()
        let ticks = HTTP1TimeoutTicks(configuration.timeouts)
        let tick = ticks.shortest
        let shutdown = context.shutdown
        return await withTaskGroup(of: SupervisorEvent.self) { group in
            group.addTask {
                var driver = HTTP1ConnectionDriver(transport: t, handler: handler, context: context,
                                                   configuration: configuration, watchdog: watchdog)
                let ending = await driver.run()
                // Taken over: keep reading and discarding until the supervisor is done, so its
                // `408` is not followed by a reset.
                if watchdog.isOwned { await driver.discardInput() }
                return .driverEnded(ending)
            }
            var timerRunning = tick != 0
            if timerRunning {
                group.addTask { .timer(await watchdog.runTimer(tick: tick)) }
            }
            group.addTask {
                await shutdown.wait()
                return .shutdown
            }

            var driverEnding: HTTP1Ending?
            // Set once the supervisor decided the ending; a nil verdict keeps the driver's.
            var decided = false
            var verdict: CloseReason?
            var sendingError = false
            while let event = await group.next() {
                switch event {
                case .driverEnded(let ending):
                    driverEnding = ending

                case .timer(let word):
                    timerRunning = false
                    guard let word else { break }
                    decided = true
                    let phase = HTTP1Watchdog.phase(of: word)
                    if HTTP1Watchdog.isOwned(word) {
                        // The supervisor's own send or linger ran out.
                        if phase == .send { verdict = .abort }
                        group.cancelAll()
                        break
                    }
                    switch phase {
                    case .head, .body:
                        // The loop waits in receive and sends nothing more: answer for it.
                        verdict = .timeout
                        sendingError = true
                        watchdog.own(.send, deadline: watchdog.deadline(after: ticks.send))
                        if ticks.send != 0 {
                            timerRunning = true
                            group.addTask { .timer(await watchdog.runTimer(tick: tick)) }
                        }
                        let response = timeoutResponse()
                        group.addTask {
                            do {
                                try await t.send(response, endOfStream: true)
                                return .errorSent(true)
                            } catch {
                                return .errorSent(false)
                            }
                        }
                    case .idle:
                        verdict = .timeout
                        group.cancelAll()
                    case .send:
                        verdict = .abort
                        group.cancelAll()
                    case .linger, .none, .done:
                        // The loop's own lingering close ran out: its ending stands.
                        group.cancelAll()
                    }

                case .shutdown:
                    // Between requests: close now. In flight: the loop finishes the exchange.
                    if shutdown.isTriggered && !decided && watchdog.takeOverIfBetweenRequests() {
                        decided = true
                        verdict = .shutdown
                        group.cancelAll()
                    }

                case .errorSent(let sent):
                    sendingError = false
                    if !sent {
                        verdict = .abort
                        group.cancelAll()
                    } else if driverEnding == nil && ticks.linger != 0 {
                        // Lingering close: the loop discards input until the client closes.
                        watchdog.own(.linger, deadline: watchdog.deadline(after: ticks.linger))
                        if !timerRunning {
                            timerRunning = true
                            group.addTask { .timer(await watchdog.runTimer(tick: tick)) }
                        }
                    } else {
                        group.cancelAll()
                    }
                }
                // Done once the loop ended, no `408` is in flight, and a takeover (if any) was
                // decided here (the timer's event can arrive after the loop noticed it).
                if let driverEnding, !sendingError, decided || !watchdog.isOwned {
                    group.cancelAll()
                    return verdict ?? driverEnding.closeReason
                }
            }
            return verdict ?? driverEnding?.closeReason ?? .abort
        }
    }

    /// `408 Request Timeout` with `connection: close`.
    static func timeoutResponse() -> ByteBuffer {
        var serializer = HTTP1Serializer()
        var output = ByteBuffer(capacity: 160)
        serializer.write(HTTPResponse(status: .requestTimeout), into: &output,
                         context: HTTP1ResponseContext(requestMethod: .get, persistence: .close))
        return output
    }
}

/// How a connection ended.
enum HTTP1Ending: Equatable {
    case closed(CloseReason)
    /// The tunnel closure owned the transport; it closes it (and the server closes it again).
    case tunnelled
    /// The supervisor took over (a timeout or a drain); it decides how the connection ends.
    case preempted

    var closeReason: CloseReason {
        switch self {
        case .closed(let reason): reason
        case .tunnelled: .normal
        case .preempted: .abort
        }
    }
}

/// The per-connection loop of ``HTTP1``: all connection state as stored properties of one
/// local value, mutated in place (no actor, no allocation per request).
struct HTTP1ConnectionDriver<Transport: ByteStreamTransport, Handler: HTTPHandler> {
    /// Largest piece of a `.file` body handed to one `sendFile`, so the send limit bounds a
    /// stall rather than the whole file.
    static var fileSlice: Int64 { 1024 * 1024 }
    /// Largest piece of the output buffer handed to one `send` (see ``sendLeadingSlices()``).
    static var sendSlice: Int { 1024 * 1024 }

    let transport: Transport
    let handler: Handler
    let shutdown: ShutdownSignal
    /// Passed to every request, with a fresh ``RequestContext/startTime`` when `recordsStartTime`.
    var requestContext: RequestContext
    let recordsStartTime: Bool
    let configuration: HTTP1Configuration
    let watchdog: HTTP1Watchdog
    let ticks: HTTP1TimeoutTicks
    /// The receive buffer is `storage.buffer`: requests borrow their bytes from it directly.
    let storage: HTTPRequestStorage
    var parser: HTTP1Parser
    var serializer: HTTP1Serializer<SystemWallClock>
    var output: ByteBuffer
    var connection: HTTP1Connection
    /// Created on the first request with a body, then reused.
    var bodyReader: HTTP1RequestBodyReader<Transport>?
    /// Created on the first `.stream` response, then reused.
    var bodyWriter: HTTP1ResponseBodyWriter<Transport>?
    /// True from the first byte of a head until it is complete; `headDeadline` is its limit.
    var headStarted = false
    var headDeadline: UInt64 = 0
    /// Request bytes may be left unread at close (an error response, an unread body, dropped
    /// pipelined requests): close lingering.
    var unreadInput = false
    /// The client finished sending.
    var peerEnded = false
    /// The output was half-closed.
    var outputShut = false

    init(transport: Transport, handler: Handler, context: ConnectionContext, configuration: HTTP1Configuration,
         watchdog: HTTP1Watchdog = HTTP1Watchdog()) {
        self.transport = transport
        self.handler = handler
        self.shutdown = context.shutdown
        self.requestContext = RequestContext(connection: context.info)
        self.recordsStartTime = context.recordsRequestStartTime
        self.configuration = configuration
        self.watchdog = watchdog
        self.ticks = HTTP1TimeoutTicks(configuration.timeouts)
        storage = HTTPRequestStorage(bufferCapacity: configuration.receiveSize, fieldCapacity: 32)
        parser = HTTP1Parser(limits: configuration.parserLimits)
        serializer = HTTP1Serializer()
        output = ByteBuffer(capacity: 4 * 1024)
        connection = HTTP1Connection(maxBodySize: configuration.maxBodySize)
    }

    /// Runs the connection, closing lingering if request bytes may be unread; returns how it
    /// ended. The caller closes the transport.
    mutating func run() async -> HTTP1Ending {
        let ending = await serve()
        if case .closed(let reason) = ending, !reason.isAbortive, !peerEnded,
           unreadInput || !storage.buffer.isEmpty {
            await linger()
        }
        return ending
    }

    /// The request loop.
    mutating func serve() async -> HTTP1Ending {
        while true {
            compactReceiveBuffer()
            // Publish the phase, then look at the drain signal (this order pairs with the
            // supervisor's: it sets the signal, then reads the phase).
            let entered = headStarted
                ? watchdog.enter(.head, deadline: headDeadline)
                : watchdog.enter(.idle, deadline: watchdog.deadline(after: ticks.idle))
            guard entered else { return .preempted }
            if shutdown.isTriggered && !connection.isDraining {
                if case .close(let reason) = connection.handle(.shutdown) { return .closed(reason) }
            }

            // Suspension 1: one receive per batch.
            let received: Int
            do {
                received = try await transport.receive(into: &storage.buffer, maxLength: configuration.receiveSize)
            } catch {
                return ending(connection.handle(.receiveFailed))
            }
            guard watchdog.enter(.none) else { return .preempted }
            if received == 0 {
                peerEnded = true
                return ending(connection.handle(.endOfStream))
            }

            if let ending = await answerBufferedRequests() { return ending }

            // Suspension 2: one send per pipelined batch. The next phase is set at the top.
            if !output.isEmpty {
                if let ending = await flush(endOfStream: false, resetPhase: false) { return ending }
            }
        }
    }

    // MARK: Batch

    /// Parses and answers every complete head in the receive buffer, serializing responses
    /// into ``output`` in order. Returns an ending when the connection must stop (its output
    /// already flushed), or `nil` to receive more.
    mutating func answerBufferedRequests() async -> HTTP1Ending? {
        while true {
            switch parser.parseHead(into: storage) {
            case .needMoreBytes:
                let inProgress = parser.isInProgress
                _ = connection.handle(.needMoreBytes(headStarted: inProgress))
                if inProgress && !headStarted {
                    headStarted = true
                    headDeadline = watchdog.deadline(after: ticks.header)
                }
                return nil

            case .error(let error):
                headStarted = false
                unreadInput = true
                return await perform(connection.handle(.parseError(error)))

            case .complete:
                headStarted = false
                if shutdown.isTriggered && !connection.isDraining {
                    // Draining: a request not started yet gets no response.
                    storage.endRequest()
                    unreadInput = true
                    return await perform(connection.handle(.shutdown))
                }
                let head = parser.head
                let summary = HTTP1Connection.RequestSummary(head: head, fields: storage.fieldsView)
                let action = connection.handle(.head(summary))
                guard case .callHandler = action else {
                    storage.endRequest()
                    if summary.hasBody { unreadInput = true }
                    return await perform(action)
                }
                var request = head.request(in: storage)
                var reader: HTTP1RequestBodyReader<Transport>?
                if summary.hasBody {
                    let bodyReader = self.bodyReader ?? makeBodyReader()
                    reader = bodyReader
                    var expectsContinue = false
                    if case .handling(let exchange) = connection.state { expectsContinue = exchange.expectsContinue }
                    // Earlier responses go out first: before `100 Continue`, and before a
                    // body stall can be answered with `408`.
                    if !output.isEmpty {
                        if let ending = await flush(endOfStream: false) {
                            storage.endRequest()
                            return ending
                        }
                    }
                    request.body = bodyReader.begin(framing: head.framing, expectsContinue: expectsContinue)
                }
                // Stamped in place: one call site passing the stored context keeps the
                // unstamped path as cheap as before #0083.
                if recordsStartTime { requestContext.startTime = .now() }
                let response: HTTPResponse
                do {
                    response = try await handler.handle(request, context: requestContext)
                } catch {
                    storage.endRequest()
                    reader?.end()
                    // Cancelled (drain deadline): stop without answering.
                    if Task.isCancelled { return ending(connection.handle(.receiveFailed)) }
                    if let reader {
                        if reader.transportFailed { return ending(connection.handle(.receiveFailed)) }
                        if !reader.isFinished { unreadInput = true }
                        if let failure = Self.bodyFailure(reader.failure ?? (error as? HTTPRequestBodyError)) {
                            return await perform(connection.handle(.bodyFailed(failure)))
                        }
                    }
                    return await perform(connection.handle(.handlerFailed))
                }
                if let reader {
                    let ending = await settleBody(reader)
                    if ending != nil {
                        storage.endRequest()
                        reader.end()
                        return ending
                    }
                }
                storage.endRequest()
                reader?.end()
                if let ending = await write(response) { return ending }
            }
        }
    }

    // MARK: Request body

    mutating func makeBodyReader() -> HTTP1RequestBodyReader<Transport> {
        let reader = HTTP1RequestBodyReader(transport: transport, storage: storage,
                                            receiveSize: configuration.receiveSize,
                                            maxBodySize: configuration.maxBodySize,
                                            chunkedLimits: configuration.chunkedLimits)
        reader.watch(watchdog, bodyTicks: ticks.body, sendTicks: ticks.send)
        bodyReader = reader
        return reader
    }

    /// How a body error that made the handler throw is answered: `413` or `400`.
    static func bodyFailure(_ error: HTTPRequestBodyError?) -> HTTP1Connection.BodyFailure? {
        switch error {
        case .tooLarge: .tooLarge
        case .malformed, .truncated: .malformed
        case .expired, .concurrentRead, nil: nil
        }
    }

    /// After the handler returned: drains a body it did not finish, so the next head starts at
    /// the right byte, or marks the response `close`. Returns an ending if the transport failed.
    mutating func settleBody(_ reader: HTTP1RequestBodyReader<Transport>) async -> HTTP1Ending? {
        if reader.transportFailed { return ending(connection.handle(.receiveFailed)) }
        if reader.isFinished { return nil }
        let drainable = reader.canDrain(limit: configuration.maxDrainSize)
        guard case .drainBody = connection.handle(.bodyUnread(drainable: drainable)) else {
            unreadInput = true
            return nil
        }
        switch await reader.drain(limit: configuration.maxDrainSize) {
        case .complete:
            _ = connection.handle(.bodyDrained(complete: true))
        case .incomplete:
            unreadInput = true
            _ = connection.handle(.bodyDrained(complete: false))
        case .transportFailed:
            return ending(connection.handle(.receiveFailed))
        }
        return nil
    }

    // MARK: Response

    /// Serializes one handler response (and sends a file or stream body). Returns an ending
    /// when the connection must stop after it.
    mutating func write(_ response: HTTPResponse) async -> HTTP1Ending? {
        let kind: HTTP1Connection.ResponseKind
        switch response.body {
        case .empty, .bytes, .file:
            kind = .delimited
        case .tunnel:
            // Only 101 among 1xx switches protocols; any other 1xx cannot carry a tunnel.
            let code = response.status.code
            if code < 200 && code != 101 { return await perform(connection.handle(.handlerFailed)) }
            kind = .tunnel
        case .stream(let length, _):
            kind = length == nil ? .unknownLength : .delimited
        }
        // Draining started while the handler ran: this response is the last one.
        if shutdown.isTriggered && !connection.isDraining { _ = connection.handle(.shutdown) }
        guard case .writeResponse(let context) = connection.handle(.response(kind)) else {
            preconditionFailure("HTTP1Connection answers a response with writeResponse")
        }
        let framing = serializer.write(response, into: &output, context: context)
        switch framing {
        case .complete:
            break
        case .contentLength(let length):
            switch response.body {
            case .file(let region):
                if let ending = await flush(endOfStream: false, resetPhase: false) { return ending }
                if let ending = await sendFile(region) { return ending }
            case .stream(_, let writer):
                if let ending = await sendStream(writer, framing: .contentLength(length)) { return ending }
            default:
                preconditionFailure("only .file and .stream bodies are sent after the head")
            }
        case .chunked:
            guard case .stream(_, let writer) = response.body else { preconditionFailure("only .stream bodies are chunked") }
            if let ending = await sendStream(writer, framing: .chunked) { return ending }
        case .closeDelimited:
            guard case .stream(_, let writer) = response.body else { preconditionFailure("only .stream bodies are close-delimited") }
            if let ending = await sendStream(writer, framing: .closeDelimited) { return ending }
        case .tunnel:
            break
        }
        assert((kind == .tunnel) == (framing == .tunnel), "the serializer and the connection disagree on the tunnel")

        let next = connection.handle(.responseWritten)
        if case .startTunnel = next {
            guard case .tunnel(let body) = response.body else { preconditionFailure("tunnel without closure") }
            if let ending = await flush(endOfStream: false, resetPhase: false) { return ending }
            // No HTTP/1.1 limit applies to the tunnel; the timer stops.
            guard watchdog.enter(.done) else { return .preempted }
            await startTunnel(body)
            return .tunnelled
        }
        if case .proceed = next {
            if output.readableBytes >= configuration.flushThreshold {
                if let ending = await flush(endOfStream: false) { return ending }
            }
            return nil
        }
        return await perform(next)
    }

    /// Sends a file region in slices of at most ``fileSlice`` bytes, each under the send limit.
    mutating func sendFile(_ region: FileRegion) async -> HTTP1Ending? {
        var offset = region.offset
        var remaining = region.length
        repeat {
            let length = ticks.send == 0 ? remaining : min(remaining, Self.fileSlice)
            guard watchdog.enter(.send, deadline: watchdog.deadline(after: ticks.send)) else { return .preempted }
            do {
                try await transport.sendFile(length == region.length ? region
                                             : FileRegion(file: region.file, offset: offset, length: length))
            } catch {
                return ending(connection.handle(.sendFailed))
            }
            offset += length
            remaining -= length
        } while remaining > 0
        guard watchdog.enter(.none) else { return .preempted }
        return nil
    }

    /// Sends the head, then runs a `.stream` writer; every write is one send. Returns an ending
    /// when the body could not be completed (the connection is aborted).
    mutating func sendStream(_ body: @Sendable (any HTTPBodyWriter) async throws -> Void,
                             framing: HTTP1ResponseBodyWriter<Transport>.Framing) async -> HTTP1Ending? {
        // The head goes out at once, so a slow first write does not hold it back.
        if let ending = await flush(endOfStream: false) { return ending }
        let writer: HTTP1ResponseBodyWriter<Transport>
        if let existing = bodyWriter {
            writer = existing
        } else {
            writer = HTTP1ResponseBodyWriter(transport: transport)
            writer.watch(watchdog, sendTicks: ticks.send)
            bodyWriter = writer
        }
        var failed = false
        do {
            try await body(writer.begin(framing))
        } catch {
            failed = true
        }
        writer.end()
        if writer.transportFailed { return ending(connection.handle(.sendFailed)) }
        if failed || !writer.lengthMatches { return ending(connection.handle(.responseBodyFailed)) }
        if framing == .chunked { HTTP1ChunkedEncoder.appendLastChunk(into: &output) }
        return nil
    }

    // MARK: Actions

    /// The ending for a terminal action that needs no I/O (a failed transport).
    func ending(_ action: HTTP1Connection.Action) -> HTTP1Ending {
        if case .close(let reason) = action { return .closed(reason) }
        assertionFailure("HTTP1ConnectionDriver: \(action) needs output")
        return .closed(.protocolError)
    }

    /// Performs an action that ends the connection: writes the error response if there is one,
    /// flushes everything buffered (half-closing the output), and returns the ending.
    mutating func perform(_ action: HTTP1Connection.Action) async -> HTTP1Ending {
        var action = action
        if case .writeError(let status, let context) = action {
            serializer.write(HTTPResponse(status: status), into: &output, context: context)
            action = connection.handle(.responseWritten)
        }
        guard case .close(let reason) = action else {
            assertionFailure("HTTP1ConnectionDriver: unexpected \(action)")
            return .closed(.protocolError)
        }
        if reason.isAbortive { return .closed(reason) }
        if let ending = await flush(endOfStream: true, resetPhase: false) { return ending }
        return .closed(reason)
    }

    /// Sends ``output`` under the send limit and clears it. Returns an ending if the send
    /// failed or the supervisor took over. With `resetPhase`, the phase goes back to `none`
    /// (more work follows: a handler, another request); without, the caller sets the next.
    mutating func flush(endOfStream: Bool, resetPhase: Bool = true) async -> HTTP1Ending? {
        if ticks.send != 0 && output.readableBytes > Self.sendSlice {
            if let ending = await sendLeadingSlices() { return ending }
        }
        guard watchdog.enter(.send, deadline: watchdog.deadline(after: ticks.send)) else {
            output.clear()
            return .preempted
        }
        do {
            try await transport.send(output, endOfStream: endOfStream)
        } catch {
            output.clear()
            return ending(connection.handle(.sendFailed))
        }
        output.clear()
        if endOfStream { outputShut = true }
        if resetPhase {
            guard watchdog.enter(.none) else { return .preempted }
        }
        return nil
    }

    /// Sends all but the last ``sendSlice`` bytes of a large output (a big `.bytes` body) in
    /// slices, each under its own send limit, so the limit bounds a stalled client rather than
    /// a slow download. Copies each slice; only outputs over a slice take this path.
    mutating func sendLeadingSlices() async -> HTTP1Ending? {
        var slice = ByteBuffer(capacity: Self.sendSlice)
        while output.readableBytes > Self.sendSlice {
            slice.clear()
            slice.append(ByteView(offset: output.readerIndex, length: Self.sendSlice), from: output)
            guard watchdog.enter(.send, deadline: watchdog.deadline(after: ticks.send)) else {
                output.clear()
                return .preempted
            }
            do {
                try await transport.send(slice, endOfStream: false)
            } catch {
                output.clear()
                return ending(connection.handle(.sendFailed))
            }
            output.moveReaderIndex(forwardBy: Self.sendSlice)
        }
        return nil
    }

    /// Lingering close: half-closes the output (if not yet), then reads and discards input
    /// until the client closes, ``HTTP1Configuration/maxLingerSize`` bytes, or the linger
    /// limit (enforced by the supervisor's timer).
    mutating func linger() async {
        guard ticks.linger != 0,
              watchdog.enter(.linger, deadline: watchdog.deadline(after: ticks.linger)) else { return }
        if !outputShut {
            do {
                try await transport.send(ByteBuffer(), endOfStream: true)
            } catch {
                return
            }
            outputShut = true
        }
        await discardInput()
    }

    /// Reads and discards input until end of stream, an error (or cancellation), or
    /// ``HTTP1Configuration/maxLingerSize`` bytes.
    mutating func discardInput() async {
        var discarded = 0
        while discarded <= configuration.maxLingerSize {
            storage.buffer.clear()
            guard let count = try? await transport.receive(into: &storage.buffer, maxLength: configuration.receiveSize),
                  count > 0 else { break }
            discarded &+= count
        }
        storage.buffer.clear()
    }

    /// Hands the byte stream to a tunnel closure, first replaying bytes the client sent after
    /// the request (an HTTP/2 preface after `Upgrade: h2c`, say).
    func startTunnel(_ body: @Sendable (any ByteStreamTransport) async -> Void) async {
        if storage.buffer.isEmpty {
            await body(transport)
        } else {
            var leftover = ByteBuffer(capacity: storage.buffer.readableBytes)
            leftover.append(storage.buffer)
            await body(HTTP1ReplayTransport(base: transport, prefix: leftover))
        }
    }

    // MARK: Buffer

    /// Reclaims consumed bytes before the next receive (legacy #0007). With no head in
    /// progress this is free when everything was consumed. With part of a head buffered after
    /// earlier requests, the parser restarts on the moved bytes (a rescan of at most one head).
    mutating func compactReceiveBuffer() {
        if !parser.isInProgress {
            storage.buffer.discardReadBytes()
        } else if storage.buffer.readerIndex > 0 && storage.buffer.readableBytes <= storage.buffer.readerIndex {
            parser.reset()
            storage.buffer.discardReadBytes()
        }
    }
}

/// A transport that first returns `prefix`, then reads from `base` (for tunnels started with
/// bytes already buffered).
final class HTTP1ReplayTransport<Base: ByteStreamTransport>: ByteStreamTransport {
    let base: Base
    private let prefix: Mutex<ByteBuffer>

    init(base: Base, prefix: ByteBuffer) {
        self.base = base
        self.prefix = Mutex(prefix)
    }

    var info: ConnectionInfo { base.info }

    func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        precondition(maxLength > 0, "maxLength must be positive")
        let replayed = prefix.withLock { prefix -> Int in
            guard !prefix.isEmpty else { return 0 }
            let count = min(maxLength, prefix.readableBytes)
            buffer.append(ByteView(offset: prefix.readerIndex, length: count), from: prefix)
            prefix.moveReaderIndex(forwardBy: count)
            return count
        }
        if replayed > 0 { return replayed }
        return try await base.receive(into: &buffer, maxLength: maxLength)
    }

    func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws {
        try await base.send(bytes, endOfStream: endOfStream)
    }

    func sendFile(_ region: FileRegion) async throws {
        try await base.sendFile(region)
    }

    func close(_ reason: CloseReason) async {
        await base.close(reason)
    }
}
