public import HTTPCore

/// An incremental HTTP/2 frame parser for one connection (RFC 9113 §4, §6).
///
/// A value type with no I/O. Call ``parse(_:)`` with the bytes received so far. Each call
/// returns one ``Event`` and the number of input bytes it used. Call again with the bytes
/// after `consumed` until the event is ``Event/needsMoreData``, which always consumes all
/// remaining input. Partial frame headers and partial payloads are kept across calls, so
/// input may be split anywhere and parses to the same events.
///
/// - DATA payloads are not buffered. The parser reports ``Event/dataHeader(_:)`` and then the
///   data as one or more ``Event/data(_:)`` ranges into the caller's input. Padding is
///   validated and skipped.
/// - Every other frame is reported once complete. When the whole payload is in one input
///   chunk, its variable part (a header-block fragment, GOAWAY debug data) is a range of
///   that input, with no copy. Otherwise the payload is collected in an internal buffer,
///   bounded by ``maxFrameSize``, and reported as ``PayloadLocation/buffered(_:)``.
/// - HEADERS, PUSH_PROMISE and CONTINUATION payloads are opaque header-block fragments.
///   Assembling them and enforcing their sequence (§6.10) belongs to the layer above.
/// - Unknown frame types are reported as ``Event/unknown(_:)`` and their payload skipped.
///
/// Errors: connection errors are thrown, and the parser must not be used afterwards. Stream
/// errors that the frame layer detects (a PRIORITY frame of the wrong length, a
/// WINDOW_UPDATE of 0, a self-dependent PRIORITY) are reported as ``Event/streamError(_:)``
/// once the frame is consumed, and parsing continues.
public struct HTTP2FrameParser: Sendable {
    /// The local endpoint's role.
    public enum Role: Sendable {
        /// A server: a peer PUSH_PROMISE is `PROTOCOL_ERROR` (§8.4).
        case server
        /// A client: PUSH_PROMISE is accepted, and a server's SETTINGS_ENABLE_PUSH 1 is
        /// `PROTOCOL_ERROR` (§6.5.2).
        case client
    }

    public struct Configuration: Sendable {
        public var role: Role
        /// The local SETTINGS_MAX_FRAME_SIZE: the largest payload accepted. Larger is a
        /// `FRAME_SIZE_ERROR` (§4.2). Must be in 2^14…2^24 − 1.
        public var maxFrameSize: Int

        public init(role: Role = .server, maxFrameSize: Int = HTTP2Settings.defaultMaxFrameSize) {
            precondition(
                (HTTP2Settings.defaultMaxFrameSize...HTTP2Settings.maxMaxFrameSize).contains(maxFrameSize),
                "SETTINGS_MAX_FRAME_SIZE is 2^14 through 2^24-1")
            self.role = role
            self.maxFrameSize = maxFrameSize
        }
    }

    /// Where a payload part lives.
    public enum PayloadLocation: Hashable, Sendable {
        /// A range of the input passed to the ``parse(_:)`` call that returned the event.
        case input(Range<Int>)
        /// A range of the parser's internal buffer, valid until the next ``parse(_:)`` call.
        /// Read it with ``withPayload(_:in:_:)``.
        case buffered(Range<Int>)

        /// The number of bytes.
        @inlinable
        public var count: Int {
            switch self {
            case .input(let range), .buffered(let range): range.count
            }
        }
    }

    /// The start of a DATA frame.
    public struct DataFrame: Hashable, Sendable {
        public var streamID: HTTP2StreamID
        /// Data bytes that follow as ``Event/data(_:)`` events, excluding padding.
        public var dataLength: Int
        /// The whole payload length, padding included, which counts against flow control
        /// (§6.9.1).
        public var flowControlledLength: Int
        public var endStream: Bool

        @inlinable
        public init(streamID: HTTP2StreamID, dataLength: Int, flowControlledLength: Int, endStream: Bool) {
            self.streamID = streamID
            self.dataLength = dataLength
            self.flowControlledLength = flowControlledLength
            self.endStream = endStream
        }
    }

