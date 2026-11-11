/// Why HPACK rejected a header block or table operation.
///
/// Every case is a connection error of type `COMPRESSION_ERROR` (RFC 9113 §4.3, RFC 7541 §2.3.3).
/// `HTTP2` (#0036, not yet on `main`) maps any `HPACKError` to
/// `HTTP2Error.connection(.compressionError, reason: …)`; ``http2ErrorCode`` carries the wire
/// value so that mapping needs no table. The cases exist for logging and tests; none of them
/// is sent to the peer.
public enum HPACKError: Error, Equatable, Sendable {
    /// An index of 0, or one past the end of the static and dynamic tables (RFC 7541 §2.3.3).
    case invalidIndex(UInt64)

    /// The HTTP/2 error code for every HPACK error: `COMPRESSION_ERROR` (0x9).
    public static let compressionErrorCode: UInt32 = 0x9

    /// The HTTP/2 error code to close the connection with: always `COMPRESSION_ERROR`.
    public var http2ErrorCode: UInt32 { Self.compressionErrorCode }
}
