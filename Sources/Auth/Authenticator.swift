public import HTTPCore

/// Who a request authenticated as (#0093); set in ``RequestContext`` by ``Authenticator``.
public struct Principal: Sendable, Equatable {
    /// How the request authenticated.
    public enum Scheme: Sendable, Equatable {
        /// HTTP Basic against a ``CredentialStore``.
        case basic
        /// A JWT verified by a ``JWTVerifier``.
        case jwt
        /// A static bearer token (``BearerToken``).
        case token
    }

    /// The user name (Basic), the token's `sub` (JWT; empty without one), or the token's name.
    public let name: String
    public let scheme: Scheme
    /// The verified claims, for ``Scheme/jwt``.
    public let claims: JWTClaims?

    public init(name: String, scheme: Scheme, claims: JWTClaims? = nil) {
        self.name = name
        self.scheme = scheme
        self.claims = claims
    }
}

/// The ``RequestContext`` key of the authenticated ``Principal``.
public enum PrincipalKey: RequestContextKey {
    public static var defaultValue: Principal? { nil }
}

extension RequestContext {
    /// Who the request authenticated as, when an ``Authenticator`` admitted it.
    public var principal: Principal? { self[PrincipalKey.self] }
}

/// A static bearer token, stored as its SHA-256 digest (never in plaintext).
public struct BearerToken: Sendable {
    /// The principal name a request with this token gets.
    public let name: String
    let digest: [UInt8]

    /// A token known by the hex SHA-256 of its value (`printf %s TOKEN | shasum -a 256`).
    public init(name: String, sha256 hex: String) throws(AuthConfigurationError) {
        let bytes = Array(hex.utf8)
        guard bytes.count == 64 else { throw AuthConfigurationError("bearer token \"\(name)\": sha256 must be 64 hex digits") }
        var digest: [UInt8] = []
        var i = 0
        while i < 64 {
            guard let high = ASCII.hexDigitValue(bytes[i]), let low = ASCII.hexDigitValue(bytes[i + 1]) else {
                throw AuthConfigurationError("bearer token \"\(name)\": sha256 must be 64 hex digits")
            }
            digest.append(high << 4 | low)
            i += 2
        }
        self.name = name
        self.digest = digest
    }

    /// A token by its value (hashed here; for tests and generated tokens).
    public init(name: String, token: String) {
        self.name = name
        self.digest = Digest.sha256(Array(token.utf8))
    }
}

/// One protected area: the path prefixes it covers and the schemes it accepts.
public struct AuthPolicy: Sendable {
    /// Path prefixes, matched by whole segments (`/admin` covers `/admin` and `/admin/x`, not
    /// `/administrator`); `["/"]` covers everything.
    public let paths: [String]
    /// The `realm` of the challenges.
    public let realm: String
    /// HTTP Basic users, when Basic is accepted.
    public let basic: CredentialStore?
    /// JWT verification, when JWT bearer tokens are accepted.
    public let jwt: JWTVerifier?
    /// Static bearer tokens accepted.
    public let tokens: [BearerToken]

    /// Lowercased segments of each prefix (see ``ScopeTable``).
    let segments: [[[UInt8]]]
    /// `401` with the challenges for this policy's schemes.
    let challenge: HTTPResponse
    /// `401` for a refused bearer token (`error="invalid_token"`, RFC 6750 §3.1).
    let invalidToken: HTTPResponse

    public init(paths: [String] = ["/"], realm: String = "Restricted", basic: CredentialStore? = nil,
                jwt: JWTVerifier? = nil, tokens: [BearerToken] = []) throws(AuthConfigurationError) {
        guard basic != nil || jwt != nil || !tokens.isEmpty else {
            throw AuthConfigurationError("an auth policy needs \"basic\", \"jwt\" or \"tokens\"")
        }
        guard !paths.isEmpty else { throw AuthConfigurationError("an auth policy needs at least one path prefix") }
        var segments: [[[UInt8]]] = []
        for path in paths {
            guard path.hasPrefix("/") else { throw AuthConfigurationError("auth path \"\(path)\" must start with '/'") }
            segments.append(path.utf8.split(separator: UInt8(ascii: "/")).map { Array($0).map(ASCII.lowercased) })
        }
        guard !realm.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
            throw AuthConfigurationError("auth realm must not contain control characters")
        }
        self.paths = paths
        self.realm = realm
        self.basic = basic
        self.jwt = jwt
        self.tokens = tokens
        self.segments = segments
        let quoted = "\"" + realm.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
        func response(bearerError: Bool) -> HTTPResponse {
            var headers = HTTPFields()
            if basic != nil { headers.append(.wwwAuthenticate, string: "Basic realm=\(quoted), charset=\"UTF-8\"") }
            if jwt != nil || !tokens.isEmpty {
                headers.append(.wwwAuthenticate, string: "Bearer realm=\(quoted)" + (bearerError ? ", error=\"invalid_token\"" : ""))
            }
            headers.append(.cacheControl, "no-store")
            return HTTPResponse(status: .unauthorized, headers: headers)
        }
        challenge = response(bearerError: false)
        invalidToken = response(bearerError: true)
    }

}

