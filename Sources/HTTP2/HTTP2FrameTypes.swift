/// An HTTP/2 frame type (RFC 9113 §6, §11.2).
///
/// The set is open: any 8-bit value may arrive. Receivers ignore unknown types (§5.5);
/// ``HTTP2FrameParser`` reports them as ``HTTP2FrameParser/Event/unknown(_:)`` so a caller
/// can still apply rules such as "nothing may interrupt a header block" (§6.10).
public struct HTTP2FrameType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt8

    @inlinable
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let data = HTTP2FrameType(rawValue: 0x0)
    public static let headers = HTTP2FrameType(rawValue: 0x1)
    public static let priority = HTTP2FrameType(rawValue: 0x2)
    public static let rstStream = HTTP2FrameType(rawValue: 0x3)
    public static let settings = HTTP2FrameType(rawValue: 0x4)
    public static let pushPromise = HTTP2FrameType(rawValue: 0x5)
    public static let ping = HTTP2FrameType(rawValue: 0x6)
    public static let goaway = HTTP2FrameType(rawValue: 0x7)
    public static let windowUpdate = HTTP2FrameType(rawValue: 0x8)
    public static let continuation = HTTP2FrameType(rawValue: 0x9)

    /// Whether RFC 9113 defines this type.
    @inlinable public var isKnown: Bool { rawValue <= 0x9 }

    public var description: String {
        switch rawValue {
        case 0x0: "DATA"
        case 0x1: "HEADERS"
        case 0x2: "PRIORITY"
        case 0x3: "RST_STREAM"
        case 0x4: "SETTINGS"
        case 0x5: "PUSH_PROMISE"
        case 0x6: "PING"
        case 0x7: "GOAWAY"
        case 0x8: "WINDOW_UPDATE"
        case 0x9: "CONTINUATION"
        default: "unknown(0x\(String(rawValue, radix: 16)))"
        }
    }
}

/// Frame flags (RFC 9113 §4.1). Their meaning depends on the frame type, and flags a type does
/// not define are ignored on receipt and must be sent as zero.
public struct HTTP2FrameFlags: OptionSet, Hashable, Sendable {
    public var rawValue: UInt8

    @inlinable
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// END_STREAM on DATA and HEADERS.
    public static let endStream = HTTP2FrameFlags(rawValue: 0x01)
    /// ACK on SETTINGS and PING. Same bit as ``endStream``.
    public static let ack = HTTP2FrameFlags(rawValue: 0x01)
    /// END_HEADERS on HEADERS, PUSH_PROMISE and CONTINUATION.
    public static let endHeaders = HTTP2FrameFlags(rawValue: 0x04)
    /// PADDED on DATA, HEADERS and PUSH_PROMISE.
    public static let padded = HTTP2FrameFlags(rawValue: 0x08)
    /// PRIORITY on HEADERS.
    public static let priority = HTTP2FrameFlags(rawValue: 0x20)
}

/// The 9-octet header that starts every frame (RFC 9113 §4.1).
public struct HTTP2FrameHeader: Hashable, Sendable {
    /// The encoded size of a frame header.
    public static let size = 9
    /// The largest payload length a frame header can express, 2^24 − 1.
    public static let maxLength = 0xff_ffff

    /// Payload length, excluding these 9 octets. At most ``maxLength``.
    public var length: Int
    public var type: HTTP2FrameType
    public var flags: HTTP2FrameFlags
    public var streamID: HTTP2StreamID

    @inlinable
    public init(length: Int, type: HTTP2FrameType, flags: HTTP2FrameFlags = [], streamID: HTTP2StreamID) {
        self.length = length
        self.type = type
        self.flags = flags
        self.streamID = streamID
    }
}

/// Stream priority fields from a PRIORITY frame or a HEADERS frame with the PRIORITY flag
/// (RFC 9113 §5.3.2, §6.3). RFC 9113 deprecates this scheme; the fields are decoded so the
/// frames stay well-formed, and a server may ignore them.
public struct HTTP2Priority: Hashable, Sendable {
    /// Whether the dependency is exclusive.
    public var exclusive: Bool
    /// The stream this one depends on.
    public var dependency: HTTP2StreamID
    /// The weight, 1 through 256. The wire carries `weight − 1`.
    public var weight: UInt16

