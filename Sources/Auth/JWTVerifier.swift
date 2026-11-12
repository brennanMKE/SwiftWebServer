/// Why a bearer token was refused.
public enum JWTError: Error, Sendable, Equatable {
    /// Not three base64url parts of JSON objects, a duplicate member, a claim of the wrong type,
    /// or longer than ``JWTVerifier/maximumTokenLength``.
    case malformed
    /// `alg` is not the pinned algorithm (`HS256`): `none`, `RS256`, `HS512`, …; or the header
    /// has `crit`.
    case unsupportedAlgorithm
    /// `kid` names no configured key (or there is no `kid` and no default key).
    case unknownKey
    /// The HMAC does not match.
    case badSignature
    /// `exp` has passed (beyond the leeway), or is missing when required.
    case expired
    /// `nbf` is in the future (beyond the leeway).
    case notYetValid
    /// `iss` is not the configured issuer.
    case issuerMismatch
    /// `aud` names none of the configured audiences.
    case audienceMismatch
}

/// The claims a verified token carried that the server uses.
public struct JWTClaims: Sendable, Equatable {
    /// `sub`, when present.
    public var subject: String?
    /// `exp`, seconds since 1970.
    public var expiresAt: Int64?
    /// `nbf`, seconds since 1970.
    public var notBefore: Int64?
    /// The `kid` of the key that verified the token, when it had one.
    public var keyID: String?
}

/// Verifies HMAC-SHA256 JSON Web Tokens (RFC 7519, JWS compact serialization RFC 7515), the
/// legacy TODO "HMAC validation for JWT tokens" (#0093).
///
/// - The algorithm is pinned to `HS256`: `none`, every other `alg` (`HS384`, `RS256`, …: the
///   algorithm-confusion attacks) and headers with `crit` are refused before any key is used.
/// - Keys are secrets of at least 32 bytes (RFC 7518 §3.2) from the config or the environment;
///   a header `kid` selects one, and a token without `kid` uses the key configured without an
///   id (or the only key).
/// - The signature is checked before the claims are read. `exp` is required (unless turned
///   off) and `exp`/`nbf` allow ``leeway`` seconds of clock skew; `iss` and `aud` are checked
///   when configured.
/// - Decoding happens in stack buffers; only `sub` becomes a `String`.
public struct JWTVerifier: Sendable {
    /// An HMAC key and its optional `kid`.
    public struct Key: Sendable {
        public let id: String?
        let idBytes: [UInt8]?
        let secret: [UInt8]

