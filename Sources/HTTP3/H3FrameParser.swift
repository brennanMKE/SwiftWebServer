/// An incremental HTTP/3 frame parser for one stream (RFC 9114 §7).
///
/// A value type with no I/O. Call ``parse(_:)`` with the bytes received so far. Each call
/// returns one ``Event`` and the number of input bytes it used. Call again with the bytes
/// after `consumed` until the event is ``Event/needsMoreData``, which always consumes all
/// remaining input. The parser keeps partial varints and partial payloads across calls, so
/// input may be split anywhere.
///
/// - DATA payloads are not buffered. The parser reports ``Event/dataHeader(length:)``
///   and then the payload as one or more ``Event/data(_:)`` ranges into the caller's input.
/// - HEADERS, PUSH_PROMISE, SETTINGS, CANCEL_PUSH, GOAWAY and MAX_PUSH_ID are reported once
///   complete. When the whole payload is in one input chunk, it is reported as a range of
///   that input, with no copy. Otherwise it is collected in an internal buffer, bounded by the
///   configured limits, and reported as ``PayloadLocation/buffered(_:)``.
/// - Reserved (0x1f·N + 0x21) and unknown frame types are skipped without buffering.
/// - HTTP/2-only types (0x02, 0x06, 0x08, 0x09) are `H3_FRAME_UNEXPECTED`.
///
/// The parser also enforces which frames may appear on the configured stream kind
/// (RFC 9114 §7.2, Table 1). Frame-sequence rules within a request stream, such as DATA
/// before HEADERS, belong to the request-stream state machine.
public struct H3FrameParser: Sendable {
    /// The kind of stream the frames arrive on.
    public enum StreamKind: Sendable {
        /// A bidirectional request stream, or a push stream.
        case request
        /// The peer's control stream.
        case control
    }

    /// The local endpoint's role, which decides who may send push-related frames.
    public enum Role: Sendable {
        /// The local endpoint is a server. It never pushes, so a PUSH_PROMISE from the client
        /// is `H3_FRAME_UNEXPECTED`, and MAX_PUSH_ID is accepted on the control stream.
        case server
        /// The local endpoint is a client. PUSH_PROMISE is accepted on request streams, and
        /// MAX_PUSH_ID (which only clients send) is `H3_FRAME_UNEXPECTED`.
        case client
    }

    public struct Configuration: Sendable {
        public var streamKind: StreamKind
        public var role: Role
        /// The largest HEADERS or PUSH_PROMISE payload accepted. Larger is
        /// `H3_EXCESSIVE_LOAD`.
        public var maxFieldSectionLength: Int
        /// The largest SETTINGS payload accepted. Larger is `H3_EXCESSIVE_LOAD`.
        public var maxSettingsLength: Int

        public init(
            streamKind: StreamKind = .request,
            role: Role = .server,
            maxFieldSectionLength: Int = 64 * 1024,
            maxSettingsLength: Int = 4 * 1024
        ) {
            self.streamKind = streamKind
            self.role = role
            self.maxFieldSectionLength = maxFieldSectionLength
            self.maxSettingsLength = maxSettingsLength
        }
    }

    /// Where a complete payload lives.
    public enum PayloadLocation: Equatable, Sendable {
        /// A range of the input passed to the ``parse(_:)`` call that returned the event.
        case input(Range<Int>)
        /// A range of the parser's internal buffer, valid until the next ``parse(_:)`` call.
        /// Read it with ``withPayload(_:in:_:)``.
        case buffered(Range<Int>)
    }

