public import HTTPCore
import Synchronization

/// Reads HTTP/1.1 request bodies (`Content-Length` and chunked) off a connection's receive
/// path, on demand: the ``HTTPRequestBodySource`` behind ``HTTPRequestBody`` for ``HTTP1``.
///
/// One reader belongs to one connection and is reused for every request with a body. It
/// borrows the connection's transport and receive buffer while the handler runs (the runner
/// is suspended in the handler then, so nothing else touches them):
///
/// - Body bytes that arrived with the head are taken from the receive buffer first.
/// - Then each ``nextChunk(request:)`` performs one `receive`. A `Content-Length` body receives
///   at most the bytes still owed, so it never reads into the next request. A chunked body
///   receives into its own buffer and puts the bytes after the last chunk back into the
///   receive buffer when the request ends (``end()``).
/// - Chunks are handed out in one reused buffer of at most `receiveSize` bytes (a chunk the
///   handler keeps is copied on the next write by copy-on-write). No task, no queue: memory
///   stays bounded by one receive whatever the body size.
///
/// `Expect: 100-continue`: `100 Continue` is sent on the first read that has to receive, which
/// is when the handler starts reading the body.
///
/// The state is mutated only by whoever holds ``isBusy`` (a reading handler) or by the runner
/// between handler calls, hence `@unchecked Sendable`.
public final class HTTP1RequestBodyReader<Transport: ByteStreamTransport>: HTTPRequestBodySource, @unchecked Sendable {
    /// How a drain ended.
    public enum DrainResult: Sendable, Hashable {
        /// The body was read to its end; the connection can continue.
        case complete
        /// The drain limit was reached or the body failed; the connection must close.
        case incomplete
        /// The transport failed.
        case transportFailed
    }

    enum Mode {
        /// `remaining` bytes of a `Content-Length` body are unread.
        case contentLength(remaining: Int)
        case chunked
        /// The body was read to its end.
        case finished
        case failed(HTTPRequestBodyError)
    }

    static var continueResponse: StaticString { "HTTP/1.1 100 Continue\r\n\r\n" }

    let transport: Transport
    let storage: HTTPRequestStorage
    let receiveSize: Int
    let maxBodySize: Int

    /// Set while a read or drain is in progress.
    let busy = Atomic<Bool>(false)

    var requestID: UInt64 = 0
    var active = false
    var mode = Mode.finished
    var decoder: ChunkedDecoder
    /// Decoded bytes of the current body.
    var bodyBytes = 0
    var continuePending = false
    var transportError: (any Error)?
    /// The chunk handed to the handler.
    var chunk = ByteBuffer()
    /// Raw chunked bytes received after the receive buffer ran out.
    var raw = ByteBuffer()
    var trailerSection = ByteBuffer()
    var trailerFields: HTTPFields?
    /// The connection's watchdog (#0082): each receive runs under the body limit, the
    /// `100 Continue` send under the send limit. `nil` when used without a supervisor.
    var watchdog: HTTP1Watchdog?
    var bodyTicks: UInt64 = 0
    var sendTicks: UInt64 = 0

    public init(transport: Transport, storage: HTTPRequestStorage, receiveSize: Int,
                maxBodySize: Int, chunkedLimits: ChunkedDecoderLimits) {
        self.transport = transport
        self.storage = storage
        self.receiveSize = receiveSize
        self.maxBodySize = maxBodySize
        decoder = ChunkedDecoder(limits: chunkedLimits)
    }

    // MARK: Runner side

    /// Puts body receives and the `100 Continue` send under the connection's limits.
    func watch(_ watchdog: HTTP1Watchdog, bodyTicks: UInt64, sendTicks: UInt64) {
        self.watchdog = watchdog
        self.bodyTicks = bodyTicks
        self.sendTicks = sendTicks
    }