    /// One step of parsing.
    public enum Event: Hashable, Sendable {
        /// All input was consumed without completing anything reportable.
        case needsMoreData
        /// A DATA frame starts; `dataLength` bytes follow as ``data(_:)`` events.
        case dataHeader(DataFrame)
        /// A non-empty part of a DATA payload: a range of this call's input.
        case data(Range<Int>)
        /// A complete HEADERS frame. Padding is removed from `fragment`.
        case headers(
            streamID: HTTP2StreamID, endStream: Bool, endHeaders: Bool, priority: HTTP2Priority?,
            fragment: PayloadLocation)
        /// A valid PRIORITY frame.
        case priority(streamID: HTTP2StreamID, HTTP2Priority)
        /// An RST_STREAM frame.
        case rstStream(streamID: HTTP2StreamID, HTTP2ErrorCode)
        /// A validated SETTINGS frame that is not an acknowledgement.
        case settings(HTTP2Settings)
        /// A SETTINGS acknowledgement.
        case settingsAck
        /// A PUSH_PROMISE frame (client role only). Padding is removed from `fragment`.
        case pushPromise(
            streamID: HTTP2StreamID, promisedStreamID: HTTP2StreamID, endHeaders: Bool,
            fragment: PayloadLocation)
        /// A PING frame and its 8 opaque octets as a big-endian integer.
        case ping(ack: Bool, opaqueData: UInt64)
        /// A GOAWAY frame.
        case goaway(lastStreamID: HTTP2StreamID, HTTP2ErrorCode, debugData: PayloadLocation)
        /// A WINDOW_UPDATE frame with a non-zero increment.
        case windowUpdate(streamID: HTTP2StreamID, increment: UInt32)
        /// A CONTINUATION frame.
        case continuation(streamID: HTTP2StreamID, endHeaders: Bool, fragment: PayloadLocation)
        /// A PRIORITY_UPDATE frame (RFC 9218 §7.1) for `prioritizedStreamID` (never 0), with
        /// its Priority Field Value.
        case priorityUpdate(prioritizedStreamID: HTTP2StreamID, field: PayloadLocation)
        /// A frame of an unknown type. Its payload is skipped; receivers ignore it (§5.5).
        case unknown(HTTP2FrameHeader)
        /// A frame-level stream error (§5.4.2), always ``HTTP2Error/stream(_:_:reason:)``.
        /// The offending frame has been consumed; send RST_STREAM and keep parsing.
        case streamError(HTTP2Error)
    }

    /// The result of ``parse(_:)``.
    public struct Output: Hashable, Sendable {
        public var event: Event
        /// Bytes of this call's input used, including any that ``event``'s ranges refer to.
        public var consumed: Int

        @inlinable
        public init(_ event: Event, consumed: Int) {
            self.event = event
            self.consumed = consumed
        }
    }

    @usableFromInline
    enum State: Hashable, Sendable {
        /// Reading a frame header; `filled` of its 9 bytes are in `partial`.
        case header(filled: Int)
        /// A PADDED DATA frame waiting for its Pad Length octet.
        case dataPadLength(streamID: HTTP2StreamID, length: Int, endStream: Bool)
        case dataPayload(remaining: Int, padding: Int)
        case skipping(remaining: Int)
        /// Collecting the whole payload of a non-DATA frame.
        case buffering(HTTP2FrameHeader)
    }

    public var configuration: Configuration
    @usableFromInline var state: State = .header(filled: 0)
    /// Header fields accumulated byte by byte when a header straddles inputs.
    @usableFromInline var partial = HTTP2FrameHeader(length: 0, type: .data, streamID: .connection)
    @usableFromInline var partialStreamID: UInt32 = 0
    @usableFromInline var buffer: [UInt8] = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The local SETTINGS_MAX_FRAME_SIZE. Raise it only once the peer has acknowledged the
    /// SETTINGS frame that announced it (§6.5.3). Applies from the next frame header.
    public var maxFrameSize: Int {
        get { configuration.maxFrameSize }
        set {
            precondition(
                (HTTP2Settings.defaultMaxFrameSize...HTTP2Settings.maxMaxFrameSize).contains(newValue),
                "SETTINGS_MAX_FRAME_SIZE is 2^14 through 2^24-1")
            configuration.maxFrameSize = newValue
        }
    }

    /// Whether the parser sits between frames. A connection that ends anywhere else ended
    /// inside a frame.
    @inlinable
    public var isAtFrameBoundary: Bool { state == .header(filled: 0) }

    /// Reports the end of input.
    ///
    /// - Throws: a `PROTOCOL_ERROR` connection error when input ended inside a frame.
    public func finish() throws(HTTP2Error) {
        if !isAtFrameBoundary { throw .connection(.protocolError, reason: "input ended inside a frame") }
    }

    /// Calls `body` with the bytes at `location`. `input` must be the buffer passed to the
    /// ``parse(_:)`` call that returned the location.
    public func withPayload<R>(
        _ location: PayloadLocation, in input: UnsafeRawBufferPointer, _ body: (UnsafeRawBufferPointer) -> R
    ) -> R {
        switch location {
        case .input(let range):
            return body(UnsafeRawBufferPointer(rebasing: input[range]))
        case .buffered(let range):
            return buffer.withUnsafeBytes { body(UnsafeRawBufferPointer(rebasing: $0[range])) }
        }
    }