    /// One step of parsing.
    public enum Event: Equatable, Sendable {
        /// All input was consumed without completing anything reportable.
        case needsMoreData
        /// A DATA frame starts. `length` payload bytes follow as ``data(_:)`` events.
        case dataHeader(length: UInt64)
        /// A non-empty part of a DATA payload: a range of this call's input.
        case data(Range<Int>)
        /// A complete HEADERS frame. The location holds the QPACK-encoded field section.
        case headers(PayloadLocation)
        /// A complete PUSH_PROMISE frame (client role only).
        case pushPromise(pushID: UInt64, fieldSection: PayloadLocation)
        /// A complete, validated SETTINGS frame.
        case settings(H3Settings)
        /// A CANCEL_PUSH frame.
        case cancelPush(pushID: UInt64)
        /// A GOAWAY frame: a stream ID from a server, a push ID from a client.
        case goaway(id: UInt64)
        /// A MAX_PUSH_ID frame.
        case maxPushID(UInt64)
    }

    /// The result of ``parse(_:)``.
    public struct Output: Equatable, Sendable {
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
    enum State: Equatable, Sendable {
        case frameType
        case frameLength(H3FrameType)
        case dataPayload(remaining: UInt64)
        case buffering(H3FrameType, length: Int)
        case skipping(remaining: UInt64)
    }

    public let configuration: Configuration
    @usableFromInline var state: State = .frameType
    @usableFromInline var varint = VarintParser()
    @usableFromInline var buffer: [UInt8] = []
    @usableFromInline var sawSettings = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Whether the parser sits between frames. A stream that ends anywhere else ends inside
    /// a frame, which is `H3_FRAME_ERROR` (RFC 9114 §7.1).
    public var isAtFrameBoundary: Bool {
        state == .frameType && !varint.isMidValue
    }