    @inlinable
    public init(exclusive: Bool = false, dependency: HTTP2StreamID = .connection, weight: UInt16 = 16) {
        precondition((1...256).contains(weight), "HTTP/2 priority weight is 1 through 256")
        self.exclusive = exclusive
        self.dependency = dependency
        self.weight = weight
    }

    /// The encoded size of the priority fields.
    public static let size = 5
}

/// HTTP/2 settings (RFC 9113 §6.5.2, RFC 8441 §3, RFC 9218 §2.1).
///
/// Only identifiers this server understands are kept; unknown ones are ignored on receipt
/// (§6.5.2). A setting that appears more than once takes its last value, which matches
/// processing the parameters in order (§6.5.3). `nil` means the setting was absent and keeps
/// its current value.
public struct HTTP2Settings: Hashable, Sendable {
    /// Setting identifiers.
    public enum Identifier {
        public static let headerTableSize: UInt16 = 0x1
        public static let enablePush: UInt16 = 0x2
        public static let maxConcurrentStreams: UInt16 = 0x3
        public static let initialWindowSize: UInt16 = 0x4
        public static let maxFrameSize: UInt16 = 0x5
        public static let maxHeaderListSize: UInt16 = 0x6
        /// RFC 8441 §3.
        public static let enableConnectProtocol: UInt16 = 0x8
        /// RFC 9218 §2.1.
        public static let noRFC7540Priorities: UInt16 = 0x9
    }

    /// The size of one identifier/value pair on the wire.
    public static let parameterSize = 6
    /// The default and smallest SETTINGS_MAX_FRAME_SIZE, 2^14.
    public static let defaultMaxFrameSize = 16_384
    /// The largest SETTINGS_MAX_FRAME_SIZE, 2^24 − 1.
    public static let maxMaxFrameSize = 16_777_215
    /// The largest SETTINGS_INITIAL_WINDOW_SIZE, 2^31 − 1.
    public static let maxWindowSize: UInt32 = 0x7fff_ffff

    public var headerTableSize: UInt32?
    public var enablePush: Bool?
    public var maxConcurrentStreams: UInt32?
    public var initialWindowSize: UInt32?
    public var maxFrameSize: UInt32?
    public var maxHeaderListSize: UInt32?
    public var enableConnectProtocol: Bool?
    public var noRFC7540Priorities: Bool?

    public init(
        headerTableSize: UInt32? = nil,
        enablePush: Bool? = nil,
        maxConcurrentStreams: UInt32? = nil,
        initialWindowSize: UInt32? = nil,
        maxFrameSize: UInt32? = nil,
        maxHeaderListSize: UInt32? = nil,
        enableConnectProtocol: Bool? = nil,
        noRFC7540Priorities: Bool? = nil
    ) {
        self.headerTableSize = headerTableSize
        self.enablePush = enablePush
        self.maxConcurrentStreams = maxConcurrentStreams
        self.initialWindowSize = initialWindowSize
        self.maxFrameSize = maxFrameSize
        self.maxHeaderListSize = maxHeaderListSize
        self.enableConnectProtocol = enableConnectProtocol
        self.noRFC7540Priorities = noRFC7540Priorities
    }

