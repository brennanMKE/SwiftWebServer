/// An HTTP/2 error code (RFC 9113 §7), carried in RST_STREAM and GOAWAY frames.
///
/// The set is open: any 32-bit value may appear on the wire. Unknown codes are preserved
/// so they can be logged and re-encoded, and a receiver must not give them special meaning
/// (they are treated like ``internalError`` where behaviour is needed).
public struct HTTP2ErrorCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt32

    @inlinable
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// The condition is not a result of an error, such as a graceful GOAWAY.
    public static let noError = HTTP2ErrorCode(rawValue: 0x0)
    /// A protocol error that no more specific code covers.
    public static let protocolError = HTTP2ErrorCode(rawValue: 0x1)
    /// An unexpected internal error.
    public static let internalError = HTTP2ErrorCode(rawValue: 0x2)
    /// The peer violated the flow-control protocol.
    public static let flowControlError = HTTP2ErrorCode(rawValue: 0x3)
    /// A SETTINGS frame was not acknowledged in time.
    public static let settingsTimeout = HTTP2ErrorCode(rawValue: 0x4)
    /// A frame arrived after the stream was half-closed.
    public static let streamClosed = HTTP2ErrorCode(rawValue: 0x5)
    /// A frame has an invalid size.
    public static let frameSizeError = HTTP2ErrorCode(rawValue: 0x6)
    /// The stream was refused before any application processing.
    public static let refusedStream = HTTP2ErrorCode(rawValue: 0x7)
    /// The stream is no longer needed.
    public static let cancel = HTTP2ErrorCode(rawValue: 0x8)
    /// The field-compression context can no longer be maintained.
    public static let compressionError = HTTP2ErrorCode(rawValue: 0x9)
    /// The TCP connection for a CONNECT request was reset or closed abnormally.
    public static let connectError = HTTP2ErrorCode(rawValue: 0xa)
    /// The peer is generating excessive load.
    public static let enhanceYourCalm = HTTP2ErrorCode(rawValue: 0xb)
    /// The transport does not meet minimum security requirements.
    public static let inadequateSecurity = HTTP2ErrorCode(rawValue: 0xc)
    /// The request must be retried over HTTP/1.1.
    public static let http11Required = HTTP2ErrorCode(rawValue: 0xd)

    /// Every code RFC 9113 §7 defines, in wire order.
    public static let allDefined: [HTTP2ErrorCode] = [
        .noError, .protocolError, .internalError, .flowControlError, .settingsTimeout, .streamClosed,
        .frameSizeError, .refusedStream, .cancel, .compressionError, .connectError, .enhanceYourCalm,
        .inadequateSecurity, .http11Required,
    ]

    /// Whether RFC 9113 defines this code.
    @inlinable public var isDefined: Bool { rawValue <= 0xd }

    /// The code's name as RFC 9113 writes it, such as `FRAME_SIZE_ERROR`, or `UNKNOWN` for an
    /// undefined code. Safe to send to the peer as GOAWAY debug data.
    public var name: StaticString {
        switch rawValue {
        case 0x0: "NO_ERROR"
        case 0x1: "PROTOCOL_ERROR"
        case 0x2: "INTERNAL_ERROR"
        case 0x3: "FLOW_CONTROL_ERROR"
        case 0x4: "SETTINGS_TIMEOUT"
        case 0x5: "STREAM_CLOSED"
        case 0x6: "FRAME_SIZE_ERROR"
        case 0x7: "REFUSED_STREAM"
        case 0x8: "CANCEL"
        case 0x9: "COMPRESSION_ERROR"
        case 0xa: "CONNECT_ERROR"
        case 0xb: "ENHANCE_YOUR_CALM"
        case 0xc: "INADEQUATE_SECURITY"
        case 0xd: "HTTP_1_1_REQUIRED"
        default: "UNKNOWN"
        }
    }

    public var description: String {
        isDefined ? "\(name)" : "UNKNOWN(0x\(String(rawValue, radix: 16)))"
    }
}
