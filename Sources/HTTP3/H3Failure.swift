/// Everything the HTTP/3 runner can give up on, and the one place that decides how each is
/// signalled on the wire (RFC 9114 §8): a stream error abandons one stream with a code, a
/// connection error closes QUIC with a code (#0102).
///
/// | Failure | Scope | Wire | Code |
/// |---|---|---|---|
/// | ``malformedRequest`` | stream | RESET_STREAM + STOP_SENDING | `H3_MESSAGE_ERROR` |
/// | ``incompleteRequest`` | stream | RESET_STREAM + STOP_SENDING | `H3_REQUEST_INCOMPLETE` |
/// | ``unservableFieldSection`` | stream | RESET_STREAM + STOP_SENDING | `H3_MESSAGE_ERROR` |
/// | ``rejectedAfterGoaway`` | stream | RESET_STREAM + STOP_SENDING | `H3_REQUEST_REJECTED` |
/// | ``rejectedOverConcurrencyLimit`` | stream | RESET_STREAM + STOP_SENDING | `H3_REQUEST_REJECTED` |
/// | ``headerTimeout`` | stream | RESET_STREAM + STOP_SENDING | `H3_REQUEST_REJECTED` |
/// | ``bodyTimeout`` | stream | RESET_STREAM + STOP_SENDING | `H3_REQUEST_CANCELLED` |
/// | ``requestCancelled`` | stream | RESET_STREAM + STOP_SENDING | `H3_REQUEST_CANCELLED` |
/// | ``sendTimeout`` | stream | RESET_STREAM + STOP_SENDING | `H3_REQUEST_CANCELLED` |
/// | ``responseFailed`` | stream | RESET_STREAM | `H3_INTERNAL_ERROR` |
/// | ``unreadBodyAbandoned`` | stream | STOP_SENDING | `H3_NO_ERROR` |
/// | ``unknownStreamType`` | stream | STOP_SENDING | `H3_STREAM_CREATION_ERROR` |
/// | ``protocolViolation(_:)`` | connection | CONNECTION_CLOSE | its `H3_*` code |
/// | ``qpackFailure(code:)`` | connection | CONNECTION_CLOSE | its `QPACK_*` code |
/// | ``localStreamFailure`` | connection | CONNECTION_CLOSE | `H3_INTERNAL_ERROR` |
/// | ``excessiveLoad(_:)`` | connection | CONNECTION_CLOSE | `H3_EXCESSIVE_LOAD` |
/// | ``gracefulShutdown`` | connection | CONNECTION_CLOSE | `H3_NO_ERROR` |
/// | ``idleTimeout`` | connection | CONNECTION_CLOSE | `H3_NO_ERROR` |
/// | ``drainTimeout`` | connection | CONNECTION_CLOSE | `H3_NO_ERROR` |
///
/// Network.framework has no STOP_SENDING of its own: there, STOP_SENDING resets the whole
/// stream (docs/notes/nw-transport.md), so ``unreadBodyAbandoned`` is used only after the
/// response is complete and the drain bounds (``H3Configuration/maxUnreadBodySize``,
/// ``H3Timeouts/unreadBody``) have passed.
public enum H3Failure: Sendable, Hashable {
    // MARK: Stream errors

    /// A request that violates RFC 9114 §4.1.2 (pseudo-header rules, `content-length`
    /// mismatch, trailers with pseudo-header fields).
    case malformedRequest
    /// The stream ended before a complete request (§4.1).
    case incompleteRequest
    /// The field section exceeds `SETTINGS_MAX_FIELD_SECTION_SIZE` before its pseudo-header
    /// fields made a valid request, so there is nothing to answer `431` to.
    case unservableFieldSection
    /// A request stream at or above the GOAWAY ID we sent (§5.2): not processed, safe to retry.
    case rejectedAfterGoaway
    /// A request stream beyond ``H3Configuration/maxConcurrentRequestStreams`` (possible when
    /// the transport granted more stream credit than the limit).
    case rejectedOverConcurrencyLimit
    /// The request's HEADERS did not arrive within ``H3Timeouts/header``. Nothing was processed.
    case headerTimeout
    /// The handler waited longer than ``H3Timeouts/body`` for body bytes after its response had
    /// started (before that, the answer is `408`).
    case bodyTimeout
    /// The handler was cancelled (or threw `CancellationError`), or the peer abandoned the
    /// request (RESET_STREAM or STOP_SENDING) before its response was complete (#0104).
    case requestCancelled
    /// One response send waited longer than ``H3Timeouts/send``: a client that does not read
    /// (#0104).
    case sendTimeout
    /// The response failed after its head was sent (a `.stream` writer or file read threw).
    case responseFailed
    /// The response is complete but the request body is not; it is no longer read (§4.1.1).
    case unreadBodyAbandoned
    /// A reserved or unknown unidirectional stream type (§6.2).
    case unknownStreamType

