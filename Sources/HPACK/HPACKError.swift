public import HeaderCompression

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
    /// The block ends in the middle of a representation.
    case truncatedBlock
    /// A prefix integer exceeds 2^32 − 1 or is overlong (RFC 7541 §5.1).
    case integerOverflow
    /// A string literal's encoded length exceeds the decoder's string limit.
    case stringTooLong
    /// A Huffman-coded string is malformed (RFC 7541 §5.2).
    case invalidHuffman(HeaderCompressionError)
    /// A dynamic table size update follows a header field (RFC 7541 §4.2).
    case tableSizeUpdateNotAtStart
    /// A dynamic table size update exceeds the advertised `SETTINGS_HEADER_TABLE_SIZE`
    /// (RFC 7541 §6.3).
    case tableSizeUpdateTooLarge(requested: UInt64, limit: Int)
    /// The advertised table size was lowered below the table's size, and the first block after
    /// that does not start with a size update (RFC 7541 §4.2).
    case missingTableSizeUpdate
    /// The decoded header list exceeds the limit (name + value + 32 per field, RFC 9113 §6.5.2).
    case headerListTooLarge(limit: Int)
    /// An earlier block failed; the decoder's table may be out of sync with the peer's, so it
    /// accepts nothing more (RFC 9113 §4.3: the connection must close).
    case decoderUnusable

    /// The HTTP/2 error code for every HPACK error: `COMPRESSION_ERROR` (0x9).
    public static let compressionErrorCode: UInt32 = 0x9

    /// The HTTP/2 error code to close the connection with: always `COMPRESSION_ERROR`.
    public var http2ErrorCode: UInt32 { Self.compressionErrorCode }
}
