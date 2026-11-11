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

    public static let defaultReceiveSize = 16 * 1024
    public static let defaultFlushThreshold = 64 * 1024
    public static let defaultMaxBodySize = 10 * 1024 * 1024
    public static let defaultMaxDrainSize = 64 * 1024

    public init(
        parserLimits: HTTP1ParserLimits = HTTP1ParserLimits(),
        receiveSize: Int = HTTP1Configuration.defaultReceiveSize,
        flushThreshold: Int = HTTP1Configuration.defaultFlushThreshold,
        maxBodySize: Int = HTTP1Configuration.defaultMaxBodySize,
        maxDrainSize: Int = HTTP1Configuration.defaultMaxDrainSize,
        chunkedLimits: ChunkedDecoderLimits = ChunkedDecoderLimits()
    ) {
        precondition(receiveSize > 0 && flushThreshold > 0, "HTTP1Configuration sizes must be positive")
        precondition(maxBodySize >= 0 && maxDrainSize >= 0, "HTTP1Configuration body limits must not be negative")
        self.parserLimits = parserLimits
        self.receiveSize = receiveSize
        self.flushThreshold = flushThreshold
        self.maxBodySize = maxBodySize
        self.maxDrainSize = maxDrainSize
        self.chunkedLimits = chunkedLimits
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
/// ## Hooks
///
/// - `.tunnel` responses (#0108): the head (`101` from the handler) is flushed, then the byte
///   stream is handed to the closure, replaying any bytes buffered after the request.
/// - Draining (#0082): a connection checks the shutdown signal once per batch and then answers
///   with `connection: close`; a connection idle in `receive` is cancelled at the drain deadline.
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
        var driver = HTTP1ConnectionDriver(transport: t, handler: handler, context: context,
                                           configuration: configuration)
        let ending = await driver.run()
        await t.close(ending.closeReason)
    }
}

/// How a connection ended.
enum HTTP1Ending: Equatable {
    case closed(CloseReason)
    /// The tunnel closure owned the transport; it closes it (and the server closes it again).
    case tunnelled

    var closeReason: CloseReason {
        if case .closed(let reason) = self { return reason }
        return .normal
    }
}

/// The per-connection loop of ``HTTP1``: all connection state as stored properties of one
/// local value, mutated in place (no actor, no allocation per request).
struct HTTP1ConnectionDriver<Transport: ByteStreamTransport, Handler: HTTPHandler> {
    let transport: Transport
    let handler: Handler
    let shutdown: ShutdownSignal
    let requestContext: RequestContext
    let configuration: HTTP1Configuration
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

    init(transport: Transport, handler: Handler, context: ConnectionContext, configuration: HTTP1Configuration) {
        self.transport = transport
        self.handler = handler
        self.shutdown = context.shutdown
        self.requestContext = RequestContext(connection: context.info)
        self.configuration = configuration
        storage = HTTPRequestStorage(bufferCapacity: configuration.receiveSize, fieldCapacity: 32)
        parser = HTTP1Parser(limits: configuration.parserLimits)
        serializer = HTTP1Serializer()
        output = ByteBuffer(capacity: 4 * 1024)
        connection = HTTP1Connection(maxBodySize: configuration.maxBodySize)
    }

    /// Runs the connection; returns how it ended. The caller closes the transport.
    mutating func run() async -> HTTP1Ending {
        while true {
            if shutdown.isTriggered && !connection.isDraining {
                if case .close(let reason) = connection.handle(.shutdown) { return .closed(reason) }
            }
            compactReceiveBuffer()

            // Suspension 1: one receive per batch.
            let received: Int
            do {
                received = try await transport.receive(into: &storage.buffer, maxLength: configuration.receiveSize)
            } catch {
                return ending(connection.handle(.receiveFailed))
            }
            if received == 0 {
                return ending(connection.handle(.endOfStream))
            }

            if let ending = await answerBufferedRequests() { return ending }

            // Suspension 2: one send per pipelined batch.
            if !output.isEmpty {
                if let ending = await flush(endOfStream: false) { return ending }
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
                _ = connection.handle(.needMoreBytes(headStarted: parser.isInProgress))
                return nil

            case .error(let error):
                return await perform(connection.handle(.parseError(error)))

            case .complete:
                let head = parser.head
                let summary = HTTP1Connection.RequestSummary(head: head, fields: storage.fieldsView)
                let action = connection.handle(.head(summary))
                guard case .callHandler = action else {
                    storage.endRequest()
                    return await perform(action)
                }
                var request = head.request(in: storage)
                var reader: HTTP1RequestBodyReader<Transport>?
                if summary.hasBody {
                    let bodyReader = self.bodyReader ?? makeBodyReader()
                    reader = bodyReader
                    var expectsContinue = false
                    if case .handling(let exchange) = connection.state { expectsContinue = exchange.expectsContinue }
                    // `100 Continue` goes straight to the transport: earlier responses first.
                    if expectsContinue && !output.isEmpty {
                        if let ending = await flush(endOfStream: false) {
                            storage.endRequest()
                            return ending
                        }
                    }
                    request.body = bodyReader.begin(framing: head.framing, expectsContinue: expectsContinue)
                }
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
        guard case .drainBody = connection.handle(.bodyUnread(drainable: drainable)) else { return nil }
        switch await reader.drain(limit: configuration.maxDrainSize) {
        case .complete:
            _ = connection.handle(.bodyDrained(complete: true))
        case .incomplete:
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
                if let ending = await flush(endOfStream: false) { return ending }
                do {
                    try await transport.sendFile(region)
                } catch {
                    return ending(connection.handle(.sendFailed))
                }
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
            if let ending = await flush(endOfStream: false) { return ending }
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
        if let ending = await flush(endOfStream: true) { return ending }
        return .closed(reason)
    }

    /// Sends ``output`` and clears it. Returns an ending if the send failed.
    mutating func flush(endOfStream: Bool) async -> HTTP1Ending? {
        do {
            try await transport.send(output, endOfStream: endOfStream)
        } catch {
            output.clear()
            return ending(connection.handle(.sendFailed))
        }
        output.clear()
        return nil
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
