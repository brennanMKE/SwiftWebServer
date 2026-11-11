/// Validates a decoded HTTP/2 or HTTP/3 field section (RFC 9113 §8.1.1–§8.3, RFC 9114
/// §4.1.2–§4.3, RFC 8441 §4 / RFC 9220 extended CONNECT).
///
/// Shared by HPACK/HTTP2 (#0047) and QPACK/HTTP3 (#0101) so that both protocols reject the
/// same malformed messages. It is a value-type state machine with no I/O: feed every field
/// in order to ``handle(name:value:)``, then call ``finish()``. The first violation is
/// returned; the caller maps it to a stream error (`PROTOCOL_ERROR` / `H3_MESSAGE_ERROR`).
///
/// The validator only checks; building the ``HTTPRequest`` (pseudo-header values into
/// method/scheme/authority/path, regular fields into an ``HTTPFieldIndex``) stays with the
/// protocol, which already holds the decoded bytes. #0047 and #0101 extend this type with the
/// remaining per-protocol rules (cookie crumb joining, `content-length` against DATA) and add
/// one test per rule.
public struct PseudoHeaderValidator: Sendable {
    /// Whether the field section is a request or a response head.
    public enum MessageKind: Sendable, Hashable {
        case request
        case response
    }

    /// Why a field section is malformed.
    public enum Violation: Error, Sendable, Hashable {
        /// A name starting with `:` that is not a defined pseudo-header.
        case unknownPseudoHeader
        /// A pseudo-header after the first regular field.
        case pseudoHeaderAfterRegularField
        /// The same pseudo-header twice.
        case duplicatePseudoHeader(HTTPFieldName)
        /// A pseudo-header that does not belong in this message kind (for example `:status`
        /// in a request).
        case pseudoHeaderNotAllowed(HTTPFieldName)
        /// A required pseudo-header is absent (`:authority` stands for "`:authority` or `host`").
        case missingPseudoHeader(HTTPFieldName)
        /// `:method` is not a token.
        case invalidMethod
        /// `:path` is empty.
        case emptyPath
        /// `:path` is `*` for a method other than OPTIONS.
        case asteriskPathRequiresOptions
        /// `:protocol` with a method other than CONNECT.
        case protocolRequiresConnect
        /// `:status` is not three digits.
        case invalidStatus
        /// A field name with uppercase letters or non-token bytes.
        case invalidFieldName
        /// A field value with CR, LF, NUL or surrounding whitespace.
        case invalidFieldValue
        /// A connection-specific field (`connection`, `keep-alive`, `proxy-connection`,
        /// `transfer-encoding`, `upgrade`).
        case connectionSpecificField(HTTPFieldName)
        /// `te` with a value other than `trailers`.
        case invalidTE
    }

    public let kind: MessageKind
    /// The parsed `:method`, once seen.
    public private(set) var method: HTTPMethod?
    @usableFromInline var seenPseudo: UInt8 = 0   // bit per pseudo-header ID offset
    @usableFromInline var sawRegularField = false
    @usableFromInline var sawHost = false
    @usableFromInline var pathIsAsterisk = false

    public init(kind: MessageKind) {
        self.kind = kind
    }

    /// True when the pseudo-header `name` has been seen.
    public func hasSeen(_ name: HTTPFieldName) -> Bool {
        guard name.isPseudoHeader else { return false }
        return seenPseudo & Self.bit(name) != 0
    }

    static func bit(_ name: HTTPFieldName) -> UInt8 {
        1 << (name.rawValue &- HTTPFieldName.pseudoAuthority.rawValue)
    }

