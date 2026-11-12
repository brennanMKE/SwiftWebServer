public import HTTPCore
import QPACK

/// Reads one request stream: receives bytes, parses frames with ``H3FrameParser``, applies
/// ``H3RequestStream`` and decodes HEADERS. The runner first reads up to the request head,
/// then keeps calling ``next(from:)`` in the stream's body pump.
///
/// All state is local to the stream's task, except with a QPACK dynamic table (#0106): then
/// field sections are decoded through the connection's ``H3QPACKDecoderContext``, and a
/// section that needs inserts not yet received waits for them (a blocked stream).
struct H3RequestReader {
    enum Event {
        /// The request head decoded and validated.
        case head(HTTPRequest)
        /// A head that cannot be served (malformed, too large, or undecodable).
        case headError(H3HeadError)
        /// A piece of DATA payload.
        case data(ByteBuffer)
        /// FIN after a complete request.
        case end
        /// A stream error: reset the stream with this code.
        case streamError(HTTP3Error)
        /// A connection error with this code.
        case connectionError(UInt64)
        /// The peer reset the stream.
        case peerReset
        /// The stream failed (connection closed) or the task was cancelled.
        case failed
    }

    let storage: HTTPRequestStorage
    let receiveSize: Int
    /// We advertised `SETTINGS_ENABLE_CONNECT_PROTOCOL`, so `:protocol` is allowed.
    let allowsExtendedConnect: Bool
    var parser: H3FrameParser
    var machine = H3RequestStream()
    var decoder: QPACKDecoder
    var buffer: ByteBuffer
    /// A HEADERS payload copied out of the parser's input, so it outlives the parse call.
    var section: [UInt8] = []
    /// The request's trailers, once its trailing HEADERS frame decoded.
    var trailers: HTTPFields?
    /// Called with the number of reserved or unknown frames skipped since the last call;
    /// returns `false` when that is too many for the connection (`H3_EXCESSIVE_LOAD`, #0104).
    let skippedFrames: (@Sendable (Int) -> Bool)?
    var reportedSkippedFrames = 0
    /// The request stream's ID, for QPACK Section Acknowledgments and Stream Cancellations.
    let streamID: UInt64
    /// The connection's dynamic table state; `nil` for static-table-only QPACK.
    let qpack: H3QPACKDecoderContext?
    /// Sends queued QPACK decoder stream instructions (with ``qpack``).
    let flushDecoderStream: (@Sendable () async -> Void)?
    /// The Required Insert Count of the HEADERS frame being decoded (with ``qpack``).
    var requiredInsertCount: UInt64 = 0
    /// Called for each section decoded that referenced the dynamic table (debug counter).
    var dynamicSectionDecoded: (@Sendable () -> Void)?

    init(
        configuration: H3Configuration, storage: HTTPRequestStorage, streamID: UInt64 = 0,
        qpack: H3QPACKDecoderContext? = nil, flushDecoderStream: (@Sendable () async -> Void)? = nil,
        skippedFrames: (@Sendable (Int) -> Bool)? = nil
    ) {
        self.storage = storage
        self.streamID = streamID
        self.qpack = qpack
        self.flushDecoderStream = flushDecoderStream
        self.receiveSize = configuration.receiveSize
        self.allowsExtendedConnect = configuration.enableConnectProtocol
        self.skippedFrames = skippedFrames
        parser = H3FrameParser(configuration: .init(
            streamKind: .request, role: .server,
            maxFieldSectionLength: configuration.maxEncodedFieldSectionLength,
            maxUnknownFrameLength: configuration.abuseLimits.maxUnknownFrameLength))
        decoder = QPACKDecoder(maxFieldSectionSize: configuration.maxFieldSectionSize)
        buffer = ByteBuffer(capacity: configuration.receiveSize)
    }

    /// The parse step's result, copied out of the closure that sees the input bytes.
    enum Step {
        case needsMoreData
        case dataHeader(UInt64)
        case data(ByteBuffer)
        case headers
    }

