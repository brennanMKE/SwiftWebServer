public import HeaderCompression

/// An HTTP/3 frame type (RFC 9114 §7.2, §11.2.1).
///
/// The type is an open set: any varint value is a valid type, and unknown or reserved types
/// are skipped by receivers.
public struct H3FrameType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt64

    @inlinable
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let data = H3FrameType(rawValue: 0x00)
    public static let headers = H3FrameType(rawValue: 0x01)
    public static let cancelPush = H3FrameType(rawValue: 0x03)
    public static let settings = H3FrameType(rawValue: 0x04)
    public static let pushPromise = H3FrameType(rawValue: 0x05)
    public static let goaway = H3FrameType(rawValue: 0x07)
    public static let maxPushID = H3FrameType(rawValue: 0x0d)

    /// A reserved (GREASE) frame type, 0x1f·N + 0x21 (RFC 9114 §7.2.8).
    @inlinable
    public static func reserved(_ n: UInt64) -> H3FrameType {
        H3FrameType(rawValue: 0x1f &* n &+ 0x21)
    }

    /// Whether this is a reserved (GREASE) type.
    @inlinable
    public var isReserved: Bool { isReservedCodePoint(rawValue) }

    /// Whether this is an HTTP/2 frame type that has no HTTP/3 counterpart: PRIORITY (0x02),
    /// PING (0x06), WINDOW_UPDATE (0x08) or CONTINUATION (0x09). Receiving one is
    /// `H3_FRAME_UNEXPECTED` (RFC 9114 §7.2.8).
    @inlinable
    public var isHTTP2Only: Bool {
        rawValue == 0x02 || rawValue == 0x06 || rawValue == 0x08 || rawValue == 0x09
    }

    public var description: String {
        switch self {
        case .data: "DATA"
        case .headers: "HEADERS"
        case .cancelPush: "CANCEL_PUSH"
        case .settings: "SETTINGS"
        case .pushPromise: "PUSH_PROMISE"
        case .goaway: "GOAWAY"
        case .maxPushID: "MAX_PUSH_ID"
        default: isReserved ? "reserved(0x\(String(rawValue, radix: 16)))" : "unknown(0x\(String(rawValue, radix: 16)))"
        }
    }
}

/// The type of a unidirectional stream, sent as a varint at its start (RFC 9114 §6.2).
public enum H3UniStreamType: Hashable, Sendable {
    /// The control stream (0x00).
    case control
    /// A push stream (0x01).
    case push
    /// The QPACK encoder stream (0x02, RFC 9204 §4.2).
    case qpackEncoder
    /// The QPACK decoder stream (0x03, RFC 9204 §4.2).
    case qpackDecoder
    /// A reserved (GREASE) type, 0x1f·N + 0x21. Receivers ignore the stream.
    case reserved(UInt64)
    /// Any other type. Receivers ignore the stream.
    case unknown(UInt64)

    @inlinable
    public init(rawValue: UInt64) {
        switch rawValue {
        case 0x00: self = .control
        case 0x01: self = .push
        case 0x02: self = .qpackEncoder
        case 0x03: self = .qpackDecoder
        default: self = isReservedCodePoint(rawValue) ? .reserved(rawValue) : .unknown(rawValue)
        }
    }

    @inlinable
    public var rawValue: UInt64 {
        switch self {
        case .control: 0x00
        case .push: 0x01
        case .qpackEncoder: 0x02
        case .qpackDecoder: 0x03
        case .reserved(let value), .unknown(let value): value
        }
    }

    /// Whether the receiver should read and act on the stream. Reserved and unknown types are
    /// skipped: the receiver stops reading them (RFC 9114 §6.2).
    @inlinable
    public var isKnown: Bool {
        switch self {
        case .control, .push, .qpackEncoder, .qpackDecoder: true
        case .reserved, .unknown: false
        }
    }

