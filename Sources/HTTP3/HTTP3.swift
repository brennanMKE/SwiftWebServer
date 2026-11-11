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
/// - one child task opens our control stream (SETTINGS) and QPACK encoder and decoder streams;
/// - one child task per peer stream: unidirectional streams are classified and read
///   (control frames, QPACK instructions) or ignored; each bidirectional stream is one request
///   (``H3RequestStream``) whose handler runs as a child of that stream's task, next to a
///   body reader that feeds the request's `HTTPRequestBody` (``H3BodyChannel``);
/// - connection-level decisions go through ``H3Connection`` in a `Mutex`, with no suspension
///   inside the lock. Request streams share no other state (static-table QPACK).
///
/// ## Errors
///
/// - A connection error (``H3Connection/Action/closeConnection(code:)``) closes the QUIC
///   connection with its code, which ends every stream and cancels running handlers.
/// - A malformed request is reset with `H3_MESSAGE_ERROR`; a request stream ending before its
///   head with `H3_REQUEST_INCOMPLETE`.
/// - A peer reset of a request stream cancels its handler.
/// - A handler that throws before anything was sent gets `500`; once the head is out (a
///   `.stream` body failing), the stream is reset with `H3_INTERNAL_ERROR`.
///
/// ## Not yet
///
/// GOAWAY and graceful drain (#0102: draining currently closes with `H3_NO_ERROR`), trailers in
/// responses, `.tunnel` / extended CONNECT (#0111; answered `501`), and limits on concurrent
/// requests beyond QUIC's MAX_STREAMS (#0104).
public struct HTTP3: MultiplexedConnectionProtocol {
    public var configuration: H3Configuration

    public init(configuration: H3Configuration = H3Configuration()) {
        self.configuration = configuration
    }

    public static var alpnTokens: [String] { ["h3"] }

    public func run<T: MultiplexedTransport, H: HTTPHandler>(
        _ t: T, handler: H, context: ConnectionContext
    ) async where T.Stream: ResettableStream {
        let driver = H3ConnectionDriver(transport: t, handler: handler, context: context, configuration: configuration)
        await driver.run()
    }
}

