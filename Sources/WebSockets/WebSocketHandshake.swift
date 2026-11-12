import CryptoKit
public import HTTPCore

/// The opening handshake of RFC 6455 §4.2 for HTTP/1.1, and its extended CONNECT form for
/// HTTP/2 and HTTP/3 (RFC 8441 §5, RFC 9220 §3), as pure functions over a request.
public enum WebSocketHandshake {
    /// Appended to the client's key before hashing (RFC 6455 §1.3).
    public static let guid: StaticString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Why a request is not an acceptable opening handshake, and how to answer it.
    public enum Failure: Error, Sendable, Hashable {
        /// Not a `GET`.
        case methodNotGET
        /// No `Upgrade: websocket`.
        case missingUpgrade
        /// No `upgrade` token in `Connection`.
        case missingConnectionUpgrade
        /// `Sec-WebSocket-Version` missing or not 13.
        case unsupportedVersion
        /// `Sec-WebSocket-Key` missing, repeated, or not the base64 of 16 bytes.
        case invalidKey
        /// An HTTP/1.0 request: `Upgrade` is ignored there (RFC 9110 §7.8) and an HTTP/1.0
        /// client must not get `101` (RFC 9110 §15.2); RFC 6455 §4.1 needs HTTP/1.1 (#0117).
        case unsupportedHTTPVersion
        /// A CONNECT that is not an extended CONNECT with `:protocol websocket`.
        case notWebSocketConnect

        /// The response status: 426 for a missing upgrade or an unsupported version (with
        /// the headers that say what is supported), 400 for the rest.
        public var status: HTTPStatus {
            switch self {
            case .missingUpgrade, .unsupportedVersion: .upgradeRequired
            case .methodNotGET, .missingConnectionUpgrade, .invalidKey, .unsupportedHTTPVersion, .notWebSocketConnect:
                .badRequest
            }
        }

        /// The error response, with `Sec-WebSocket-Version: 13` for a version mismatch and
        /// `Upgrade: websocket` with every 426 (RFC 9110 §15.5.22).
        public var response: HTTPResponse {
            var headers = HTTPFields()
            switch self {
            case .unsupportedVersion:
                headers.append(.secWebSocketVersion, "13")
                headers.append(.upgrade, "websocket")
                headers.append(.connection, "upgrade")
            case .missingUpgrade:
                headers.append(.upgrade, "websocket")
                headers.append(.connection, "upgrade")
            default:
                break
            }
            return HTTPResponse(status: status, headers: headers)
        }

        /// The error response to an extended CONNECT: `400`, with `Sec-WebSocket-Version: 13`
        /// for a version mismatch (HTTP/2 and HTTP/3 have no `Upgrade`, so no `426`).
        public var extendedConnectResponse: HTTPResponse {
            var headers = HTTPFields()
            if self == .unsupportedVersion { headers.append(.secWebSocketVersion, "13") }
            return HTTPResponse(status: .badRequest, headers: headers)
        }
    }

    /// True when the request asks for a WebSocket (`Upgrade: websocket`); whether it is a
    /// valid handshake is ``validate(_:)``'s job. Always false for HTTP/1.0, whose `Upgrade`
    /// field a server must ignore (RFC 9110 §7.8).
    public static func isUpgradeRequest(_ request: HTTPRequest) -> Bool {
        if request.method == .connect { return isExtendedConnect(request) }
        return request.version != .http1_0 && request.headers.containsListElement("websocket", in: .upgrade)
    }

    /// True for an extended CONNECT with `:protocol websocket` (RFC 8441 §4, RFC 9220 §3).
    public static func isExtendedConnect(_ request: HTTPRequest) -> Bool {
        request.method == .connect
            && request.withSpan(of: request.connectProtocol) { ASCII.equalsCaseInsensitive($0, "websocket") }
    }

    /// Checks an extended CONNECT opening handshake (RFC 8441 §5, RFC 9220 §3): `:protocol
    /// websocket` and `Sec-WebSocket-Version: 13`. There is no key and no accept value; the
    /// answer is `200`. `:scheme`, `:path` and `:authority` were required by the protocol's
    /// pseudo-header validation (``PseudoHeaderValidator``).
    public static func validateExtendedConnect(_ request: HTTPRequest) throws(Failure) {
        guard isExtendedConnect(request) else { throw .notWebSocketConnect }
        guard request.headers.count(of: .secWebSocketVersion) == 1,
              let version = request.headers.firstValue(for: .secWebSocketVersion),
              request.withSpan(of: version, { ASCII.equals($0, "13") }) else { throw .unsupportedVersion }
    }