    /// Returns the next reportable event, receiving from `stream` as needed.
    mutating func next<S: ByteStreamTransport>(from stream: S) async -> Event {
        while true {
            while buffer.readableBytes > 0 {
                let step: Step
                do throws(HTTP3Error) {
                    step = try parseOne()
                } catch {
                    machine.markFailed()
                    return .connectionError(error.rawValue)
                }
                if parser.skippedFrameCount != reportedSkippedFrames {
                    let skipped = parser.skippedFrameCount - reportedSkippedFrames
                    reportedSkippedFrames = parser.skippedFrameCount
                    if let skippedFrames, !skippedFrames(skipped) {
                        machine.markFailed()
                        return .connectionError(HTTP3Error.excessiveLoad.rawValue)
                    }
                }
                switch step {
                case .needsMoreData:
                    break
                case .dataHeader(let length):
                    switch machine.handle(.dataFrame(length: length)) {
                    case .deliverData: continue
                    case let action: return failure(action)
                    }
                case .data(let chunk):
                    return .data(chunk)
                case .headers:
                    switch machine.handle(.headers) {
                    case .decodeRequestHead:
                        if qpack != nil, let event = await admitSection() { return event }
                        let event = decodeHead()
                        if qpack != nil, let failure = await acknowledgeSection() { return failure }
                        return event
                    case .decodeTrailers:
                        if qpack != nil, let event = await admitSection() { return event }
                        do throws(H3HeadError) {
                            trailers = try decodeTrailers()
                        } catch {
                            cancelUnacknowledgedSection(error)
                            await flushDecoderStream?()
                            machine.markFailed()
                            if case .qpack(let qpack) = error { return .connectionError(qpack.code.rawValue) }
                            return .streamError(.messageError)
                        }
                        if qpack != nil, let failure = await acknowledgeSection() { return failure }
                        continue
                    case let action:
                        return failure(action)
                    }
                }
            }
            buffer.clear()
            let received: Int
            do {
                received = try await stream.receive(into: &buffer, maxLength: receiveSize)
            } catch TransportError.connectionReset {
                machine.markFailed()
                return .peerReset
            } catch {
                machine.markFailed()
                return .failed
            }
            if received == 0 {
                guard parser.isAtFrameBoundary else {
                    machine.markFailed()
                    return .connectionError(HTTP3Error.frameError.rawValue)
                }
                switch machine.handle(.endOfStream) {
                case .finishBody: return .end
                case let action: return failure(action)
                }
            }
        }
    }

    /// Parses one event from the readable bytes and advances past what it used.
    mutating func parseOne() throws(HTTP3Error) -> Step {
        // A second reference to the storage (no copy), so the closure can mutate `self`.
        let bytes = buffer
        var section = self.section
        self.section = []
        defer { self.section = section }
        let (step, consumed) = try bytes.withUnsafeReadableBytes { (input) throws(HTTP3Error) -> (Step, Int) in
            let output = try parser.parse(input)
            let step: Step
            switch output.event {
            case .needsMoreData:
                step = .needsMoreData
            case .dataHeader(let length):
                step = .dataHeader(length)
            case .data(let range):
                var chunk = ByteBuffer(capacity: range.count)
                _ = chunk.appendRaw(UnsafeRawBufferPointer(rebasing: input[range]))
                step = .data(chunk)
            case .headers(let location):
                section.removeAll(keepingCapacity: true)
                parser.withPayload(location, in: input) { section.append(contentsOf: $0) }
                step = .headers
            case .pushPromise, .settings, .cancelPush, .goaway, .maxPushID, .priorityUpdate:
                // The request-stream parser rejects these before reporting them.
                throw .frameUnexpected
            }
            return (step, output.consumed)
        }
        buffer.moveReaderIndex(forwardBy: consumed)
        return step
    }

    // MARK: QPACK dynamic table (#0106)

    /// Reads the HEADERS frame's Required Insert Count and, when its inserts have not arrived,
    /// waits for them. Returns the event to report instead of decoding, if any.
    mutating func admitSection() async -> Event? {
        guard let qpack else { return nil }
        let result: Result<QPACKDynamicDecoder.Admission, QPACKError> = section.withUnsafeBytes { bytes in
            do throws(QPACKError) {
                return .success(try qpack.admit(bytes))
            } catch {
                return .failure(error)
            }
        }
        let admission: QPACKDynamicDecoder.Admission
        switch result {
        case .success(let value):
            admission = value
        case .failure(let error):
            machine.markFailed()
            return .connectionError(error.code.rawValue)
        }
        switch admission {
        case .ready(let count):
            requiredInsertCount = count
            return nil
        case .blocked(let count):
            requiredInsertCount = count
            guard await qpack.waitForInserts(count) else {
                // Cancelled (the stream timed out, or the connection is closing): tell the
                // peer's encoder it need not keep this section's entries (RFC 9204 §4.4.2).
                // The runner sends it once this stream's tasks have ended.
                qpack.cancelStream(streamID)
                machine.markFailed()
                return .failed
            }
            return nil
        }
    }