    /// Decodes and validates a SETTINGS payload whose length is a multiple of 6.
    ///
    /// - Parameter fromServer: whether the peer is a server, which may not enable push.
    /// - Throws: connection errors per RFC 9113 §6.5.2: `PROTOCOL_ERROR` for an
    ///   ENABLE_PUSH, ENABLE_CONNECT_PROTOCOL or NO_RFC7540_PRIORITIES value other than 0 or 1
    ///   (and ENABLE_PUSH 1 from a server), or a MAX_FRAME_SIZE outside 2^14…2^24 − 1;
    ///   `FLOW_CONTROL_ERROR` for an INITIAL_WINDOW_SIZE above 2^31 − 1.
    public init(payload: UnsafeRawBufferPointer, fromServer: Bool = false) throws(HTTP2Error) {
        self.init()
        precondition(payload.count % Self.parameterSize == 0, "SETTINGS length is checked by the frame parser")
        var offset = 0
        while offset < payload.count {
            let id = UInt16(payload[offset]) << 8 | UInt16(payload[offset + 1])
            let value = readUInt32(payload, at: offset + 2)
            offset += Self.parameterSize
            switch id {
            case Identifier.headerTableSize:
                headerTableSize = value
            case Identifier.enablePush:
                let push = try Self.boolean(value, "SETTINGS_ENABLE_PUSH")
                if push && fromServer {
                    throw .connection(.protocolError, reason: "server sent SETTINGS_ENABLE_PUSH 1")
                }
                enablePush = push
            case Identifier.maxConcurrentStreams:
                maxConcurrentStreams = value
            case Identifier.initialWindowSize:
                guard value <= Self.maxWindowSize else {
                    throw .connection(.flowControlError, reason: "SETTINGS_INITIAL_WINDOW_SIZE above 2^31-1")
                }
                initialWindowSize = value
            case Identifier.maxFrameSize:
                guard value >= Self.defaultMaxFrameSize, value <= Self.maxMaxFrameSize else {
                    throw .connection(.protocolError, reason: "SETTINGS_MAX_FRAME_SIZE out of range")
                }
                maxFrameSize = value
            case Identifier.maxHeaderListSize:
                maxHeaderListSize = value
            case Identifier.enableConnectProtocol:
                enableConnectProtocol = try Self.boolean(value, "SETTINGS_ENABLE_CONNECT_PROTOCOL")
            case Identifier.noRFC7540Priorities:
                noRFC7540Priorities = try Self.boolean(value, "SETTINGS_NO_RFC7540_PRIORITIES")
            default:
                break  // Unknown identifiers are ignored (§6.5.2).
            }
        }
    }

    private static func boolean(_ value: UInt32, _ name: StaticString) throws(HTTP2Error) -> Bool {
        switch value {
        case 0: return false
        case 1: return true
        default: throw .connection(.protocolError, reason: "\(name) must be 0 or 1")
        }
    }

    /// The number of parameters ``HTTP2FrameEncoder/encodeSettings(_:into:)`` writes.
    @inlinable
    public var parameterCount: Int {
        var count = 0
        if headerTableSize != nil { count += 1 }
        if enablePush != nil { count += 1 }
        if maxConcurrentStreams != nil { count += 1 }
        if initialWindowSize != nil { count += 1 }
        if maxFrameSize != nil { count += 1 }
        if maxHeaderListSize != nil { count += 1 }
        if enableConnectProtocol != nil { count += 1 }
        if noRFC7540Priorities != nil { count += 1 }
        return count
    }

    /// Calls `body` with each present parameter, in identifier order.
    @inlinable
    public func forEachParameter(_ body: (UInt16, UInt32) -> Void) {
        if let value = headerTableSize { body(Identifier.headerTableSize, value) }
        if let value = enablePush { body(Identifier.enablePush, value ? 1 : 0) }
        if let value = maxConcurrentStreams { body(Identifier.maxConcurrentStreams, value) }
        if let value = initialWindowSize { body(Identifier.initialWindowSize, value) }
        if let value = maxFrameSize { body(Identifier.maxFrameSize, value) }
        if let value = maxHeaderListSize { body(Identifier.maxHeaderListSize, value) }
        if let value = enableConnectProtocol { body(Identifier.enableConnectProtocol, value ? 1 : 0) }
        if let value = noRFC7540Priorities { body(Identifier.noRFC7540Priorities, value ? 1 : 0) }
    }
}

/// The big-endian `UInt32` at `offset`, which must have four bytes after it.
@inlinable
func readUInt32(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
    UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
}
