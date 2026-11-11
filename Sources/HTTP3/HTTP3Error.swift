/// HTTP/3 error codes (RFC 9114 §8.1), with their wire values.
///
/// These are the codes carried in QUIC `RESET_STREAM`, `STOP_SENDING` and
/// `CONNECTION_CLOSE` frames. Codecs in this target throw them directly.
public enum HTTP3Error: UInt64, Error, Sendable, CaseIterable {
    /// No error. Used when closing the connection or a stream with nothing wrong.
    case noError = 0x0100
    /// A protocol violation that no more specific code covers.
    case generalProtocolError = 0x0101
    /// An internal error in the HTTP stack.
    case internalError = 0x0102
    /// The peer created a stream that is not allowed.
    case streamCreationError = 0x0103
    /// A stream the connection needs was closed or reset.
    case closedCriticalStream = 0x0104
    /// A frame was not permitted in the current state or on the current stream.
    case frameUnexpected = 0x0105
    /// A frame does not satisfy its layout requirements or has an invalid size.
    case frameError = 0x0106
    /// The peer is generating excessive load.
    case excessiveLoad = 0x0107
    /// A stream ID or push ID was used incorrectly.
    case idError = 0x0108
    /// A SETTINGS frame has an error in its payload.
    case settingsError = 0x0109
    /// No SETTINGS frame started the control stream.
    case missingSettings = 0x010a
    /// The server rejected the request without doing any application processing.
    case requestRejected = 0x010b
    /// The request or its response was cancelled.
    case requestCancelled = 0x010c
    /// The client's stream ended without a fully formed request.
    case requestIncomplete = 0x010d
    /// An HTTP message was malformed.
    case messageError = 0x010e
    /// The TCP connection for a CONNECT request was reset or closed abnormally.
    case connectError = 0x010f
    /// The request is not served over HTTP/3. The peer should retry over HTTP/1.1.
    case versionFallback = 0x0110

    /// The code's name as RFC 9114 writes it, such as `H3_FRAME_UNEXPECTED`.
    public var name: StaticString {
        switch self {
        case .noError: "H3_NO_ERROR"
        case .generalProtocolError: "H3_GENERAL_PROTOCOL_ERROR"
        case .internalError: "H3_INTERNAL_ERROR"
        case .streamCreationError: "H3_STREAM_CREATION_ERROR"
        case .closedCriticalStream: "H3_CLOSED_CRITICAL_STREAM"
        case .frameUnexpected: "H3_FRAME_UNEXPECTED"
        case .frameError: "H3_FRAME_ERROR"
        case .excessiveLoad: "H3_EXCESSIVE_LOAD"
        case .idError: "H3_ID_ERROR"
        case .settingsError: "H3_SETTINGS_ERROR"
        case .missingSettings: "H3_MISSING_SETTINGS"
        case .requestRejected: "H3_REQUEST_REJECTED"
        case .requestCancelled: "H3_REQUEST_CANCELLED"
        case .requestIncomplete: "H3_REQUEST_INCOMPLETE"
        case .messageError: "H3_MESSAGE_ERROR"
        case .connectError: "H3_CONNECT_ERROR"
        case .versionFallback: "H3_VERSION_FALLBACK"
        }
    }

    /// Whether `code` is a reserved (GREASE) error code, 0x1f·N + 0x21 (RFC 9114 §8.1).
    /// They carry no meaning; peers send them to exercise handling of unknown codes.
    public static func isReserved(_ code: UInt64) -> Bool {
        isReservedCodePoint(code)
    }
}

/// The name issue #0096 and ROADMAP use for ``HTTP3Error``.
public typealias H3ErrorCode = HTTP3Error

/// Whether `value` is of the form 0x1f·N + 0x21. HTTP/3 reserves these for frame types,
/// stream types, setting identifiers and error codes (RFC 9114 §§6.2.3, 7.2.8, 7.2.4.1, 8.1).
@inlinable
func isReservedCodePoint(_ value: UInt64) -> Bool {
    value >= 0x21 && (value - 0x21) % 0x1f == 0
}