/// Every policy's path prefixes, flattened for matching (built once by ``Authenticator``).
///
/// A path is covered by a prefix when its segments, percent-decoded and compared
/// case-insensitively (a case-insensitive file system serves `/ADMIN` as `/admin`), start with
/// the prefix's segments; empty and `.` segments are skipped, and any `..` segment puts the
/// request in scope. It errs on the side of protecting. Matching walks flat arrays and
/// does not allocate.
final class ScopeTable: Sendable {
    struct Segment {
        var start: Int32
        var length: Int32
    }

    struct Prefix {
        var segmentStart: Int32
        var segmentCount: Int32
        var policy: Int32
    }

    let bytes: [UInt8]
    let segments: [Segment]
    let prefixes: [Prefix]

    init(_ policies: [AuthPolicy]) {
        var bytes: [UInt8] = []
        var segments: [Segment] = []
        var prefixes: [Prefix] = []
        for (index, policy) in policies.enumerated() {
            for prefix in policy.segments {
                prefixes.append(Prefix(segmentStart: Int32(segments.count), segmentCount: Int32(prefix.count), policy: Int32(index)))
                for segment in prefix {
                    segments.append(Segment(start: Int32(bytes.count), length: Int32(segment.count)))
                    bytes.append(contentsOf: segment)
                }
            }
        }
        self.bytes = bytes
        self.segments = segments
        self.prefixes = prefixes
    }

    /// The policy of the first prefix covering `path` (still percent-encoded), or -1.
    func policy(for path: Span<UInt8>) -> Int {
        bytes.withUnsafeBufferPointer { bytes in
            segments.withUnsafeBufferPointer { segments in
                for prefix in prefixes where Self.matches(path, prefix, segments, bytes) { return Int(prefix.policy) }
                return -1
            }
        }
    }

    static func matches(_ path: Span<UInt8>, _ prefix: Prefix, _ segments: UnsafeBufferPointer<Segment>,
                        _ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let count = Int(prefix.segmentCount)
        if count == 0 { return true }
        var matched = 0
        var mismatch = false
        var i = 0
        let n = path.count
        while i < n {
            while i < n && path[i] == UInt8(ascii: "/") { i &+= 1 }
            if i >= n { break }
            var j = i
            while j < n && path[j] != UInt8(ascii: "/") { j &+= 1 }
            // Decode the segment [i, j) on the fly, comparing with the next prefix segment.
            var targetStart = 0, targetLength = 0
            if !mismatch && matched < count {
                let segment = segments[Int(prefix.segmentStart) &+ matched]
                targetStart = Int(segment.start)
                targetLength = Int(segment.length)
            }
            var length = 0
            var equal = true
            var dots = 0
            var k = i
            while k < j {
                var byte = path[k]
                if byte == UInt8(ascii: "%"), k &+ 2 < j,
                   let high = ASCII.hexDigitValue(path[k &+ 1]), let low = ASCII.hexDigitValue(path[k &+ 2]) {
                    byte = high << 4 | low
                    k &+= 3
                } else {
                    k &+= 1
                }
                if byte == UInt8(ascii: ".") { dots &+= 1 }
                equal = equal && length < targetLength && bytes[targetStart &+ length] == ASCII.lowercased(byte)
                length &+= 1
            }
            if dots == length && length == 2 { return true }       // ".." anywhere: protect
            if dots == length && length == 1 { i = j; continue }   // "."
            if !mismatch && matched < count {
                if equal && length == targetLength { matched &+= 1 } else { mismatch = true }
            }
            i = j
        }
        return !mismatch && matched == count
    }
}