    /// Parses the readable bytes of `buffer`. Ranges in the event are relative to
    /// `buffer.readerIndex`; the caller moves the reader index by `consumed`.
    @inlinable
    public mutating func parse(_ buffer: ByteBuffer) throws(HTTP2Error) -> Output {
        try buffer.withUnsafeReadableBytes { (input) throws(HTTP2Error) -> Output in try parse(input) }
    }

    /// Parses from the start of `input` up to the next reportable event.
    ///
    /// - Throws: a connection error. The parser must not be used after it throws.
    public mutating func parse(_ input: UnsafeRawBufferPointer) throws(HTTP2Error) -> Output {
        var offset = 0
        while true {
            let available = input.count - offset
            switch state {
            case .header(var filled):
                let header: HTTP2FrameHeader
                if filled == 0 && available >= HTTP2FrameHeader.size {
                    header = Self.decodeHeader(input, at: offset)
                    offset += HTTP2FrameHeader.size
                } else {
                    while filled < HTTP2FrameHeader.size && offset < input.count {
                        accumulate(input[offset], at: filled)
                        filled += 1
                        offset += 1
                    }
                    guard filled == HTTP2FrameHeader.size else {
                        state = .header(filled: filled)
                        return Output(.needsMoreData, consumed: input.count)
                    }
                    partial.streamID = HTTP2StreamID(wireValue: partialStreamID)
                    header = partial
                }
                state = .header(filled: 0)
                if let event = try begin(header) {
                    return Output(event, consumed: offset)
                }

            case .dataPadLength(let streamID, let length, let endStream):
                guard available > 0 else { return Output(.needsMoreData, consumed: input.count) }
                let padding = Int(input[offset])
                offset += 1
                let dataLength = length - 1 - padding
                guard dataLength >= 0 else {
                    throw .connection(.protocolError, reason: "DATA padding exceeds payload")
                }
                state = Self.dataState(remaining: dataLength, padding: padding)
                let frame = DataFrame(
                    streamID: streamID, dataLength: dataLength, flowControlledLength: length, endStream: endStream)
                return Output(.dataHeader(frame), consumed: offset)

            case .dataPayload(let remaining, let padding):
                guard available > 0 else { return Output(.needsMoreData, consumed: input.count) }
                let count = available < remaining ? available : remaining
                state = count == remaining ? Self.dataState(remaining: 0, padding: padding)
                    : .dataPayload(remaining: remaining - count, padding: padding)
                return Output(.data(offset..<(offset + count)), consumed: offset + count)

            case .skipping(let remaining):
                if available < remaining {
                    state = .skipping(remaining: remaining - available)
                    return Output(.needsMoreData, consumed: input.count)
                }
                offset += remaining
                state = .header(filled: 0)

            case .buffering(let header):
                let length = header.length
                if buffer.isEmpty && available >= length {
                    // The whole payload is here: report it in place.
                    let start = offset
                    offset += length
                    state = .header(filled: 0)
                    let payload = UnsafeRawBufferPointer(rebasing: input[start..<offset])
                    let event = try complete(header, payload: payload, base: start, buffered: false)
                    return Output(event, consumed: offset)
                }
                let wanted = length - buffer.count
                let count = available < wanted ? available : wanted
                buffer.append(contentsOf: UnsafeRawBufferPointer(rebasing: input[offset..<(offset + count)]))
                offset += count
                guard buffer.count == length else { return Output(.needsMoreData, consumed: input.count) }
                state = .header(filled: 0)
                let result: Result<Event, HTTP2Error> = buffer.withUnsafeBytes { payload in
                    do throws(HTTP2Error) {
                        return .success(try complete(header, payload: payload, base: 0, buffered: true))
                    } catch {
                        return .failure(error)
                    }
                }
                return Output(try result.get(), consumed: offset)
            }
        }
    }

    @inlinable
    static func dataState(remaining: Int, padding: Int) -> State {
        if remaining > 0 { return .dataPayload(remaining: remaining, padding: padding) }
        return padding > 0 ? .skipping(remaining: padding) : .header(filled: 0)
    }

    @inlinable
    static func decodeHeader(_ input: UnsafeRawBufferPointer, at offset: Int) -> HTTP2FrameHeader {
        let length = Int(input[offset]) << 16 | Int(input[offset + 1]) << 8 | Int(input[offset + 2])
        return HTTP2FrameHeader(
            length: length,
            type: HTTP2FrameType(rawValue: input[offset + 3]),
            flags: HTTP2FrameFlags(rawValue: input[offset + 4]),
            streamID: HTTP2StreamID(wireValue: readUInt32(input, at: offset + 5)))
    }