    /// Appends the stream-type varint that starts a unidirectional stream.
    @inlinable
    public func encode<Sink: ByteSink>(into sink: inout Sink) throws(QUICVarintError) {
        try QUICVarint.encode(rawValue, into: &sink)
    }
}

/// Reads the stream-type varint at the start of an incoming unidirectional stream.
///
/// A value type with no I/O. Feed it the stream's first bytes until it returns
/// ``Result/classified(_:consumed:)``. The remaining bytes of that chunk belong to the
/// stream's body.
public struct UniStreamClassifier: Sendable {
    public enum Result: Equatable, Sendable {
        /// The type is known. `consumed` bytes of this call's input held the type varint.
        case classified(H3UniStreamType, consumed: Int)
        /// All input was consumed and the type is still incomplete.
        case needsMoreData
    }

    @usableFromInline var varint = VarintParser()

    public init() {}

    @inlinable
    public mutating func classify(_ input: UnsafeRawBufferPointer) -> Result {
        switch varint.parse(input) {
        case .value(let raw, let consumed): .classified(H3UniStreamType(rawValue: raw), consumed: consumed)
        case .needsMoreData: .needsMoreData
        }
    }
}

/// HTTP/3 settings (RFC 9114 §7.2.4, RFC 9204 §5, RFC 9220 §3, RFC 9297 §2.1.1).
///
/// Only the settings this server understands are kept. Unknown and reserved identifiers are
/// ignored on receipt, as §7.2.4 requires. Absent settings take their default value.
public struct H3Settings: Equatable, Sendable {
    /// Setting identifiers.
    public enum Identifier {
        /// `SETTINGS_QPACK_MAX_TABLE_CAPACITY` (RFC 9204 §5).
        public static let qpackMaxTableCapacity: UInt64 = 0x01
        /// `SETTINGS_MAX_FIELD_SECTION_SIZE` (RFC 9114 §7.2.4.1).
        public static let maxFieldSectionSize: UInt64 = 0x06
        /// `SETTINGS_QPACK_BLOCKED_STREAMS` (RFC 9204 §5).
        public static let qpackBlockedStreams: UInt64 = 0x07
        /// `SETTINGS_ENABLE_CONNECT_PROTOCOL` (RFC 9220 §3).
        public static let enableConnectProtocol: UInt64 = 0x08
        /// `SETTINGS_H3_DATAGRAM` (RFC 9297 §2.1.1).
        public static let h3Datagram: UInt64 = 0x33

        /// Whether `id` is an HTTP/2 setting with no HTTP/3 counterpart (0x02–0x05).
        /// Receiving one is `H3_SETTINGS_ERROR` (RFC 9114 §7.2.4.1).
        @inlinable
        public static func isHTTP2Only(_ id: UInt64) -> Bool { (0x02...0x05).contains(id) }
    }

    /// QPACK dynamic table capacity. Default 0.
    public var qpackMaxTableCapacity: UInt64?
    /// Largest field section the sender accepts. Default unlimited.
    public var maxFieldSectionSize: UInt64?
    /// QPACK blocked streams. Default 0.
    public var qpackBlockedStreams: UInt64?
    /// Extended CONNECT support. Default false.
    public var enableConnectProtocol: Bool?
    /// HTTP datagram support. Default false.
    public var h3Datagram: Bool?

    public init(
        qpackMaxTableCapacity: UInt64? = nil,
        maxFieldSectionSize: UInt64? = nil,
        qpackBlockedStreams: UInt64? = nil,
        enableConnectProtocol: Bool? = nil,
        h3Datagram: Bool? = nil
    ) {
        self.qpackMaxTableCapacity = qpackMaxTableCapacity
        self.maxFieldSectionSize = maxFieldSectionSize
        self.qpackBlockedStreams = qpackBlockedStreams
        self.enableConnectProtocol = enableConnectProtocol
        self.h3Datagram = h3Datagram
    }