/// Protects path prefixes with HTTP Basic or bearer tokens (#0093, docs/ROADMAP.md §5.2).
///
/// ```swift
/// let users = try CredentialStore(lines: try String(contentsOfFile: "users.htpasswd"))
/// let auth = try Authenticator(paths: ["/admin"], realm: "Admin", basic: users)
/// let server = Server(listeners: [listener], protocols: [HTTP1()]) {
///     auth
///     router
///     StaticFiles(root: publicURL)
/// }
/// ```
///
/// - A request under a policy's paths needs `Authorization`: `Basic` checked against the
///   ``CredentialStore`` (PBKDF2, constant-time compare), or `Bearer` checked as a JWT
///   (``JWTVerifier``) when it has two dots, else against the static ``BearerToken``s.
/// - Missing or wrong credentials get `401` with one `WWW-Authenticate` challenge per accepted
///   scheme (`Basic realm="…", charset="UTF-8"`, `Bearer realm="…"`).
/// - A peer with too many recent failures gets `429` with `Retry-After` before any hashing
///   (``FailureLimiter``).
/// - On success the ``Principal`` is set in the context (``RequestContext/principal``) and the
///   request goes on. The policies are tried in order; the first covering the path decides.
/// - Requests outside every policy pass through after one prefix check.
/// - Credentials are never logged or kept; `authorization` is a sensitive field that HPACK
///   sends as never-indexed.
///
/// With the ``Router`` (or any handler), protect single routes with ``protect(_:)``:
/// `GET("/me", handler: auth.protect(MeHandler()))`.
public struct Authenticator: HTTPMiddleware {
    public let policies: [AuthPolicy]
    public let limiter: FailureLimiter?
    let clock: AuthClock
    let scopes: ScopeTable

    public init(_ policies: [AuthPolicy], limiter: FailureLimiter? = FailureLimiter(), clock: AuthClock = .system) {
        self.policies = policies
        self.limiter = limiter
        self.clock = clock
        self.scopes = ScopeTable(policies)
    }

    /// One policy.
    public init(paths: [String] = ["/"], realm: String = "Restricted", basic: CredentialStore? = nil,
                jwt: JWTVerifier? = nil, tokens: [BearerToken] = [],
                limiter: FailureLimiter? = FailureLimiter(), clock: AuthClock = .system) throws(AuthConfigurationError) {
        self.init([try AuthPolicy(paths: paths, realm: realm, basic: basic, jwt: jwt, tokens: tokens)],
                  limiter: limiter, clock: clock)
    }

    /// The outcome of ``authenticate(_:context:policy:)``.
    public enum Outcome: Sendable {
        /// Admitted as this principal.
        case admitted(Principal)
        /// Refused; send this response.
        case refused(HTTPResponse)
    }

    /// The first policy covering `request`'s path, or `nil`.
    public func policy(for request: HTTPRequest) -> Int? {
        let scopes = scopes
        let index = request.withSpan(of: request.path) { scopes.policy(for: $0) }
        return index >= 0 ? index : nil
    }

    /// Checks `request`'s credentials against policy `index`.
    public func authenticate(_ request: HTTPRequest, context: RequestContext, policy index: Int) -> Outcome {
        let policy = policies[index]
        guard let header = request.headers.firstValue(for: .authorization) else { return .refused(policy.challenge) }
        let peer = context.connection.remoteAddress?.host
        let now = clock.now()
        if let limiter {
            let wait = limiter.retryAfter(peer: peer, now: now)
            if wait > 0 {
                var headers = HTTPFields()
                headers.append(.retryAfter, decimal: wait)
                return .refused(HTTPResponse(status: .tooManyRequests, headers: headers))
            }
        }
        let outcome = request.withSpan(of: header) { value in
            Self.check(value, policy: policy, now: now)
        }
        switch outcome {
        case .admitted:
            return outcome
        case .refused(let response):
            // A malformed or unsupported header (no credentials to guess with) is not counted.
            if response.status == .unauthorized, Self.presentedCredentials(request, header) {
                limiter?.recordFailure(peer: peer, now: now)
            }
            return outcome
        }
    }

    /// True when the header carries a Basic or Bearer credential (as opposed to another scheme).
    static func presentedCredentials(_ request: HTTPRequest, _ header: ByteView) -> Bool {
        request.withSpan(of: header) { value in
            let (scheme, start, end) = split(value)
            return start < end && (scheme == .basic || scheme == .bearer)
        }
    }

    enum SchemeName { case basic, bearer, other }

    /// The scheme and the credentials' range in `value`.
    static func split(_ value: Span<UInt8>) -> (SchemeName, Int, Int) {
        var i = 0, end = value.count
        while i < end && (value[i] == 0x20 || value[i] == 0x09) { i &+= 1 }
        while end > i && (value[end &- 1] == 0x20 || value[end &- 1] == 0x09) { end &-= 1 }
        let schemeStart = i
        while i < end && value[i] != 0x20 { i &+= 1 }
        let scheme = value.extracting(schemeStart..<i)
        while i < end && value[i] == 0x20 { i &+= 1 }
        if ASCII.equalsCaseInsensitive(scheme, "basic") { return (.basic, i, end) }
        if ASCII.equalsCaseInsensitive(scheme, "bearer") { return (.bearer, i, end) }
        return (.other, i, end)
    }