    /// Sends the Section Acknowledgment a dynamic section queued. Returns a connection error
    /// when the peer does not read our decoder stream and its backlog grew too large.
    func acknowledgeSection() async -> Event? {
        guard let qpack, requiredInsertCount > 0 else { return nil }
        dynamicSectionDecoded?()
        if qpack.isDecoderStreamBacklogged { return .connectionError(HTTP3Error.excessiveLoad.rawValue) }
        await flushDecoderStream?()
        return nil
    }

    /// A dynamic section that failed to decode as a stream error (malformed or too large) was
    /// not acknowledged: cancel the stream so the encoder can release its entries. A QPACK
    /// error closes the connection, so there is nobody to tell.
    func cancelUnacknowledgedSection(_ error: H3HeadError) {
        guard let qpack, requiredInsertCount > 0, error.isStreamError else { return }
        qpack.cancelStream(streamID)
    }

    mutating func decodeTrailers() throws(H3HeadError) -> HTTPFields {
        let section = self.section
        if let qpack {
            var dynamic = H3DynamicSectionDecoder(context: qpack, streamID: streamID, requiredInsertCount: requiredInsertCount)
            return try Self.withSection(section, decoder: &dynamic) { (bytes, decoder) throws(H3HeadError) in
                try H3RequestHeadDecoder.decodeTrailers(bytes, decoder: &decoder)
            }
        }
        return try Self.withSection(section, decoder: &decoder) { (bytes, decoder) throws(H3HeadError) in
            try H3RequestHeadDecoder.decodeTrailers(bytes, decoder: &decoder)
        }
    }

    mutating func decodeRequest() throws(H3HeadError) -> HTTPRequest {
        let storage = self.storage
        let allowsExtendedConnect = self.allowsExtendedConnect
        let section = self.section
        if let qpack {
            var dynamic = H3DynamicSectionDecoder(context: qpack, streamID: streamID, requiredInsertCount: requiredInsertCount)
            return try Self.withSection(section, decoder: &dynamic) { (bytes, decoder) throws(H3HeadError) in
                try H3RequestHeadDecoder.decode(bytes, decoder: &decoder, storage: storage,
                                                allowsExtendedConnect: allowsExtendedConnect)
            }
        }
        return try Self.withSection(section, decoder: &decoder) { (bytes, decoder) throws(H3HeadError) in
            try H3RequestHeadDecoder.decode(bytes, decoder: &decoder, storage: storage,
                                            allowsExtendedConnect: allowsExtendedConnect)
        }
    }

    mutating func decodeHead() -> Event {
        do throws(H3HeadError) {
            let request = try decodeRequest()
            let contentLength: UInt64?
            switch request.headers.contentLength() {
            case .absent: contentLength = nil
            case .value(let value): contentLength = value
            case .invalid, .conflicting:
                machine.markFailed()
                return .headError(.malformed(.invalidFieldValue))
            }
            _ = machine.handle(.requestHead(contentLength: contentLength))
            return .head(request)
        } catch {
            cancelUnacknowledgedSection(error)
            if error == .fieldSectionTooLarge {
                // Answered `431`: the stream stays readable so the body can be drained.
                _ = machine.handle(.requestHead(contentLength: nil))
            } else {
                machine.markFailed()
            }
            return .headError(error)
        }
    }

    /// Calls `body` with the copied HEADERS payload and the QPACK decoder.
    static func withSection<Decoder: QPACKSectionDecoder, R>(
        _ section: [UInt8], decoder: inout Decoder,
        _ body: (UnsafeRawBufferPointer, inout Decoder) throws(H3HeadError) -> R
    ) throws(H3HeadError) -> R {
        let result: Result<R, H3HeadError> = section.withUnsafeBytes { bytes in
            do throws(H3HeadError) {
                return .success(try body(bytes, &decoder))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    func failure(_ action: H3RequestStream.Action) -> Event {
        switch action {
        case .streamError(let error): .streamError(error)
        case .connectionError(let error): .connectionError(error.rawValue)
        default: .failed
        }
    }
}
