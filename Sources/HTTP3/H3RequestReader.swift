public import HTTPCore
import QPACK

/// Reads one request stream: receives bytes, parses frames with ``H3FrameParser``, applies
/// ``H3RequestStream`` and decodes HEADERS. The runner first reads up to the request head,
/// then keeps calling ``next(from:)`` in the stream's body pump.
///
/// All state is local to the stream's task; nothing is shared with other streams (static-table
/// QPACK has no connection state).
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
    var parser: H3FrameParser
    var machine = H3RequestStream()
    var decoder: QPACKDecoder
    var buffer: ByteBuffer
    /// A HEADERS payload copied out of the parser's input, so it outlives the parse call.
    var section: [UInt8] = []
    /// The request's trailers, once its trailing HEADERS frame decoded.
    var trailers: HTTPFields?

    init(configuration: H3Configuration, storage: HTTPRequestStorage) {
        self.storage = storage
        self.receiveSize = configuration.receiveSize
        parser = H3FrameParser(configuration: .init(
            streamKind: .request, role: .server,
            maxFieldSectionLength: configuration.maxEncodedFieldSectionLength))
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
                        return decodeHead()
                    case .decodeTrailers:
                        do throws(H3HeadError) {
                            trailers = try withSection { (bytes, decoder) throws(H3HeadError) in
                                try H3RequestHeadDecoder.decodeTrailers(bytes, decoder: &decoder)
                            }
                        } catch {
                            machine.markFailed()
                            if case .qpack(let qpack) = error { return .connectionError(qpack.code.rawValue) }
                            return .streamError(.messageError)
                        }
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
            case .pushPromise, .settings, .cancelPush, .goaway, .maxPushID:
                // The request-stream parser rejects these before reporting them.
                throw .frameUnexpected
            }
            return (step, output.consumed)
        }
        buffer.moveReaderIndex(forwardBy: consumed)
        return step
    }

    mutating func decodeHead() -> Event {
        do throws(H3HeadError) {
            let storage = self.storage
            let request = try withSection { (bytes, decoder) throws(H3HeadError) -> HTTPRequest in
                try H3RequestHeadDecoder.decode(bytes, decoder: &decoder, storage: storage)
            }
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
            machine.markFailed()
            return .headError(error)
        }
    }

    /// Calls `body` with the copied HEADERS payload and the QPACK decoder.
    mutating func withSection<R>(
        _ body: (UnsafeRawBufferPointer, inout QPACKDecoder) throws(H3HeadError) -> R
    ) throws(H3HeadError) -> R {
        let section = self.section
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
