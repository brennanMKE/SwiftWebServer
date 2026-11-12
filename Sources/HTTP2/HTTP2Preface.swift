public import HTTPCore

/// The client connection preface (RFC 9113 §3.4): `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`, followed
/// by a SETTINGS frame.
public enum HTTP2Preface {
    /// The 24 octets every HTTP/2 client sends first.
    public static let bytes: [UInt8] = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)

    /// The preface's length, 24.
    public static let count = 24

    /// Whether `bytes` (the first bytes a client sent) start the preface: ``SniffResult/match``
    /// once all 24 octets matched, ``SniffResult/noMatch`` at the first octet that differs, and
    /// ``SniffResult/needMoreBytes`` for a proper prefix.
    public static func match(_ bytes: borrowing ByteBuffer) -> SniffResult {
        bytes.withUnsafeReadableBytes { match($0) }
    }

    /// ``match(_:)`` over raw bytes.
    public static func match(_ input: UnsafeRawBufferPointer) -> SniffResult {
        let count = Swift.min(input.count, Self.count)
        for i in 0..<count where input[i] != Self.bytes[i] { return .noMatch }
        return count == Self.count ? .match : .needMoreBytes
    }
}