/// Runs one HTTP/3 connection (see ``HTTP3``).
final class H3ConnectionDriver<Transport: MultiplexedTransport, Handler: HTTPHandler>: Sendable
where Transport.Stream: ResettableStream {
    typealias Stream = Transport.Stream

    let transport: Transport
    let handler: Handler
    let context: ConnectionContext
    let configuration: H3Configuration
    let state: Mutex<H3Connection>
    /// Our control and QPACK streams. Kept until the connection ends: releasing a QUIC stream
    /// cancels it, and the peer treats a closed critical stream as a connection error.
    let localStreams = Mutex<[Stream]>([])

    init(transport: Transport, handler: Handler, context: ConnectionContext, configuration: H3Configuration) {
        self.transport = transport
        self.handler = handler
        self.context = context
        self.configuration = configuration
        state = Mutex(H3Connection(configuration: configuration))
    }

    func run() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.openLocalStreams() }
            group.addTask { await self.closeOnShutdown() }
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
        let code = state.withLock { $0.closeCode } ?? HTTP3Error.noError.rawValue
        await transport.close(applicationError: code)
        localStreams.withLock { $0.removeAll() }
    }

    /// Applies `event` to the connection state; closes the connection if it says so.
    @discardableResult
    func handle(_ event: H3Connection.Event) async -> H3Connection.Action {
        let action = state.withLock { $0.handle(event) }
        if case .closeConnection(let code) = action {
            await transport.close(applicationError: code)
        }
        return action
    }

    var isClosing: Bool { state.withLock { $0.isClosing } }

    // MARK: Local streams

    func openLocalStreams() async {
        let prefaces = [
            state.withLock { $0.controlStreamPreface() },
            H3Connection.qpackEncoderStreamPreface,
            H3Connection.qpackDecoderStreamPreface,
        ]
        do {
            for preface in prefaces {
                let stream = try await transport.openUnidirectionalStream()
                localStreams.withLock { $0.append(stream) }
                try await stream.send(ByteBuffer(bytes: preface), endOfStream: false)
            }
        } catch {
            // The connection closed or failed before our streams were open.
            if !isClosing && !Task.isCancelled {
                await handle(.connectionError(code: HTTP3Error.internalError.rawValue))
            }
        }
    }

    /// Draining: until GOAWAY exists (#0102), close the connection with `H3_NO_ERROR`.
    func closeOnShutdown() async {
        await context.shutdown.wait()
        guard context.shutdown.isTriggered, !Task.isCancelled else { return }
        await handle(.connectionError(code: HTTP3Error.noError.rawValue))
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
        case .ignoreStream(let code):
            await stream.stopSending(applicationError: code)
        case .none, .serveRequest, .rejectRequest, .closeConnection:
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
                    await handle(.connectionError(code: error.rawValue))
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
                await handle(.connectionError(code: error.code.rawValue))
                return
            }
            // A partial instruction (a few bytes at most) stays for the next receive.
            _ = buffer.discardReadBytes()
            guard await receiveCritical(stream, into: &buffer, critical: critical) else { return }
        }
    }

    // MARK: Request streams

    func serveRequest(_ stream: Stream) async {
        switch await handle(.requestStream(streamID: stream.streamID)) {
        case .serveRequest:
            break
        case .rejectRequest(let code):
            await abandon(stream, code: code)
            return
        default:
            return
        }

        let storage = HTTPRequestStorage(bufferCapacity: 512, fieldCapacity: 16)
        var reader = H3RequestReader(configuration: configuration, storage: storage)
        switch await reader.next(from: stream) {
        case .head(let request):
            await serve(request, on: stream, reader: reader)
        case .headError(let error):
            switch error {
            case .malformed:
                await abandon(stream, code: HTTP3Error.messageError.rawValue)
            case .fieldSectionTooLarge:
                await serve(nil, on: stream, reader: reader)
            case .qpack(let qpack):
                await handle(.connectionError(code: qpack.code.rawValue))
            }
        case .streamError(let error):
            await abandon(stream, code: error.rawValue)
        case .connectionError(let code):
            await handle(.connectionError(code: code))
        case .data, .end, .peerReset, .failed:
            // DATA before HEADERS is a connection error, and `end` without HEADERS is a stream
            // error, so neither arrives here; a reset or failed stream has nobody to answer.
            return
        }
    }

    /// Resets a stream in both directions with `code`.
    func abandon(_ stream: Stream, code: UInt64) async {
        await stream.reset(applicationError: code)
        await stream.stopSending(applicationError: code)
    }

    enum StreamOutcome: Sendable {
        case bodyRead(H3RequestReader.Event)
        case responded
    }

    /// Runs the handler for `request` (or answers `431` when it is `nil`) next to the body
    /// reader, and handles the first of: peer reset, malformed body, end of both.
    func serve(_ head: HTTPRequest?, on stream: Stream, reader: H3RequestReader) async {
        let channel = H3BodyChannel(capacity: configuration.bodyQueueCapacity, streamID: stream.streamID)
        let length = reader.machine.contentLength.flatMap { Int(exactly: $0) }
        let request = head.map { head -> HTTPRequest in
            var request = head
            request.body = HTTPRequestBody(source: channel, request: channel.streamID, length: length)
            return request
        }
        await withTaskGroup(of: StreamOutcome.self) { group in
            group.addTask {
                var reader = reader
                return .bodyRead(await Self.pumpBody(from: stream, reader: &reader, into: channel))
            }
            group.addTask {
                await self.respond(to: request, storage: reader.storage, on: stream, body: channel)
                return .responded
            }
            for await outcome in group {
                guard case .bodyRead(let end) = outcome else { continue }
                switch end {
                case .end:
                    continue
                case .peerReset, .failed:
                    group.cancelAll()
                case .streamError(let error):
                    group.cancelAll()
                    await abandon(stream, code: error.rawValue)
                case .connectionError(let code):
                    group.cancelAll()
                    await handle(.connectionError(code: code))
                case .head, .headError, .data:
                    continue
                }
            }
        }
        await stream.close(.normal)
    }

    /// Feeds DATA payload to `channel` until FIN or an error, and reports how the body ended.
    /// Suspends (and so stops reading the stream) while the channel is full.
    static func pumpBody(from stream: Stream, reader: inout H3RequestReader, into channel: H3BodyChannel) async -> H3RequestReader.Event {
        while true {
            let event = await reader.next(from: stream)
            switch event {
            case .data(let chunk):
                do {
                    try await channel.queue.send(chunk)
                } catch {
                    // Cancelled: the stream is being torn down.
                    channel.fail(TransportError.closed)
                    return .failed
                }
            case .end:
                channel.finish(trailers: reader.trailers)
                return .end
            case .streamError:
                channel.fail(HTTPRequestBodyError.malformed)
                return event
            case .connectionError(let code):
                channel.fail(code == HTTP3Error.frameError.rawValue ? HTTPRequestBodyError.truncated : HTTPRequestBodyError.malformed)
                return event
            case .peerReset:
                channel.fail(TransportError.connectionReset)
                return event
            case .failed, .head, .headError:
                channel.fail(TransportError.closed)
                return .failed
            }
        }
    }

    /// Calls the handler and writes its response; then discards any body the handler left
    /// unread, so the reader can reach FIN.
    func respond(to request: HTTPRequest?, storage: HTTPRequestStorage, on stream: Stream, body: H3BodyChannel) async {
        var isHead = false
        let response: HTTPResponse
        if let request {
            isHead = request.method == .head
            let requestContext = RequestContext(connection: context.info)
            do {
                response = try await handler.handle(request, context: requestContext)
                storage.endRequest()
                body.expire()
            } catch {
                storage.endRequest()
                body.expire()
                // Cancelled (peer reset), or the body turned out malformed: the stream is
                // reset by `serve`, so nothing is written here.
                guard !Task.isCancelled, !body.failed else { return }
                response = HTTPResponse(status: .internalServerError)
            }
        } else {
            response = HTTPResponse(status: .requestHeaderFieldsTooLarge)
        }
        guard !Task.isCancelled else { return }
        await write(response, isHead: isHead, on: stream)
        // Unread request body: drop it until FIN (bounded: one chunk at a time).
        for await _ in body.queue {}
    }

    /// Writes `response` as HEADERS and DATA frames, then FIN.
    func write(_ response: HTTPResponse, isHead: Bool, on stream: Stream) async {
        let hasContent = !isHead && !response.status.forbidsContent
        var encoder = H3ResponseHeadEncoder()
        var out = ByteBuffer(capacity: 256)
        var headSent = false
        do {
            switch response.body {
            case .empty:
                encoder.encode(status: response.status, headers: response.headers,
                               contentLength: hasContent ? 0 : nil, into: &out)
                try await stream.send(out, endOfStream: true)

            case .bytes(let bytes):
                encoder.encode(status: response.status, headers: response.headers,
                               contentLength: response.status.forbidsContent ? nil : bytes.readableBytes, into: &out)
                if hasContent && bytes.readableBytes > 0 {
                    var sink = ByteBufferSink(buffer: out)
                    try H3FrameEncoder.encodeDataHeader(length: UInt64(bytes.readableBytes), into: &sink)
                    out = sink.buffer
                    out.append(bytes)
                }
                try await stream.send(out, endOfStream: true)

            case .file(let region):
                encoder.encode(status: response.status, headers: response.headers,
                               contentLength: response.status.forbidsContent ? nil : Int(region.length), into: &out)
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

            case .stream(let length, let writer):
                encoder.encode(status: response.status, headers: response.headers,
                               contentLength: response.status.forbidsContent ? nil : length, into: &out)
                headSent = true
                try await stream.send(out, endOfStream: false)
                if hasContent {
                    try await writer(H3DataWriter(stream: stream))
                }
                try await stream.send(ByteBuffer(), endOfStream: true)

            case .tunnel:
                // Extended CONNECT arrives with #0111.
                encoder.encode(status: .notImplemented, headers: HTTPFields(), contentLength: 0, into: &out)
                try await stream.send(out, endOfStream: true)
            }
        } catch {
            // A peer reset or STOP_SENDING, cancellation, or a failing body writer or file.
            if headSent && !Task.isCancelled {
                await stream.reset(applicationError: HTTP3Error.internalError.rawValue)
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
