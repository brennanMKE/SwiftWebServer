/// A WebSocket close status code (RFC 6455 §7.4).
///
/// Codes the connection checks: a code received in a Close frame must be one an endpoint may
/// send (``isValidOnTheWire``); anything else fails the connection with
/// ``protocolError`` (1002).
public struct WebSocketCloseCode: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public var rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// 1000: the purpose of the connection was fulfilled.
    public static let normalClosure = WebSocketCloseCode(rawValue: 1000)
    /// 1001: the endpoint is going away (server shutdown, page navigation).
    public static let goingAway = WebSocketCloseCode(rawValue: 1001)
    /// 1002: the peer violated the protocol.
    public static let protocolError = WebSocketCloseCode(rawValue: 1002)
    /// 1003: the endpoint cannot accept this data type.
    public static let unsupportedData = WebSocketCloseCode(rawValue: 1003)
    /// 1005: reserved; reported locally when a Close frame carried no code. Never sent.
    public static let noStatusReceived = WebSocketCloseCode(rawValue: 1005)
    /// 1006: reserved; reported locally when the connection ended without a Close frame.
    /// Never sent.
    public static let abnormalClosure = WebSocketCloseCode(rawValue: 1006)
    /// 1007: a text message (or close reason) was not valid UTF-8.
    public static let invalidFramePayloadData = WebSocketCloseCode(rawValue: 1007)
    /// 1008: a message violated the endpoint's policy.
    public static let policyViolation = WebSocketCloseCode(rawValue: 1008)
    /// 1009: a frame or message exceeded the endpoint's size limit.
    public static let messageTooBig = WebSocketCloseCode(rawValue: 1009)
    /// 1010: the client expected an extension the server did not negotiate.
    public static let mandatoryExtension = WebSocketCloseCode(rawValue: 1010)
    /// 1011: the server hit an unexpected condition.
    public static let internalServerError = WebSocketCloseCode(rawValue: 1011)
    /// 1012: the service is restarting (IANA registry).
    public static let serviceRestart = WebSocketCloseCode(rawValue: 1012)
    /// 1013: try again later (IANA registry).
    public static let tryAgainLater = WebSocketCloseCode(rawValue: 1013)
    /// 1014: bad gateway (IANA registry).
    public static let badGateway = WebSocketCloseCode(rawValue: 1014)
    /// 1015: reserved; TLS handshake failure, reported locally. Never sent.
    public static let tlsHandshake = WebSocketCloseCode(rawValue: 1015)

    /// True for codes an endpoint may put in a Close frame (RFC 6455 §7.4.1, §7.4.2 and the
    /// IANA registry): 1000–1003, 1007–1014, and 3000–4999 (registered and private use).
    /// 1004 is reserved, 1005, 1006 and 1015 are local-only, 1016–2999 are reserved for
    /// future RFCs, and anything below 1000 or above 4999 is invalid.
    public var isValidOnTheWire: Bool {
        switch rawValue {
        case 1000...1003, 1007...1014, 3000...4999: true
        default: false
        }
    }

    public var description: String { "\(rawValue)" }
}