    /// Reports the end of the stream.
    ///
    /// - Throws: `H3_FRAME_ERROR` when the stream ended inside a frame.
    public func finish() throws(HTTP3Error) {
        if !isAtFrameBoundary { throw .frameError }
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

    /// Parses from the start of `input` up to the next reportable event.
    ///
    /// - Throws: an ``HTTP3Error`` for a connection error. The parser must not be used after
    ///   it throws.
    public mutating func parse(_ input: UnsafeRawBufferPointer) throws(HTTP3Error) -> Output {
        var offset = 0
        while true {
            let rest = UnsafeRawBufferPointer(rebasing: input[offset...])
            switch state {
            case .frameType:
                guard case .value(let raw, let used) = varint.parse(rest) else {
                    return Output(.needsMoreData, consumed: input.count)
                }
                offset += used
                let type = H3FrameType(rawValue: raw)
                try admit(type)
                state = .frameLength(type)

            case .frameLength(let type):
                guard case .value(let length, let used) = varint.parse(rest) else {
                    return Output(.needsMoreData, consumed: input.count)
                }
                offset += used
                if type == .data {
                    state = length == 0 ? .frameType : .dataPayload(remaining: length)
                    return Output(.dataHeader(length: length), consumed: offset)
                }
                try begin(type, length: length)

            case .dataPayload(let remaining):
                guard !rest.isEmpty else { return Output(.needsMoreData, consumed: input.count) }
                let count = rest.count < remaining ? rest.count : Int(remaining)
                state = UInt64(count) == remaining ? .frameType : .dataPayload(remaining: remaining - UInt64(count))
                return Output(.data(offset..<(offset + count)), consumed: offset + count)

            case .skipping(let remaining):
                if UInt64(rest.count) < remaining {
                    state = .skipping(remaining: remaining - UInt64(rest.count))
                    return Output(.needsMoreData, consumed: input.count)
                }
                offset += Int(remaining)
                state = .frameType

            case .buffering(let type, let length):
                if buffer.isEmpty && rest.count >= length {
                    // The whole payload is here: report it in place.
                    let start = offset
                    offset += length
                    state = .frameType
                    let payload = UnsafeRawBufferPointer(rebasing: input[start..<offset])
                    let event = try complete(type, payload: payload, base: start, buffered: false)
                    return Output(event, consumed: offset)
                }
                let wanted = length - buffer.count
                let count = rest.count < wanted ? rest.count : wanted
                buffer.append(contentsOf: UnsafeRawBufferPointer(rebasing: rest[..<count]))
                offset += count
                guard buffer.count == length else { return Output(.needsMoreData, consumed: input.count) }
                state = .frameType
                let result: Result<Event, HTTP3Error> = buffer.withUnsafeBytes { payload in
                    do throws(HTTP3Error) {
                        return .success(try complete(type, payload: payload, base: 0, buffered: true))
                    } catch {
                        return .failure(error)
                    }
                }
                return Output(try result.get(), consumed: offset)
            }
        }
    }

    /// Checks that a frame of `type` may appear here (RFC 9114 §6.2.1, §7.2).
    @usableFromInline
    mutating func admit(_ type: H3FrameType) throws(HTTP3Error) {
        if type.isHTTP2Only { throw .frameUnexpected }
        switch configuration.streamKind {
        case .control:
            if !sawSettings {
                // The first frame on a control stream must be SETTINGS, whatever else it is.
                guard type == .settings else { throw .missingSettings }
                sawSettings = true
                return
            }
            switch type {
            case .settings, .data, .headers, .pushPromise:
                throw .frameUnexpected
            case .maxPushID where configuration.role == .client:
                throw .frameUnexpected
            default:
                return
            }
        case .request:
            switch type {
            case .cancelPush, .settings, .goaway, .maxPushID:
                throw .frameUnexpected
            case .pushPromise where configuration.role == .server:
                throw .frameUnexpected
            default:
                return
            }
        }
    }

    /// Validates the length of an admitted non-DATA frame and picks how to read its payload.
    @usableFromInline
    mutating func begin(_ type: H3FrameType, length: UInt64) throws(HTTP3Error) {
        let limit: Int
        switch type {
        case .headers, .pushPromise:
            guard length <= UInt64(configuration.maxFieldSectionLength) else { throw .excessiveLoad }
            limit = Int(length)
        case .settings:
            guard length <= UInt64(configuration.maxSettingsLength) else { throw .excessiveLoad }
            limit = Int(length)
        case .cancelPush, .goaway, .maxPushID:
            // Exactly one varint: 1 to 8 bytes.
            guard length >= 1, length <= 8 else { throw .frameError }
            limit = Int(length)
        default:
            state = length == 0 ? .frameType : .skipping(remaining: length)
            return
        }
        buffer.removeAll(keepingCapacity: true)
        state = .buffering(type, length: limit)
    }

    /// Decodes a complete payload. `base` shifts payload-relative ranges into the location's
    /// coordinates.
    @usableFromInline
    func complete(
        _ type: H3FrameType, payload: UnsafeRawBufferPointer, base: Int, buffered: Bool
    ) throws(HTTP3Error) -> Event {
        func location(_ range: Range<Int>) -> PayloadLocation {
            let shifted = (range.lowerBound + base)..<(range.upperBound + base)
            return buffered ? .buffered(shifted) : .input(shifted)
        }
        switch type {
        case .headers:
            return .headers(location(0..<payload.count))
        case .pushPromise:
            guard case .value(let pushID, let used) = QUICVarint.decode(payload) else { throw .frameError }
            return .pushPromise(pushID: pushID, fieldSection: location(used..<payload.count))
        case .settings:
            return .settings(try H3Settings(payload: payload))
        case .cancelPush:
            return .cancelPush(pushID: try Self.singleVarint(payload))
        case .goaway:
            return .goaway(id: try Self.singleVarint(payload))
        case .maxPushID:
            return .maxPushID(try Self.singleVarint(payload))
        default:
            preconditionFailure("only buffered frame types reach complete")
        }
    }

    /// A payload that must be exactly one varint.
    @usableFromInline
    static func singleVarint(_ payload: UnsafeRawBufferPointer) throws(HTTP3Error) -> UInt64 {
        guard case .value(let value, let used) = QUICVarint.decode(payload), used == payload.count else {
            throw .frameError
        }
        return value
    }
}
