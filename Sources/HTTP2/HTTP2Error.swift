/// An HTTP/2 protocol violation, classified by its scope (RFC 9113 §5.4).
///
/// Every error is either a connection error, answered with GOAWAY and closing the
/// connection, or a stream error, answered with RST_STREAM on that stream while the
/// connection carries on. Making the scope part of the type means a handler has to decide
/// which frame to send by matching the case; it cannot send RST_STREAM for a connection error.
///
/// `reason` is for logs only. It may describe internals and is never sent to the peer:
/// ``goawayDebugData`` is the only text that goes on the wire.
public enum HTTP2Error: Error, Sendable, Hashable, CustomStringConvertible {
    /// A connection error (RFC 9113 §5.4.1): send GOAWAY with `code`, then close.
    case connection(HTTP2ErrorCode, reason: String)
    /// A stream error (RFC 9113 §5.4.2): send RST_STREAM with `code` on the stream.
    case stream(HTTP2StreamID, HTTP2ErrorCode, reason: String)

    /// A stream-scoped error for `streamID`, escalated to a connection error when the
    /// stream is 0, which has no stream to reset.
    @inlinable
    public static func onStream(_ streamID: HTTP2StreamID, _ code: HTTP2ErrorCode, reason: String) -> HTTP2Error {
        streamID.isConnection ? .connection(code, reason: reason) : .stream(streamID, code, reason: reason)
    }

    /// The error code to send.
    @inlinable
    public var code: HTTP2ErrorCode {
        switch self {
        case .connection(let code, _), .stream(_, let code, _): code
        }
    }

    /// The stream to reset, or `nil` for a connection error.
    @inlinable
    public var streamID: HTTP2StreamID? {
        switch self {
        case .connection: nil
        case .stream(let id, _, _): id
        }
    }

    /// Whether the connection must be closed.
    @inlinable
    public var isConnectionError: Bool {
        if case .connection = self { return true }
        return false
    }

    /// The internal explanation, for logs only.
    public var reason: String {
        switch self {
        case .connection(_, let reason), .stream(_, _, let reason): reason
        }
    }

    /// The opaque debug data to put in GOAWAY (RFC 9113 §6.8): the error code's name and
    /// nothing else, so no internal detail reaches the client.
    @inlinable
    public var goawayDebugData: StaticString { code.name }

    public var description: String {
        switch self {
        case .connection(let code, let reason): "connection error \(code): \(reason)"
        case .stream(let id, let code, let reason): "stream \(id) error \(code): \(reason)"
        }
    }
}