    // MARK: Connection errors

    /// A frame, settings, stream-type or ID error found by the parsers and state machines.
    case protocolViolation(HTTP3Error)
    /// A QPACK error (`QPACK_DECOMPRESSION_FAILED`, `QPACK_ENCODER_STREAM_ERROR`, ...).
    case qpackFailure(code: UInt64)
    /// Our control or QPACK streams could not be opened.
    case localStreamFailure
    /// The peer went over one of the ``H3AbuseLimits`` (#0104).
    case excessiveLoad(H3AbuseKind)
    /// The drain after GOAWAY finished.
    case gracefulShutdown
    /// The connection had no request stream for ``H3Timeouts/idle``.
    case idleTimeout
    /// In-flight requests were still running when ``H3Timeouts/drain`` passed after GOAWAY.
    case drainTimeout

    /// How the failure is signalled.
    public enum Signal: Sendable, Hashable {
        /// RESET_STREAM and STOP_SENDING with `code`: abandon both directions of the stream.
        case resetStream(code: UInt64)
        /// RESET_STREAM only: abandon the response, keep reading nothing more either.
        case resetSending(code: UInt64)
        /// STOP_SENDING only: stop reading the request (the response already ended).
        case stopSending(code: UInt64)
        /// CONNECTION_CLOSE with `code`: every stream ends.
        case closeConnection(code: UInt64)

        /// The application error code on the wire.
        public var code: UInt64 {
            switch self {
            case .resetStream(let code), .resetSending(let code), .stopSending(let code), .closeConnection(let code):
                code
            }
        }

        /// True for a connection error.
        public var isConnectionError: Bool {
            if case .closeConnection = self { return true }
            return false
        }
    }

    /// The table: how this failure is signalled, and with which code.
    public var signal: Signal {
        switch self {
        case .malformedRequest, .unservableFieldSection:
            .resetStream(code: HTTP3Error.messageError.rawValue)
        case .incompleteRequest:
            .resetStream(code: HTTP3Error.requestIncomplete.rawValue)
        case .rejectedAfterGoaway, .rejectedOverConcurrencyLimit, .headerTimeout:
            .resetStream(code: HTTP3Error.requestRejected.rawValue)
        case .bodyTimeout, .requestCancelled, .sendTimeout:
            .resetStream(code: HTTP3Error.requestCancelled.rawValue)
        case .responseFailed:
            .resetSending(code: HTTP3Error.internalError.rawValue)
        case .unreadBodyAbandoned:
            .stopSending(code: HTTP3Error.noError.rawValue)
        case .unknownStreamType:
            .stopSending(code: HTTP3Error.streamCreationError.rawValue)
        case .protocolViolation(let error):
            .closeConnection(code: error.rawValue)
        case .qpackFailure(let code):
            .closeConnection(code: code)
        case .localStreamFailure:
            .closeConnection(code: HTTP3Error.internalError.rawValue)
        case .excessiveLoad:
            .closeConnection(code: HTTP3Error.excessiveLoad.rawValue)
        case .gracefulShutdown, .idleTimeout, .drainTimeout:
            .closeConnection(code: HTTP3Error.noError.rawValue)
        }
    }

    /// The failure for a stream error reported by ``H3RequestStream``.
    public init(streamError: HTTP3Error) {
        self = streamError == .requestIncomplete ? .incompleteRequest : .malformedRequest
    }

    /// The failure for a connection error code from a parser or state machine: an `H3_*` code
    /// is a protocol violation, anything else (`QPACK_*`) a QPACK failure.
    public init(connectionErrorCode code: UInt64) {
        if let error = HTTP3Error(rawValue: code) {
            self = .protocolViolation(error)
        } else {
            self = .qpackFailure(code: code)
        }
    }
}