    /// Starts the body of the request whose head was just parsed from the storage's buffer
    /// and returns the body to hand to the handler.
    public func begin(framing: HTTP1RequestFraming, expectsContinue: Bool) -> HTTPRequestBody {
        requestID &+= 1
        active = true
        bodyBytes = 0
        transportError = nil
        trailerFields = nil
        trailerSection.clear()
        continuePending = expectsContinue
        let length: Int?
        switch framing {
        case .none:
            mode = .finished
            length = 0
        case .contentLength(let declared):
            // The connection rejected lengths above maxBodySize before the handler ran.
            let value = Int(clamping: declared)
            mode = value == 0 ? .finished : .contentLength(remaining: value)
            length = value
        case .chunked:
            decoder.reset()
            mode = .chunked
            length = nil
        }
        return HTTPRequestBody(source: self, request: requestID, length: length)
    }

    /// True when the body was read to its end.
    public var isFinished: Bool {
        if case .finished = mode { return true }
        return false
    }

    /// The body failure that made the handler throw, if any.
    public var failure: HTTPRequestBodyError? {
        if case .failed(let error) = mode { return error }
        return nil
    }

    /// True when a receive failed while reading the body: the connection must abort.
    public var transportFailed: Bool { transportError != nil }

    /// True while a handler's read is still running (a body iterated from an escaped task).
    public var isReading: Bool { busy.load(ordering: .acquiring) }

    /// Whether the unread rest of the body can be skipped by reading at most `limit` more
    /// decoded bytes. Not when it failed, when the client was never asked to send it
    /// (`100-continue` not sent), or when a `Content-Length` body has more than `limit` left.
    public func canDrain(limit: Int) -> Bool {
        if continuePending || transportFailed || isReading { return false }
        switch mode {
        case .finished: return true
        case .failed: return false
        case .contentLength(let remaining): return remaining <= limit
        case .chunked: return true
        }
    }

    /// Reads and discards the rest of the body, up to `limit` decoded bytes.
    public func drain(limit: Int) async -> DrainResult {
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else {
            return .incomplete
        }
        defer { busy.store(false, ordering: .releasing) }
        var drained = 0
        while true {
            do {
                guard let next = try await read() else { return .complete }
                drained &+= next.readableBytes
                if drained > limit { return .incomplete }
            } catch {
                return transportFailed ? .transportFailed : .incomplete
            }
        }
    }

    /// Ends the current request: its body expires, and bytes received past a chunked body go
    /// back to the receive buffer for the next head. Call after the storage's `endRequest()`.
    public func end() {
        active = false
        chunk.clear()
        if !raw.isEmpty {
            // The receive buffer was read to its end before `raw` was filled, and the request
            // has ended, so its consumed bytes can be dropped before appending.
            assert(storage.buffer.isEmpty, "HTTP1RequestBodyReader: bytes left in both buffers")
            storage.buffer.discardReadBytes()
            storage.buffer.append(raw)
            raw.clear()
        }
    }

    // MARK: HTTPRequestBodySource

    public func nextChunk(request: UInt64) async throws -> ByteBuffer? {
        guard request == requestID && active else { throw HTTPRequestBodyError.expired }
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else {
            throw HTTPRequestBodyError.concurrentRead
        }
        defer { busy.store(false, ordering: .releasing) }
        return try await read()
    }

    public func trailers(request: UInt64) -> HTTPFields? {
        guard request == requestID else { return nil }
        return trailerFields
    }

    // MARK: Reading

    /// The next chunk of the body, or `nil` at its end. Caller holds ``busy``.
    func read() async throws -> ByteBuffer? {
        switch mode {
        case .finished:
            return nil
        case .failed(let error):
            throw error
        case .contentLength(let remaining):
            return try await readContentLength(remaining: remaining)
        case .chunked:
            return try await readChunked()
        }
    }

    func readContentLength(remaining: Int) async throws -> ByteBuffer {
        chunk.clear()
        let buffered = storage.buffer.readableBytes
        if buffered > 0 {
            let count = min(remaining, buffered)
            chunk.append(ByteView(offset: storage.buffer.readerIndex, length: count), from: storage.buffer)
            storage.buffer.moveReaderIndex(forwardBy: count)
            // The client is already sending: it is not waiting for 100 (Continue).
            continuePending = false
            setRemaining(remaining &- count)
            return chunk
        }
        try await sendContinueIfPending()
        let count = try await receive(into: &chunk, maxLength: min(remaining, receiveSize))
        setRemaining(remaining &- count)
        return chunk
    }