    @inlinable
    mutating func accumulate(_ byte: UInt8, at index: Int) {
        switch index {
        case 0: partial.length = Int(byte)
        case 1, 2: partial.length = partial.length << 8 | Int(byte)
        case 3: partial.type = HTTP2FrameType(rawValue: byte)
        case 4: partial.flags = HTTP2FrameFlags(rawValue: byte)
        case 5: partialStreamID = UInt32(byte)
        default: partialStreamID = partialStreamID << 8 | UInt32(byte)
        }
    }

    /// Validates a frame header and picks how to read its payload. Returns an event to report
    /// now, if any.
    @usableFromInline
    mutating func begin(_ header: HTTP2FrameHeader) throws(HTTP2Error) -> Event? {
        let length = header.length
        let stream = header.streamID
        let flags = header.flags
        guard length <= configuration.maxFrameSize else {
            throw .connection(.frameSizeError, reason: "frame exceeds SETTINGS_MAX_FRAME_SIZE")
        }
        switch header.type {
        case .data:
            if stream.isConnection { throw .connection(.protocolError, reason: "DATA on stream 0") }
            let endStream = flags.contains(.endStream)
            if flags.contains(.padded) {
                guard length >= 1 else { throw .connection(.frameSizeError, reason: "PADDED DATA has no Pad Length") }
                state = .dataPadLength(streamID: stream, length: length, endStream: endStream)
                return nil
            }
            state = Self.dataState(remaining: length, padding: 0)
            return .dataHeader(
                DataFrame(streamID: stream, dataLength: length, flowControlledLength: length, endStream: endStream))

        case .headers:
            if stream.isConnection { throw .connection(.protocolError, reason: "HEADERS on stream 0") }
            let minimum = (flags.contains(.padded) ? 1 : 0) + (flags.contains(.priority) ? HTTP2Priority.size : 0)
            guard length >= minimum else {
                throw .connection(.frameSizeError, reason: "HEADERS too short for its fields")
            }

        case .priority:
            if stream.isConnection { throw .connection(.protocolError, reason: "PRIORITY on stream 0") }
            guard length == HTTP2Priority.size else {
                state = length == 0 ? .header(filled: 0) : .skipping(remaining: length)
                return .streamError(.stream(stream, .frameSizeError, reason: "PRIORITY length is not 5"))
            }

        case .rstStream:
            if stream.isConnection { throw .connection(.protocolError, reason: "RST_STREAM on stream 0") }
            guard length == 4 else { throw .connection(.frameSizeError, reason: "RST_STREAM length is not 4") }

        case .settings:
            if !stream.isConnection { throw .connection(.protocolError, reason: "SETTINGS on a stream") }
            if flags.contains(.ack) {
                guard length == 0 else { throw .connection(.frameSizeError, reason: "SETTINGS ACK with a payload") }
                return .settingsAck
            }
            guard length % HTTP2Settings.parameterSize == 0 else {
                throw .connection(.frameSizeError, reason: "SETTINGS length is not a multiple of 6")
            }
            if length == 0 { return .settings(HTTP2Settings()) }

        case .pushPromise:
            if configuration.role == .server {
                throw .connection(.protocolError, reason: "client sent PUSH_PROMISE")
            }
            if stream.isConnection { throw .connection(.protocolError, reason: "PUSH_PROMISE on stream 0") }
            guard length >= (flags.contains(.padded) ? 1 : 0) + 4 else {
                throw .connection(.frameSizeError, reason: "PUSH_PROMISE too short for its fields")
            }

        case .ping:
            if !stream.isConnection { throw .connection(.protocolError, reason: "PING on a stream") }
            guard length == 8 else { throw .connection(.frameSizeError, reason: "PING length is not 8") }

        case .goaway:
            if !stream.isConnection { throw .connection(.protocolError, reason: "GOAWAY on a stream") }
            guard length >= 8 else { throw .connection(.frameSizeError, reason: "GOAWAY shorter than 8") }

        case .windowUpdate:
            guard length == 4 else { throw .connection(.frameSizeError, reason: "WINDOW_UPDATE length is not 4") }

        case .continuation:
            if stream.isConnection { throw .connection(.protocolError, reason: "CONTINUATION on stream 0") }

        case .priorityUpdate:
            // RFC 9218 §7.1: only on stream 0, and at least the Prioritized Stream ID.
            if !stream.isConnection { throw .connection(.protocolError, reason: "PRIORITY_UPDATE on a stream") }
            guard length >= 4 else { throw .connection(.frameSizeError, reason: "PRIORITY_UPDATE shorter than 4") }

        default:
            state = length == 0 ? .header(filled: 0) : .skipping(remaining: length)
            return .unknown(header)
        }
        // The buffer is cleared here, not after a buffered frame completes, so a
        // `.buffered` location stays readable until the next frame starts.
        buffer.removeAll(keepingCapacity: true)
        state = .buffering(header)
        return nil
    }