    static func check(_ value: Span<UInt8>, policy: AuthPolicy, now: Int64) -> Outcome {
        let (scheme, start, end) = split(value)
        guard start < end else { return .refused(policy.challenge) }
        switch scheme {
        case .basic:
            guard let store = policy.basic else { return .refused(policy.challenge) }
            return basic(value, from: start, to: end, store: store, policy: policy, now: now)
        case .bearer:
            return bearer(value, from: start, to: end, policy: policy, now: now)
        case .other:
            return .refused(policy.challenge)
        }
    }

    /// Longest decoded `user:password` accepted.
    static let maximumBasicLength = 1024

    static func basic(_ value: Span<UInt8>, from start: Int, to end: Int, store: CredentialStore,
                      policy: AuthPolicy, now: Int64) -> Outcome {
        guard end &- start <= (maximumBasicLength / 3 + 1) * 4 else { return .refused(policy.challenge) }
        // A recently verified value: one keyed hash instead of PBKDF2.
        let digest = store.cache.map { cache in
            value.withUnsafeBufferPointer { cache.digest(UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: $0[start..<end]))) }
        }
        if let digest, let user = store.cache?.lookup(digest, now: now) {
            return .admitted(Principal(name: store.name(at: user), scheme: .basic))
        }
        return withUnsafeTemporaryAllocation(byteCount: maximumBasicLength, alignment: 1) { buffer -> Outcome in
            defer { buffer.initializeMemory(as: UInt8.self, repeating: 0) }
            guard let count = Base64.decode(value, from: start, to: end, alphabet: .standard, into: buffer) else {
                return .refused(policy.challenge)
            }
            let decoded = UnsafeRawBufferPointer(rebasing: buffer[0..<count])
            guard let colon = decoded.firstIndex(of: UInt8(ascii: ":")) else { return .refused(policy.challenge) }
            let user = UnsafeRawBufferPointer(rebasing: decoded[0..<colon])
            let password = UnsafeRawBufferPointer(rebasing: decoded[(colon + 1)...])
            guard let index = store.verify(user: user, password: password) else { return .refused(policy.challenge) }
            if let digest, let cache = store.cache {
                cache.store(digest, user: index, expires: now + store.cacheLifetime)
            }
            return .admitted(Principal(name: store.name(at: index), scheme: .basic))
        }
    }

    static func bearer(_ value: Span<UInt8>, from start: Int, to end: Int, policy: AuthPolicy, now: Int64) -> Outcome {
        var dots = 0
        for i in start..<end where value[i] == UInt8(ascii: ".") { dots &+= 1 }
        if dots == 2, let jwt = policy.jwt {
            do {
                let claims = try jwt.verify(value, from: start, to: end, now: now)
                return .admitted(Principal(name: claims.subject ?? "", scheme: .jwt, claims: claims))
            } catch {
                return .refused(policy.invalidToken)
            }
        }
        guard !policy.tokens.isEmpty else { return .refused(policy.invalidToken) }
        var found = -1
        withUnsafeTemporaryAllocation(byteCount: Digest.length, alignment: 8) { digest in
            value.withUnsafeBufferPointer { Digest.sha256(UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: $0[start..<end])), into: digest) }
            // Compare with every token, so the time does not depend on which one matched.
            for (i, token) in policy.tokens.enumerated() {
                let equal = token.digest.withUnsafeBytes { ConstantTime.equals($0.baseAddress!, digest.baseAddress!, count: Digest.length) }
                if equal { found = i }
            }
        }
        guard found >= 0 else { return .refused(policy.invalidToken) }
        return .admitted(Principal(name: policy.tokens[found].name, scheme: .token))
    }

    // MARK: HTTPMiddleware

    /// Admits, refuses, or passes through a request outside every policy.
    public func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                          next: Next) async throws -> HTTPResponse {
        guard let index = policy(for: request) else {
            return try await next.handle(request, context: context)
        }
        switch authenticate(request, context: context, policy: index) {
        case .admitted(let principal):
            var context = context
            context[PrincipalKey.self] = principal
            return try await next.handle(request, context: context)
        case .refused(let response):
            return response
        }
    }

    /// `handler` behind policy `policy` (the first by default), whatever the path: for single
    /// routes of a ``Router``.
    public func protect<H: HTTPHandler>(_ handler: H, policy: Int = 0) -> Authenticated<H> {
        Authenticated(authenticator: self, policy: policy, handler: handler)
    }
}

/// A handler that runs only for authenticated requests (``Authenticator/protect(_:policy:)``).
public struct Authenticated<Handler: HTTPHandler>: HTTPHandler {
    public let authenticator: Authenticator
    public let policy: Int
    public let handler: Handler

    public func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        switch authenticator.authenticate(request, context: context, policy: policy) {
        case .admitted(let principal):
            var context = context
            context[PrincipalKey.self] = principal
            return try await handler.handle(request, context: context)
        case .refused(let response):
            return response
        }
    }
}