    func setRemaining(_ remaining: Int) {
        mode = remaining == 0 ? .finished : .contentLength(remaining: remaining)
    }

    func readChunked() async throws -> ByteBuffer? {
        chunk.clear()
        while true {
            // Decode what is buffered: the receive buffer first, then our own.
            let fromStorage = !storage.buffer.isEmpty
            if fromStorage || !raw.isEmpty {
                continuePending = false
                let step = fromStorage ? decodeStep(&storage.buffer) : decodeStep(&raw)
                switch step {
                case .data, .needMoreBytes:
                    if bodyBytes > maxBodySize { return try fail(.tooLarge) }
                    if chunk.readableBytes >= receiveSize { return chunk }
                    continue
                case .end:
                    trailerFields = trailerSection.isEmpty ? nil : ChunkedDecoder.parseTrailers(trailerSection)
                    mode = .finished
                    return chunk.isEmpty ? nil : chunk
                case .error:
                    return try fail(.malformed)
                }
            }
            // Nothing buffered: hand out what was decoded, or receive more.
            if !chunk.isEmpty { return chunk }
            try await sendContinueIfPending()
            raw.clear()
            _ = try await receive(into: &raw, maxLength: receiveSize)
        }
    }

    enum StepKind { case data, needMoreBytes, end, error }

    /// Decodes one step from the readable bytes of `buffer`, appending data to ``chunk`` and
    /// trailer bytes to ``trailerSection``, and consumes it.
    func decodeStep(_ buffer: inout ByteBuffer) -> StepKind {
        let step = buffer.withReadableSpan { decoder.decode($0) }
        let base = buffer.readerIndex
        let payload = ByteView(offset: base &+ step.range.lowerBound, length: step.range.count)
        let kind: StepKind
        switch step.kind {
        case .data:
            bodyBytes &+= payload.length
            chunk.append(payload, from: buffer)
            kind = .data
        case .needMoreBytes:
            if payload.length > 0 { trailerSection.append(payload, from: buffer) }
            kind = .needMoreBytes
        case .end:
            if payload.length > 0 { trailerSection.append(payload, from: buffer) }
            kind = .end
        case .error:
            kind = .error
        }
        buffer.moveReaderIndex(forwardBy: step.consumed)
        return kind
    }

    func fail(_ error: HTTPRequestBodyError) throws -> ByteBuffer? {
        mode = .failed(error)
        throw error
    }

    /// Receives at least one byte; end of stream fails the body as truncated.
    func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        if let watchdog, !watchdog.enter(.body, deadline: watchdog.deadline(after: bodyTicks)) {
            throw preempted()
        }
        let count: Int
        do {
            count = try await transport.receive(into: &buffer, maxLength: maxLength)
        } catch {
            transportError = error
            mode = .failed(.truncated)
            throw error
        }
        // The handler's own time is not limited.
        if let watchdog, !watchdog.enter(.none) { throw preempted() }
        if count == 0 {
            mode = .failed(.truncated)
            throw HTTPRequestBodyError.truncated
        }
        return count
    }

    /// Sends `100 Continue` once, the first time the body has to be received.
    func sendContinueIfPending() async throws {
        guard continuePending else { return }
        continuePending = false
        if let watchdog, !watchdog.enter(.send, deadline: watchdog.deadline(after: sendTicks)) {
            throw preempted()
        }
        do {
            try await transport.send(ByteBuffer(Self.continueResponse), endOfStream: false)
        } catch {
            transportError = error
            mode = .failed(.truncated)
            throw error
        }
        if let watchdog, !watchdog.enter(.none) { throw preempted() }
    }

    /// The supervisor took over (a body timeout): the body fails like a broken transport, so
    /// the runner stops without answering.
    func preempted() -> TransportError {
        transportError = TransportError.timedOut
        mode = .failed(.truncated)
        return .timedOut
    }
}