    /// Decodes a complete non-DATA payload. `base` shifts payload-relative ranges into the
    /// location's coordinates.
    @usableFromInline
    func complete(
        _ header: HTTP2FrameHeader, payload: UnsafeRawBufferPointer, base: Int, buffered: Bool
    ) throws(HTTP2Error) -> Event {
        func location(_ range: Range<Int>) -> PayloadLocation {
            let shifted = (range.lowerBound + base)..<(range.upperBound + base)
            return buffered ? .buffered(shifted) : .input(shifted)
        }
        let stream = header.streamID
        let flags = header.flags
        switch header.type {
        case .headers:
            var start = 0
            var end = payload.count
            if flags.contains(.padded) {
                end -= Int(payload[0])
                start = 1
            }
            var priority: HTTP2Priority?
            if flags.contains(.priority) {
                priority = Self.decodePriority(payload, at: start)
                start += HTTP2Priority.size
            }
            guard end >= start else { throw .connection(.protocolError, reason: "HEADERS padding exceeds payload") }
            return .headers(
                streamID: stream, endStream: flags.contains(.endStream), endHeaders: flags.contains(.endHeaders),
                priority: priority, fragment: location(start..<end))

        case .priority:
            let priority = Self.decodePriority(payload, at: 0)
            if priority.dependency == stream {
                return .streamError(.stream(stream, .protocolError, reason: "stream depends on itself"))
            }
            return .priority(streamID: stream, priority)

        case .rstStream:
            return .rstStream(streamID: stream, HTTP2ErrorCode(rawValue: readUInt32(payload, at: 0)))

        case .settings:
            return .settings(try HTTP2Settings(payload: payload, fromServer: configuration.role == .client))

        case .pushPromise:
            var start = 0
            var end = payload.count
            if flags.contains(.padded) {
                end -= Int(payload[0])
                start = 1
            }
            let promised = HTTP2StreamID(wireValue: readUInt32(payload, at: start))
            start += 4
            guard end >= start else {
                throw .connection(.protocolError, reason: "PUSH_PROMISE padding exceeds payload")
            }
            return .pushPromise(
                streamID: stream, promisedStreamID: promised, endHeaders: flags.contains(.endHeaders),
                fragment: location(start..<end))

        case .ping:
            let opaque = UInt64(readUInt32(payload, at: 0)) << 32 | UInt64(readUInt32(payload, at: 4))
            return .ping(ack: flags.contains(.ack), opaqueData: opaque)

        case .goaway:
            return .goaway(
                lastStreamID: HTTP2StreamID(wireValue: readUInt32(payload, at: 0)),
                HTTP2ErrorCode(rawValue: readUInt32(payload, at: 4)),
                debugData: location(8..<payload.count))

        case .windowUpdate:
            let increment = readUInt32(payload, at: 0) & 0x7fff_ffff
            if increment == 0 {
                if stream.isConnection {
                    throw .connection(.protocolError, reason: "WINDOW_UPDATE increment 0 on the connection")
                }
                return .streamError(.stream(stream, .protocolError, reason: "WINDOW_UPDATE increment 0"))
            }
            return .windowUpdate(streamID: stream, increment: increment)

        case .continuation:
            return .continuation(streamID: stream, endHeaders: flags.contains(.endHeaders), fragment: location(0..<payload.count))

        case .priorityUpdate:
            let prioritized = HTTP2StreamID(wireValue: readUInt32(payload, at: 0))
            if prioritized.isConnection {
                throw .connection(.protocolError, reason: "PRIORITY_UPDATE for stream 0")
            }
            return .priorityUpdate(prioritizedStreamID: prioritized, field: location(4..<payload.count))

        default:
            preconditionFailure("only buffered frame types reach complete")
        }
    }

    @inlinable
    static func decodePriority(_ payload: UnsafeRawBufferPointer, at offset: Int) -> HTTP2Priority {
        let word = readUInt32(payload, at: offset)
        return HTTP2Priority(
            exclusive: word & 0x8000_0000 != 0,
            dependency: HTTP2StreamID(wireValue: word),
            weight: UInt16(payload[offset + 4]) + 1)
    }
}