    /// Parses a complete SETTINGS payload.
    ///
    /// - Throws: `H3_FRAME_ERROR` when the payload ends inside a pair, `H3_SETTINGS_ERROR`
    ///   for a duplicate identifier, an HTTP/2-only identifier, or a boolean setting whose
    ///   value is not 0 or 1.
    public init(payload: UnsafeRawBufferPointer) throws(HTTP3Error) {
        self.init()
        var offset = 0
        var pairIndex = 0
        while offset < payload.count {
            let pairStart = offset
            let id = try Self.readVarint(payload, at: &offset)
            let value = try Self.readVarint(payload, at: &offset)
            if Identifier.isHTTP2Only(id) { throw .settingsError }
            // Duplicate check without a set: rescan the earlier pairs. The payload is bounded
            // by the parser's SETTINGS limit, and real peers send a handful of pairs.
            if pairIndex > 0, try Self.contains(id: id, in: UnsafeRawBufferPointer(rebasing: payload[..<pairStart])) {
                throw .settingsError
            }
            pairIndex += 1
            switch id {
            case Identifier.qpackMaxTableCapacity: qpackMaxTableCapacity = value
            case Identifier.maxFieldSectionSize: maxFieldSectionSize = value
            case Identifier.qpackBlockedStreams: qpackBlockedStreams = value
            case Identifier.enableConnectProtocol: enableConnectProtocol = try Self.boolean(value)
            case Identifier.h3Datagram: h3Datagram = try Self.boolean(value)
            default: break  // Unknown and reserved identifiers are ignored.
            }
        }
    }

    private static func boolean(_ value: UInt64) throws(HTTP3Error) -> Bool {
        switch value {
        case 0: false
        case 1: true
        default: throw .settingsError
        }
    }

    private static func readVarint(_ payload: UnsafeRawBufferPointer, at offset: inout Int) throws(HTTP3Error) -> UInt64 {
        switch QUICVarint.decode(UnsafeRawBufferPointer(rebasing: payload[offset...])) {
        case .value(let value, let consumed):
            offset += consumed
            return value
        case .needsMoreData:
            throw .frameError
        }
    }

    private static func contains(id: UInt64, in pairs: UnsafeRawBufferPointer) throws(HTTP3Error) -> Bool {
        var offset = 0
        while offset < pairs.count {
            if try readVarint(pairs, at: &offset) == id { return true }
            _ = try readVarint(pairs, at: &offset)
        }
        return false
    }

    /// The identifier/value pairs this value encodes, in identifier order.
    @usableFromInline
    func forEachPair(_ body: (UInt64, UInt64) throws(QUICVarintError) -> Void) throws(QUICVarintError) {
        if let value = qpackMaxTableCapacity { try body(Identifier.qpackMaxTableCapacity, value) }
        if let value = maxFieldSectionSize { try body(Identifier.maxFieldSectionSize, value) }
        if let value = qpackBlockedStreams { try body(Identifier.qpackBlockedStreams, value) }
        if let value = enableConnectProtocol { try body(Identifier.enableConnectProtocol, value ? 1 : 0) }
        if let value = h3Datagram { try body(Identifier.h3Datagram, value ? 1 : 0) }
    }

    /// The length of the SETTINGS payload ``H3FrameEncoder/encodeSettings(_:grease:into:)``
    /// writes, without its frame header.
    public func payloadLength(grease: (id: UInt64, value: UInt64)? = nil) throws(QUICVarintError) -> Int {
        var length = 0
        func add(_ id: UInt64, _ value: UInt64) throws(QUICVarintError) {
            guard let idLength = QUICVarint.encodedLength(id) else { throw .valueOutOfRange(id) }
            guard let valueLength = QUICVarint.encodedLength(value) else { throw .valueOutOfRange(value) }
            length += idLength + valueLength
        }
        try forEachPair(add)
        if let grease { try add(grease.id, grease.value) }
        return length
    }
}
