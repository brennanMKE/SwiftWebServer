/// An HTTP/2 stream identifier (RFC 9113 §5.1.1): an unsigned 31-bit integer.
///
/// Stream 0 is the connection itself and carries connection control frames. Clients open
/// odd-numbered streams and servers even-numbered ones.
public struct HTTP2StreamID: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The largest stream identifier, 2^31 − 1.
    public static let maxValue: UInt32 = 0x7fff_ffff

    /// Stream 0, which identifies the connection as a whole.
    public static let connection = HTTP2StreamID(0)

    public let rawValue: UInt32

    /// Creates an identifier from a 31-bit value. Returns `nil` above ``maxValue``.
    @inlinable
    public init?(rawValue: UInt32) {
        guard rawValue <= Self.maxValue else { return nil }
        self.rawValue = rawValue
    }

    /// Creates an identifier from a 31-bit value, which must not exceed ``maxValue``.
    @inlinable
    public init(_ value: UInt32) {
        precondition(value <= Self.maxValue, "HTTP/2 stream identifiers are 31 bits")
        self.rawValue = value
    }

    /// Creates an identifier from a 32-bit wire field, ignoring the reserved high bit
    /// (RFC 9113 §4.1).
    @inlinable
    public init(wireValue: UInt32) {
        self.rawValue = wireValue & Self.maxValue
    }

    /// Whether this is stream 0.
    @inlinable public var isConnection: Bool { rawValue == 0 }

    /// Whether a client opens this stream (odd, RFC 9113 §5.1.1).
    @inlinable public var isClientInitiated: Bool { rawValue & 1 == 1 }

    /// Whether a server opens this stream (even and not 0).
    @inlinable public var isServerInitiated: Bool { rawValue != 0 && rawValue & 1 == 0 }

    @inlinable
    public static func < (lhs: HTTP2StreamID, rhs: HTTP2StreamID) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { String(rawValue) }
}