        /// `secret` must be at least 32 bytes.
        public init(id: String? = nil, secret: [UInt8]) throws(AuthConfigurationError) {
            guard secret.count >= 32 else {
                throw AuthConfigurationError("JWT key\(id.map { " \"\($0)\"" } ?? "") is \(secret.count) bytes; HS256 needs at least 32")
            }
            self.id = id
            self.idBytes = id.map { Array($0.utf8) }
            self.secret = secret
        }
    }

    public let keys: [Key]
    let defaultKey: Int
    /// Required `iss`, when set.
    public let issuer: String?
    let issuerBytes: [UInt8]?
    /// Accepted `aud` values; empty accepts tokens without checking `aud`.
    public let audiences: [String]
    let audienceBytes: [[UInt8]]
    /// Clock skew allowed for `exp` and `nbf`, seconds.
    public let leeway: Int64
    /// When true (the default), a token without `exp` is refused.
    public let requiresExpiration: Bool

    /// Longest token accepted.
    public static let maximumTokenLength = 8192

    public init(keys: [Key], issuer: String? = nil, audiences: [String] = [], leeway: Int64 = 60,
                requiresExpiration: Bool = true) throws(AuthConfigurationError) {
        guard !keys.isEmpty else { throw AuthConfigurationError("JWT verification needs at least one key") }
        var ids = Set<String>()
        for key in keys {
            guard ids.insert(key.id ?? "\u{0}").inserted else {
                throw AuthConfigurationError(key.id.map { "JWT key id \"\($0)\" is used twice" } ?? "more than one JWT key without an id")
            }
        }
        self.keys = keys
        defaultKey = keys.count == 1 ? 0 : (keys.firstIndex { $0.id == nil } ?? -1)
        self.issuer = issuer
        issuerBytes = issuer.map { Array($0.utf8) }
        self.audiences = audiences
        audienceBytes = audiences.map { Array($0.utf8) }
        self.leeway = leeway
        self.requiresExpiration = requiresExpiration
    }

    /// Verifies `token` at `now` (seconds since 1970).
    public func verify(_ token: String, now: Int64) throws(JWTError) -> JWTClaims {
        let bytes = Array(token.utf8)
        return try bytes.withUnsafeBufferPointer { (buffer) throws(JWTError) -> JWTClaims in
            try verify(Span(_unsafeElements: buffer), from: 0, to: buffer.count, now: now)
        }
    }

    /// Verifies the token `bytes[start..<end]` at `now`.
    public func verify(_ bytes: Span<UInt8>, from start: Int, to end: Int, now: Int64) throws(JWTError) -> JWTClaims {
        let length = end &- start
        guard length > 0, length <= Self.maximumTokenLength else { throw .malformed }
        var firstDot = -1, secondDot = -1
        for i in start..<end where bytes[i] == UInt8(ascii: ".") {
            if firstDot < 0 { firstDot = i } else if secondDot < 0 { secondDot = i } else { throw .malformed }
        }
        guard firstDot > start, secondDot > firstDot &+ 1, secondDot &+ 1 < end else { throw .malformed }

        // Header: alg pinned, kid selects the key.
        let keyIndex = try withDecoded(bytes, from: start, to: firstDot) { (header) throws(JWTError) -> Int in
            try selectKey(header: header)
        }
        let key = keys[keyIndex]

        // Signature over the ASCII "header.payload".
        try withDecoded(bytes, from: secondDot &+ 1, to: end) { (signature) throws(JWTError) -> Void in
            guard signature.count == 32 else { throw .badSignature }
            let valid = bytes.withUnsafeBufferPointer { buffer in
                let signed = UnsafeRawBufferPointer(start: buffer.baseAddress! + start, count: secondDot &- start)
                return withUnsafeTemporaryAllocation(byteCount: Digest.length, alignment: 8) { mac in
                    key.secret.withUnsafeBytes { Digest.hmacSHA256(key: $0, data: signed, into: mac) }
                    return ConstantTime.equals(mac.baseAddress!, signature.baseAddress!, count: Digest.length)
                }
            }
            guard valid else { throw .badSignature }
        }

        // Claims.
        var claims = try withDecoded(bytes, from: firstDot &+ 1, to: secondDot) { (payload) throws(JWTError) -> JWTClaims in
            try readClaims(payload, now: now)
        }
        claims.keyID = key.id
        return claims
    }

    // MARK: Steps

    /// Decodes base64url `bytes[start..<end]` into a stack buffer for `body`.
    private func withDecoded<R>(_ bytes: Span<UInt8>, from start: Int, to end: Int,
                                _ body: (UnsafeBufferPointer<UInt8>) throws(JWTError) -> R) throws(JWTError) -> R {
        let capacity = Base64.maximumDecodedLength(end &- start)
        let result: Result<R, JWTError> = withUnsafeTemporaryAllocation(byteCount: capacity, alignment: 1) { buffer in
            guard let count = Base64.decode(bytes, from: start, to: end, alphabet: .url, into: buffer) else {
                return .failure(.malformed)
            }
            let typed = buffer.bindMemory(to: UInt8.self)
            do throws(JWTError) {
                return .success(try body(UnsafeBufferPointer(rebasing: typed[0..<count])))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    private func selectKey(header: UnsafeBufferPointer<UInt8>) throws(JWTError) -> Int {
        var scanner = JSONScanner(header)
        var seen: UInt8 = 0
        var algorithmOK = false
        var refused = false
        var key = -2   // -2: no kid seen
        let keys = keys
        let wellFormed = scanner.forEachMember { name, value in
            let bit: UInt8
            if JSONScanner.string(name, in: header, equals: "alg") {
                bit = 1
                algorithmOK = JSONScanner.string(value, in: header, equals: "HS256")
            } else if JSONScanner.string(name, in: header, equals: "kid") {
                bit = 2
                guard value.kind == .string else { return false }
                key = keys.firstIndex { id in id.idBytes.map { JSONScanner.string(value, in: header, equals: $0) } ?? false } ?? -1
            } else if JSONScanner.string(name, in: header, equals: "crit") {
                bit = 4
                refused = true
            } else if JSONScanner.string(name, in: header, equals: "typ") {
                bit = 8
                guard value.kind == .string else { return false }
            } else {
                return true
            }
            guard seen & bit == 0 else { return false }
            seen |= bit
            return true
        }
        guard wellFormed else { throw .malformed }
        guard algorithmOK, !refused else { throw .unsupportedAlgorithm }
        if key == -2 { key = defaultKey }
        guard key >= 0 else { throw .unknownKey }
        return key
    }

    private func readClaims(_ payload: UnsafeBufferPointer<UInt8>, now: Int64) throws(JWTError) -> JWTClaims {
        var scanner = JSONScanner(payload)
        var seen: UInt8 = 0
        var expires: Int64?, notBefore: Int64?
        var issuerValue: JSONScanner.Value?, audienceValue: JSONScanner.Value?, subjectValue: JSONScanner.Value?
        let wellFormed = scanner.forEachMember { name, value in
            let bit: UInt8
            if JSONScanner.string(name, in: payload, equals: "exp") {
                bit = 1
                guard let seconds = JSONScanner.seconds(value, in: payload) else { return false }
                expires = seconds
            } else if JSONScanner.string(name, in: payload, equals: "nbf") {
                bit = 2
                guard let seconds = JSONScanner.seconds(value, in: payload) else { return false }
                notBefore = seconds
            } else if JSONScanner.string(name, in: payload, equals: "iss") {
                bit = 4
                guard value.kind == .string else { return false }
                issuerValue = value
            } else if JSONScanner.string(name, in: payload, equals: "aud") {
                bit = 8
                guard value.kind == .string || value.kind == .array else { return false }
                audienceValue = value
            } else if JSONScanner.string(name, in: payload, equals: "sub") {
                bit = 16
                guard value.kind == .string else { return false }
                subjectValue = value
            } else {
                return true
            }
            guard seen & bit == 0 else { return false }
            seen |= bit
            return true
        }
        guard wellFormed else { throw .malformed }

        if let expires {
            // RFC 7519 §4.1.4: the current time must be before exp.
            guard now < expires.addingReportingOverflow(leeway).partialValue else { throw .expired }
        } else if requiresExpiration {
            throw .expired
        }
        if let notBefore {
            guard now.addingReportingOverflow(leeway).partialValue >= notBefore else { throw .notYetValid }
        }
        if let issuerBytes {
            guard let issuerValue, JSONScanner.string(issuerValue, in: payload, equals: issuerBytes) else {
                throw .issuerMismatch
            }
        }
        if !audienceBytes.isEmpty {
            guard let audienceValue else { throw .audienceMismatch }
            let accepted = audienceBytes
            var matched = false
            if audienceValue.kind == .string {
                matched = accepted.contains { JSONScanner.string(audienceValue, in: payload, equals: $0) }
            } else {
                let ok = JSONScanner.forEachElement(of: audienceValue, in: payload) { element in
                    guard element.kind == .string else { return false }
                    if !matched { matched = accepted.contains { JSONScanner.string(element, in: payload, equals: $0) } }
                    return true
                }
                guard ok else { throw .malformed }
            }
            guard matched else { throw .audienceMismatch }
        }
        var claims = JWTClaims(subject: nil, expiresAt: expires, notBefore: notBefore, keyID: nil)
        if let subjectValue {
            guard let subject = JSONScanner.decodedString(subjectValue, in: payload) else { throw .malformed }
            claims.subject = subject
        }
        return claims
    }
}
