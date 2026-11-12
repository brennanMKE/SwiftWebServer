public import HTTPCore

/// A WebSocket message as the application sees it.
public enum WebSocketMessage: Sendable, Equatable {
    /// A text message, already validated as UTF-8.
    case text(String)
    /// A binary message.
    case binary(ByteBuffer)
}

/// The RFC 6455 connection state machine: frame parsing, message assembly, streaming UTF-8
/// validation, ping/pong and the close handshake. A value type with no I/O; the session in
/// ``WebSocket`` performs the actions it returns.
///
/// ```
///            peer Close / we echo it, then close TCP
///   open ──────────────────────────────────────────────▶ closed
///    │  app close / we send Close                          ▲
///    └──────────────────────▶ closing ─── peer Close ──────┤
///    protocol violation: send Close(code), close TCP ──────┘ (also EOF, timeout)
/// ```
///
/// Two entry points, each returning one ``Action``: ``process(_:)`` consumes received bytes
/// until there is something to do (call it again until it returns ``Action/needMoreBytes``),
/// and ``handle(_:)`` takes local events (an application close, the close timeout, end of
/// stream).
///
/// Message rules, on top of the frame rules of ``WSFrameParser``:
/// - A continuation frame with no message in progress, or a text/binary frame inside a
///   fragmented message, is 1002. Control frames may interleave with fragments.
/// - A message longer than ``Configuration/maxMessageSize`` is 1009, detected from frame
///   headers before the payload is buffered.
/// - Text is validated as it arrives, across fragment boundaries: the first invalid byte is
///   1007, as is a message that ends inside a code point.
/// - A Close payload of one byte or with a code no endpoint may send is 1002; a reason that
///   is not UTF-8 is 1007.
///
/// With permessage-deflate (RFC 7692, #0110) negotiated, RSV1 on the first frame of a data
/// message marks it compressed; RSV1 on a continuation or control frame is 1002. Compressed
/// payload is inflated as it arrives, so the size and UTF-8 checks apply to the inflated
/// bytes: past ``Configuration/maxMessageSize`` is 1009 (decompression bombs stop there),
/// data that does not inflate is 1007.
public struct WSConnection: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Largest payload in one frame (1009 beyond).
        public var maxFrameSize: Int
        /// Largest assembled message (1009 beyond).
        public var maxMessageSize: Int
        /// RSV bits a negotiated extension gives meaning to (none without extensions).
        public var allowedReservedBits: UInt8

        public init(maxFrameSize: Int = 16 * 1024 * 1024, maxMessageSize: Int = 16 * 1024 * 1024,
                    allowedReservedBits: UInt8 = 0) {
            self.maxFrameSize = maxFrameSize
            self.maxMessageSize = maxMessageSize
            self.allowedReservedBits = allowedReservedBits
        }
    }

    public enum State: Sendable, Hashable {
        /// Messages flow both ways.
        case open
        /// We sent a Close frame and wait for the peer's (incoming data is discarded).
        case closing
        /// The close handshake finished, failed, or the stream ended.
        case closed
    }

    /// Local events.
    public enum Event: Sendable, Hashable {
        /// The application closes the connection with `code` and `reason` (≤ 123 UTF-8 bytes).
        case closeRequested(WebSocketCloseCode, reason: String)
        /// The peer did not finish the close handshake in time.
        case closeTimedOut
        /// The peer ended the byte stream.
        case endOfStream
    }

    public enum Action: Sendable, Equatable {
        /// Nothing to do until more bytes arrive.
        case needMoreBytes
        /// Hand a complete message to the application.
        case deliver(WebSocketMessage)
        /// Answer a ping with this payload.
        case sendPong(ByteBuffer)
        /// A pong arrived with this payload (it may answer an application ping).
        case receivedPong(ByteBuffer)
        /// Send a Close frame (`code` `nil` means an empty payload). With
        /// `thenCloseTransport`, this ends the conversation: shut down the sending side and
        /// close the transport once the peer has seen it (server closes TCP first,
        /// RFC 6455 §7.1.1).
        case sendClose(code: WebSocketCloseCode?, reason: String, thenCloseTransport: Bool)
        /// The close handshake is over (or abandoned): close the transport.
        case closeTransport(CloseReason)
        /// Nothing to do.
        case none
    }

    enum Phase: Sendable, Hashable {
        /// Between frames.
        case idle
        /// Payload of a data frame goes to the message buffer.
        case data(fin: Bool)
        /// Payload of a control frame goes to the control buffer.
        case control(WSOpcode)
        /// Payload is read and dropped (data while closing).
        case discard
    }

    public let configuration: Configuration
    var parser: WSFrameParser
    var phase = Phase.idle
    /// The message being assembled and its opcode (`nil` between messages).
    var message = ByteBuffer()
    var messageOpcode: WSOpcode?
    /// The permessage-deflate decompressor, when negotiated.
    let inflater: PerMessageDeflate.Inflater?
    /// The message being assembled is compressed (RSV1 on its first frame).
    var messageCompressed = false
    /// Compressed bytes of the current message so far, and the bound on them.
    var compressedReceived = 0
    var compressed = ByteBuffer()
    /// Compressed messages received (for tests and statistics).
    public private(set) var compressedMessages = 0
    var utf8 = UTF8Validator()
    var control = ByteBuffer(capacity: 125)
    var scratch = ByteBuffer()

    public private(set) var state = State.open
    /// The code in the peer's Close frame (``WebSocketCloseCode/noStatusReceived`` for an
    /// empty one), or ``WebSocketCloseCode/abnormalClosure`` if the stream ended without one.
    public private(set) var receivedCloseCode: WebSocketCloseCode?
    /// The reason in the peer's Close frame.
    public private(set) var receivedCloseReason = ""
    /// The code of the Close frame we sent (`nil` before one is sent, or when we echoed an
    /// empty Close).
    public private(set) var sentCloseCode: WebSocketCloseCode?
    /// Set when the connection failed because the peer violated the protocol.
    public private(set) var failure: WebSocketCloseCode?

    public init(configuration: Configuration = Configuration()) {
        self.init(configuration: configuration, inflater: nil)
    }

    /// A connection with permessage-deflate negotiated (`inflater` decompresses).
    init(configuration: Configuration, inflater: PerMessageDeflate.Inflater?) {
        self.configuration = configuration
        self.inflater = inflater
        let reserved = configuration.allowedReservedBits | (inflater != nil ? 0x40 : 0)
        parser = WSFrameParser(configuration: .init(
            maxFrameSize: configuration.maxFrameSize, allowedReservedBits: reserved,
            expectsMaskedFrames: true))
    }

    /// Compressed input may run slightly past the inflated limit (deflate's stored blocks cost
    /// 5 bytes per 64 KiB).
    var maxCompressedMessageSize: Int {
        configuration.maxMessageSize &+ configuration.maxMessageSize / 8192 &+ 64
    }

    // MARK: Received bytes

    /// Consumes bytes from `input` until there is an action to perform. Returns
    /// ``Action/needMoreBytes`` once `input` holds no complete unit of work.
    public mutating func process(_ input: inout ByteBuffer) -> Action {
        if state == .closed {
            input.moveReaderIndex(forwardBy: input.readableBytes)
            return .needMoreBytes
        }
        while true {
            let result: WSFrameParser.Result
            switch phase {
            case .data:
                if messageCompressed {
                    result = parser.parse(&input, payloadInto: &compressed)
                } else {
                    result = parser.parse(&input, payloadInto: &message)
                }
            case .control, .idle:
                result = parser.parse(&input, payloadInto: &control)
            case .discard:
                result = parser.parse(&input, payloadInto: &scratch)
                scratch.clear()
            }
            switch result {
            case .needMoreBytes:
                return .needMoreBytes
            case .error(let code):
                return fail(code)
            case .header(let header):
                if let action = startFrame(header) { return action }
            case .payload(let count, let frameEnd):
                if let action = payload(count: count, frameEnd: frameEnd) { return action }
            }
        }
    }

    mutating func startFrame(_ header: WSFrameHeader) -> Action? {
        // RSV1 (permessage-deflate) belongs on the first frame of a data message only.
        let rsv1 = header.reservedBits & 0x40 != 0
        if rsv1 && (header.opcode.isControl || header.opcode == .continuation) { return fail(.protocolError) }
        if header.opcode.isControl {
            control.clear()
            phase = state == .open || header.opcode == .close ? .control(header.opcode) : .discard
            return nil
        }
        if state != .open {
            phase = .discard
            return nil
        }
        switch header.opcode {
        case .continuation:
            guard messageOpcode != nil else { return fail(.protocolError) }
        default:
            guard messageOpcode == nil else { return fail(.protocolError) }
            messageOpcode = header.opcode
            messageCompressed = rsv1
            compressedReceived = 0
            utf8.reset()
        }
        if messageCompressed {
            compressedReceived &+= Int(clamping: header.payloadLength)
            if compressedReceived > maxCompressedMessageSize { return fail(.messageTooBig) }
        } else if UInt64(message.readableBytes) + header.payloadLength > UInt64(configuration.maxMessageSize) {
            return fail(.messageTooBig)
        }
        phase = .data(fin: header.fin)
        return nil
    }

    mutating func payload(count: Int, frameEnd: Bool) -> Action? {
        switch phase {
        case .data(let fin):
            var added = count
            if messageCompressed {
                let before = message.readableBytes
                if let failure = inflateCompressed(finish: frameEnd && fin) { return fail(failure) }
                added = message.readableBytes - before
            }
            if messageOpcode == .text && added > 0 {
                let valid = message.withUnsafeReadableBytes { bytes in
                    utf8.validate(UnsafeRawBufferPointer(rebasing: bytes[(bytes.count - added)...]))
                }
                if !valid { return fail(.invalidFramePayloadData) }
            }
            guard frameEnd else { return nil }
            phase = .idle
            guard fin else { return nil }
            return finishMessage()
        case .control(let opcode):
            guard frameEnd else { return nil }
            phase = .idle
            return controlFrame(opcode)
        case .discard:
            if frameEnd { phase = .idle }
            return nil
        case .idle:
            preconditionFailure("payload without a frame header")
        }
    }

    /// Inflates the compressed bytes received so far into ``message`` (and the removed tail at
    /// the end of the message). Returns the close code on failure.
    mutating func inflateCompressed(finish: Bool) -> WebSocketCloseCode? {
        guard let inflater else { return .protocolError }
        let limit = configuration.maxMessageSize
        do throws(PerMessageDeflate.InflateError) {
            if compressed.readableBytes > 0 {
                let input = compressed
                try input.withUnsafeReadableBytes { (bytes) throws(PerMessageDeflate.InflateError) in
                    try inflater.inflate(bytes, into: &message, limit: limit)
                }
                compressed.clear()
            }
            if finish {
                try inflater.finishMessage(into: &message, limit: limit)
                compressedMessages &+= 1
            }
        } catch {
            return error == .tooBig ? .messageTooBig : .invalidFramePayloadData
        }
        return nil
    }

    mutating func finishMessage() -> Action {
        let opcode = messageOpcode
        messageOpcode = nil
        messageCompressed = false
        let bytes = message
        message = ByteBuffer()
        if opcode == .text {
            guard utf8.isAtBoundary else { return fail(.invalidFramePayloadData) }
            let text = bytes.withReadableSpan { ASCII.string(from: $0) }
            return .deliver(.text(text))
        }
        return .deliver(.binary(bytes))
    }

    mutating func controlFrame(_ opcode: WSOpcode) -> Action? {
        switch opcode {
        case .ping:
            return .sendPong(control)
        case .pong:
            return .receivedPong(control)
        case .close:
            return closeFrame()
        default:
            preconditionFailure("not a control opcode")
        }
    }

    mutating func closeFrame() -> Action {
        let count = control.readableBytes
        var code: WebSocketCloseCode?
        if count == 1 { return fail(.protocolError) }
        if count >= 2 {
            let value = WebSocketCloseCode(rawValue: control.getInteger(at: control.readerIndex, as: UInt16.self)!)
            guard value.isValidOnTheWire else { return fail(.protocolError) }
            var reasonValidator = UTF8Validator()
            let valid = control.withUnsafeReadableBytes { bytes in
                reasonValidator.validate(UnsafeRawBufferPointer(rebasing: bytes[2...])) && reasonValidator.isAtBoundary
            }
            guard valid else { return fail(.invalidFramePayloadData) }
            code = value
            receivedCloseReason = control.withReadableSpan { span in
                span.withUnsafeBufferPointer { String(decoding: $0[2...], as: UTF8.self) }
            }
        }
        receivedCloseCode = code ?? .noStatusReceived
        switch state {
        case .open:
            // Echo the code (RFC 6455 §5.5.1), then end the conversation.
            state = .closed
            sentCloseCode = code
            return .sendClose(code: code, reason: "", thenCloseTransport: true)
        case .closing:
            state = .closed
            return .closeTransport(.normal)
        case .closed:
            return .none
        }
    }

    /// Fails the connection (RFC 6455 §7.1.7): send Close with `code` if we have not sent one,
    /// then close the transport.
    mutating func fail(_ code: WebSocketCloseCode) -> Action {
        failure = failure ?? code
        message = ByteBuffer()
        compressed = ByteBuffer()
        messageOpcode = nil
        messageCompressed = false
        switch state {
        case .open:
            state = .closed
            sentCloseCode = code
            return .sendClose(code: code, reason: "", thenCloseTransport: true)
        case .closing:
            state = .closed
            return .closeTransport(.protocolError)
        case .closed:
            return .none
        }
    }

    // MARK: Local events

    public mutating func handle(_ event: Event) -> Action {
        switch event {
        case .closeRequested(let code, let reason):
            guard state == .open else { return .none }
            state = .closing
            sentCloseCode = code
            return .sendClose(code: code, reason: reason, thenCloseTransport: false)
        case .closeTimedOut:
            guard state != .closed else { return .none }
            state = .closed
            receivedCloseCode = receivedCloseCode ?? .abnormalClosure
            return .closeTransport(.timeout)
        case .endOfStream:
            guard state != .closed else { return .none }
            state = .closed
            receivedCloseCode = receivedCloseCode ?? .abnormalClosure
            return .closeTransport(.normal)
        }
    }
}