    /// Checks the request line and fields of an opening handshake (RFC 6455 §4.2.1) and
    /// returns the `Sec-WebSocket-Accept` value. An HTTP/1.0 request is
    /// ``Failure/unsupportedHTTPVersion`` (`400`), never `101`.
    public static func validate(_ request: HTTPRequest) throws(Failure) -> String {
        guard request.version != .http1_0 else { throw .unsupportedHTTPVersion }
        guard request.method == .get else { throw .methodNotGET }
        guard isUpgradeRequest(request) else { throw .missingUpgrade }
        guard request.headers.containsListElement("upgrade", in: .connection) else { throw .missingConnectionUpgrade }
        guard request.headers.count(of: .secWebSocketVersion) == 1,
              let version = request.headers.firstValue(for: .secWebSocketVersion),
              request.withSpan(of: version, { ASCII.equals($0, "13") }) else { throw .unsupportedVersion }
        guard request.headers.count(of: .secWebSocketKey) == 1,
              let keyView = request.headers.firstValue(for: .secWebSocketKey) else { throw .invalidKey }
        let key = request.withSpan(of: keyView) { span in span.withUnsafeBufferPointer { Array($0) } }
        guard let decoded = Base64.decode(key), decoded.count == 16 else { throw .invalidKey }
        return acceptValue(forKey: key)
    }

    /// `base64(SHA-1(key + GUID))` (RFC 6455 §4.2.2 step 5.4), for the key bytes as sent.
    public static func acceptValue(forKey key: [UInt8]) -> String {
        var hasher = Insecure.SHA1()
        key.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        guid.withUTF8Buffer { hasher.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        return Base64.encode(Array(hasher.finalize()))
    }

    /// `acceptValue(forKey:)` for a key given as a string.
    public static func acceptValue(forKey key: String) -> String {
        acceptValue(forKey: Array(key.utf8))
    }

    /// The tokens of every `Sec-WebSocket-Protocol` field, in order.
    public static func offeredSubprotocols(_ request: HTTPRequest) -> [String] {
        var tokens: [String] = []
        request.headers.forEachListElement(of: .secWebSocketProtocol) { tokens.append(request.string(of: $0)) }
        return tokens
    }
}

/// Standard base64 (RFC 4648 §4) with padding, for the handshake's key and accept values.
enum Base64 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity((bytes.count + 2) / 3 * 4)
        var i = 0
        while i < bytes.count {
            let b0 = bytes[i]
            let b1 = i + 1 < bytes.count ? bytes[i + 1] : 0
            let b2 = i + 2 < bytes.count ? bytes[i + 2] : 0
            out.append(alphabet[Int(b0 >> 2)])
            out.append(alphabet[Int((b0 & 0x03) << 4 | b1 >> 4)])
            out.append(i + 1 < bytes.count ? alphabet[Int((b1 & 0x0F) << 2 | b2 >> 6)] : UInt8(ascii: "="))
            out.append(i + 2 < bytes.count ? alphabet[Int(b2 & 0x3F)] : UInt8(ascii: "="))
            i += 3
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func value(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): byte - UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"): byte - UInt8(ascii: "a") + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0") + 52
        case UInt8(ascii: "+"): 62
        case UInt8(ascii: "/"): 63
        default: nil
        }
    }

    /// Decodes padded base64; `nil` for any other input (wrong length, bad characters,
    /// misplaced padding, non-zero padding bits).
    static func decode(_ text: [UInt8]) -> [UInt8]? {
        guard text.count % 4 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(text.count / 4 * 3)
        var i = 0
        while i < text.count {
            let last = i + 4 == text.count
            let pad = (text[i + 3] == UInt8(ascii: "=") ? 1 : 0) + (text[i + 2] == UInt8(ascii: "=") ? 1 : 0)
            guard pad == 0 || last, !(text[i + 2] == UInt8(ascii: "=") && text[i + 3] != UInt8(ascii: "=")) else { return nil }
            guard let v0 = value(text[i]), let v1 = value(text[i + 1]) else { return nil }
            out.append(v0 << 2 | v1 >> 4)
            if pad == 2 {
                guard v1 & 0x0F == 0 else { return nil }
                break
            }
            guard let v2 = value(text[i + 2]) else { return nil }
            out.append(v1 << 4 | v2 >> 2)
            if pad == 1 {
                guard v2 & 0x03 == 0 else { return nil }
                break
            }
            guard let v3 = value(text[i + 3]) else { return nil }
            out.append(v2 << 6 | v3)
            i += 4
        }
        return out
    }
}