    /// Checks one field in section order. Returns the first violation, or `nil`.
    public mutating func handle(name: Span<UInt8>, value: Span<UInt8>) -> Violation? {
        guard !name.isEmpty else { return .invalidFieldName }
        if name[0] == UInt8(ascii: ":") {
            return handlePseudoHeader(name: name, value: value)
        }
        sawRegularField = true
        for i in name.indices {
            let byte = name[i]
            guard ASCII.isTokenCharacter(byte), byte &- 0x41 >= 26 else { return .invalidFieldName }
        }
        guard Self.isValidValue(value) else { return .invalidFieldValue }
        let id = HTTPFieldName.lookup(name)
        switch id {
        case .connection, .keepAlive, .proxyConnection, .transferEncoding, .upgrade:
            return .connectionSpecificField(id)
        case .te:
            return ASCII.equals(value, "trailers") ? nil : .invalidTE
        case .host:
            sawHost = true
        default:
            break
        }
        return nil
    }

    mutating func handlePseudoHeader(name: Span<UInt8>, value: Span<UInt8>) -> Violation? {
        guard !sawRegularField else { return .pseudoHeaderAfterRegularField }
        // Pseudo-header names are lowercase on the wire, so match exactly.
        let id = HTTPFieldName.lookup(name)
        guard id.isPseudoHeader, ASCII.equals(name, id.canonicalName) else { return .unknownPseudoHeader }
        let bit = Self.bit(id)
        guard seenPseudo & bit == 0 else { return .duplicatePseudoHeader(id) }
        seenPseudo |= bit
        guard Self.isValidValue(value) else { return .invalidFieldValue }
        switch (kind, id) {
        case (.response, .pseudoStatus):
            guard value.count == 3, ASCII.isDigit(value[0]), ASCII.isDigit(value[1]), ASCII.isDigit(value[2])
            else { return .invalidStatus }
        case (.response, _), (.request, .pseudoStatus):
            return .pseudoHeaderNotAllowed(id)
        case (.request, .pseudoMethod):
            guard let method = HTTPMethod(value) else { return .invalidMethod }
            self.method = method
        case (.request, .pseudoPath):
            guard !value.isEmpty else { return .emptyPath }
            pathIsAsterisk = value.count == 1 && value[0] == UInt8(ascii: "*")
        default:
            break
        }
        return nil
    }

    /// Checks the rules that need the whole section (required pseudo-headers, CONNECT forms).
    public func finish() -> Violation? {
        switch kind {
        case .response:
            return hasSeen(.pseudoStatus) ? nil : .missingPseudoHeader(.pseudoStatus)
        case .request:
            guard let method else { return .missingPseudoHeader(.pseudoMethod) }
            let extendedConnect = hasSeen(.pseudoProtocol)
            if extendedConnect && method != .connect { return .protocolRequiresConnect }
            if method == .connect && !extendedConnect {
                // RFC 9113 §8.5: plain CONNECT has :authority only.
                guard hasSeen(.pseudoAuthority) else { return .missingPseudoHeader(.pseudoAuthority) }
                if hasSeen(.pseudoScheme) { return .pseudoHeaderNotAllowed(.pseudoScheme) }
                if hasSeen(.pseudoPath) { return .pseudoHeaderNotAllowed(.pseudoPath) }
                return nil
            }
            guard hasSeen(.pseudoScheme) else { return .missingPseudoHeader(.pseudoScheme) }
            guard hasSeen(.pseudoPath) else { return .missingPseudoHeader(.pseudoPath) }
            guard hasSeen(.pseudoAuthority) || (sawHost && !extendedConnect) else {
                return .missingPseudoHeader(.pseudoAuthority)
            }
            if pathIsAsterisk && method != .options { return .asteriskPathRequiresOptions }
            return nil
        }
    }

    /// RFC 9113 §8.2.1: no CR, LF or NUL, and no leading or trailing SP / HTAB.
    static func isValidValue(_ value: Span<UInt8>) -> Bool {
        if value.isEmpty { return true }
        let first = value[0]
        let last = value[value.count &- 1]
        if first == 0x20 || first == 0x09 || last == 0x20 || last == 0x09 { return false }
        for i in value.indices {
            let byte = value[i]
            if byte == 0x0D || byte == 0x0A || byte == 0x00 { return false }
        }
        return true
    }
}
