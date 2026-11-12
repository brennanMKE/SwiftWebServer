import Foundation
import HTTPCore
import Testing
@testable import Auth

@Suite struct ConstantTimeTests {
    /// A byte collection that counts element reads, to check the comparison's structure: it
    /// must read every byte however early the inputs differ.
    final class Counter: @unchecked Sendable { var reads = 0 }

    struct CountingBytes: Collection {
        let bytes: [UInt8]
        let counter: Counter
        var startIndex: Int { 0 }
        var endIndex: Int { bytes.count }
        func index(after i: Int) -> Int { i + 1 }
        subscript(position: Int) -> UInt8 {
            counter.reads += 1
            return bytes[position]
        }
    }

    func reads(_ a: [UInt8], _ b: [UInt8]) -> (Bool, Int) {
        let counter = Counter()
        let result = ConstantTime.equals(CountingBytes(bytes: a, counter: counter), CountingBytes(bytes: b, counter: counter))
        return (result, counter.reads)
    }

    @Test func readsEveryByteWhereverTheInputsDiffer() {
        let secret = Array(repeating: UInt8(0x41), count: 32)
        var first = secret; first[0] ^= 1
        var last = secret; last[31] ^= 1
        let equal = reads(secret, secret)
        let early = reads(secret, first)
        let late = reads(secret, last)
        #expect(equal == (true, 64))
        #expect(early == (false, 64))
        #expect(late == (false, 64))
        // Different lengths: unequal, and still reads the longer input in full.
        #expect(reads(secret, Array(secret.prefix(31))) == (false, 63))
        #expect(reads([], []).0)
    }

    @Test func rawPointerForm() {
        let a: [UInt8] = [1, 2, 3, 4], b: [UInt8] = [1, 2, 3, 5]
        a.withUnsafeBytes { x in
            b.withUnsafeBytes { y in
                #expect(!ConstantTime.equals(x.baseAddress!, y.baseAddress!, count: 4))
                #expect(ConstantTime.equals(x.baseAddress!, y.baseAddress!, count: 3))
            }
        }
    }
}

@Suite struct PasswordHashTests {
    @Test func roundTripsAndVerifies() throws {
        let hash = PasswordHash.make(password: "correct horse", iterations: testIterations)
        let text = hash.description
        #expect(text.hasPrefix("$pbkdf2-sha256$1000$"))
        let parsed = try #require(PasswordHash(text))
        #expect(parsed == hash)
        #expect(Array("correct horse".utf8).withUnsafeBytes { parsed.verify(password: $0) })
        #expect(!Array("correct horse!".utf8).withUnsafeBytes { parsed.verify(password: $0) })
        #expect(![UInt8]().withUnsafeBytes { parsed.verify(password: $0) })
    }

    @Test func knownVector() throws {
        // RFC 7914 §11 PBKDF2-HMAC-SHA256 test vector: P="passwd", S="salt", c=1, dkLen=64
        // (first 32 bytes). Built directly since parsing requires ≥ 1,000 iterations.
        var key = [UInt8](repeating: 0, count: 32)
        Array("passwd".utf8).withUnsafeBytes { password in
            key.withUnsafeMutableBytes { PasswordHash.derive(password: password, salt: Array("salt".utf8), iterations: 1, into: $0) }
        }
        #expect(key.map { String(format: "%02x", $0) }.joined()
            == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
    }

    @Test func rejectsMalformed() {
        for text in ["secret", "$pbkdf2-sha256$", "$pbkdf2-sha256$10$AAAAAAAAAAA$AAAA", "$pbkdf2-sha1$1000$a$b",
                     "$pbkdf2-sha256$1000$c2FsdHNhbHQ$short"] {
            #expect(PasswordHash(text) == nil, "\(text)")
        }
    }

    @Test func credentialLinesRejectPlaintext() throws {
        let hash = PasswordHash.make(password: "pw", iterations: testIterations)
        let users = try CredentialStore(lines: "# users\n\nalice:\(hash)\r\n  bob:\(hash)  \n")
        #expect(users.names == ["alice", "bob"])
        #expect(throws: AuthConfigurationError.self) { try CredentialStore(lines: "alice:plaintext") }
        #expect(throws: AuthConfigurationError.self) { try CredentialStore(lines: "alice:\(hash)\nalice:\(hash)") }
        #expect(throws: AuthConfigurationError.self) { try CredentialStore(lines: "no-colon") }
    }
}

@Suite struct BasicAuthTests {
    let users: CredentialStore
    let auth: Authenticator

    init() throws {
        users = try store([("alice", "wonderland"), ("bob", "builder")])
        auth = try Authenticator(paths: ["/admin", "/api/private"], realm: "Admin \"area\"", basic: users)
    }

    @Test(.timeLimit(.minutes(1))) func success() async throws {
        let response = try await auth.run(AuthRequest("/admin/settings", authorization: basicHeader("alice", "wonderland")))
        #expect(response.status == .ok)
        #expect(response.headers.firstValueString(for: .server) == "basic:alice")
        let bob = try await auth.run(AuthRequest("/admin", authorization: "basic  " + Data("bob:builder".utf8).base64EncodedString() + " "))
        #expect(bob.headers.firstValueString(for: .server) == "basic:bob")
    }

    @Test(.timeLimit(.minutes(1))) func failures() async throws {
        let challenge = #"Basic realm="Admin \"area\"", charset="UTF-8""#
        for header in [nil, basicHeader("alice", "wrong"), basicHeader("mallory", "wonderland"),
                       basicHeader("alice", ""), "Basic !!!notbase64", "Basic " + Data("nocolon".utf8).base64EncodedString(),
                       "Digest username=\"alice\"", "Basic", "Bearer abc"] {
            let response = try await auth.run(AuthRequest("/admin", authorization: header), context: peerContext("10.9.9.\(Int.random(in: 1...250))"))
            #expect(response.status == .unauthorized, "\(header ?? "nil")")
            #expect(response.headers.firstValueString(for: .wwwAuthenticate) == challenge)
            #expect(response.headers.firstValueString(for: .server) == nil)
        }
    }

    @Test(.timeLimit(.minutes(1))) func scopeIsSegmentPrefixes() async throws {
        func status(_ path: String) async throws -> Int {
            Int(try await auth.run(AuthRequest(path)).status.code)
        }
        for open in ["/", "/index.html", "/administrator", "/api", "/api/public", "/adminx/y", "/api/private2"] {
            #expect(try await status(open) == 200, "\(open)")
        }
        for covered in ["/admin", "/admin/", "/admin/x", "/ADMIN/x", "/%61dmin/x", "/%41DMIN", "//admin", "/./admin",
                        "/x/../admin", "/api//private/k", "/api/private"] {
            #expect(try await status(covered) == 401, "\(covered)")
        }
    }

    @Test(.timeLimit(.minutes(1))) func verifiedValuesAreCached() async throws {
        let request = AuthRequest("/admin", authorization: basicHeader("alice", "wonderland"))
        #expect(try await auth.run(request).status == .ok)
        // The cache holds the value's digest: a lookup without PBKDF2 finds alice.
        let value = Array(Data("alice:wonderland".utf8).base64EncodedString().utf8)
        let key = value.withUnsafeBytes { users.cache!.digest($0) }
        #expect(users.cache!.lookup(key, now: Int64(time(nil))) == 0)
        // A wrong password is never cached.
        _ = try await auth.run(AuthRequest("/admin", authorization: basicHeader("alice", "nope")))
        let wrong = Array(Data("alice:nope".utf8).base64EncodedString().utf8).withUnsafeBytes { users.cache!.digest($0) }
        #expect(users.cache!.lookup(wrong, now: Int64(time(nil))) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func unknownUserCostsAPasswordHash() throws {
        // Structural: verify runs PBKDF2 for unknown users too (against the dummy hash with
        // the store's iteration count).
        #expect(users.dummy.iterations == testIterations)
        let none = Array("nobody".utf8).withUnsafeBytes { user in
            Array("pw".utf8).withUnsafeBytes { users.verify(user: user, password: $0) }
        }
        #expect(none == nil)
    }
}

@Suite struct RateLimitTests {
    @Test(.timeLimit(.minutes(1))) func blocksAPeerAfterRepeatedFailures() async throws {
        let clock = TestClock()
        let limiter = FailureLimiter(maximumFailures: 3, window: 60, capacity: 64)
        let auth = try Authenticator(paths: ["/"], basic: try store([("alice", "pw")]), limiter: limiter, clock: clock.clock)
        let attacker = peerContext("192.0.2.1"), other = peerContext("192.0.2.2")
        for _ in 0..<3 {
            #expect(try await auth.run(AuthRequest("/", authorization: basicHeader("alice", "x")), context: attacker).status == .unauthorized)
        }
        // Missing credentials are not failures; they still get the challenge.
        #expect(try await auth.run(AuthRequest("/"), context: other).status == .unauthorized)
        let blocked = try await auth.run(AuthRequest("/", authorization: basicHeader("alice", "pw")), context: attacker)
        #expect(blocked.status == .tooManyRequests)
        #expect(blocked.headers.firstValueString(for: .retryAfter) == "60")
        #expect(try await auth.run(AuthRequest("/", authorization: basicHeader("alice", "pw")), context: other).status == .ok)
        clock.advance(30)
        #expect(try await auth.run(AuthRequest("/", authorization: basicHeader("alice", "pw")), context: attacker).headers.firstValueString(for: .retryAfter) == "30")
        clock.advance(31)
        #expect(try await auth.run(AuthRequest("/", authorization: basicHeader("alice", "pw")), context: attacker).status == .ok)
    }

    @Test func tableIsBounded() {
        let limiter = FailureLimiter(maximumFailures: 2, window: 60, capacity: 100)
        #expect(limiter.capacity == 128)
        for i in 0..<10_000 { limiter.recordFailure(peer: "10.\(i / 65536).\(i / 256 % 256).\(i % 256)", now: 1) }
        #expect(limiter.buckets.withLock { $0.count } == 128)
    }
}

@Suite struct JWTTests {
    let now: Int64 = 1_800_000_000
    let verifier: JWTVerifier

    init() throws {
        verifier = try JWTVerifier(keys: [try .init(secret: jwtSecret)], issuer: "https://issuer.test",
                                   audiences: ["api", "admin"], leeway: 30)
    }

    func claims(exp: Int64? = nil, nbf: Int64? = nil, iss: String? = "https://issuer.test",
                aud: String? = #""api""#, sub: String? = "alice") -> String {
        var members: [String] = []
        if let sub { members.append(#""sub":"\#(sub)""#) }
        if let iss { members.append(#""iss":"\#(iss)""#) }
        if let aud { members.append(#""aud":\#(aud)"#) }
        members.append(#""exp":\#(exp ?? now + 300)"#)
        if let nbf { members.append(#""nbf":\#(nbf)"#) }
        return "{" + members.joined(separator: ",") + "}"
    }

    func verify(_ token: String) -> Result<JWTClaims, JWTError> {
        Result { () throws(JWTError) in try verifier.verify(token, now: now) }
    }

    @Test func valid() throws {
        let result = try verifier.verify(makeToken(claims: claims()), now: now)
        #expect(result.subject == "alice")
        #expect(result.expiresAt == now + 300)
        // Whitespace, unknown members, nested values, escapes and an audience array.
        let fancy = #"{ "sub" : "alïce", "iss":"https:\/\/issuer.test", "aud":["other","admin"], "exp":1800000100.5, "x":{"y":[1,2,{"z":null}]}, "ok":true }"#
        #expect(try verifier.verify(makeToken(claims: fancy), now: now).subject == "alïce")
    }

    @Test func expiry() {
        #expect(verify(makeToken(claims: claims(exp: now - 31))) == .failure(.expired))
        #expect(verify(makeToken(claims: claims(exp: now - 29))).isSuccess, "within the leeway")
        #expect(verify(makeToken(claims: #"{"sub":"a","iss":"https://issuer.test","aud":"api"}"#)) == .failure(.expired),
                "exp is required")
        let lenient = try! JWTVerifier(keys: [try! .init(secret: jwtSecret)], requiresExpiration: false)
        #expect(throws: Never.self) { try lenient.verify(makeToken(claims: #"{"sub":"a"}"#), now: now) }
    }

    @Test func notBefore() {
        #expect(verify(makeToken(claims: claims(nbf: now + 31))) == .failure(.notYetValid))
        #expect(verify(makeToken(claims: claims(nbf: now + 29))).isSuccess)
        #expect(verify(makeToken(claims: claims(nbf: now - 100))).isSuccess)
    }

    @Test func audienceAndIssuer() {
        #expect(verify(makeToken(claims: claims(aud: #""web""#))) == .failure(.audienceMismatch))
        #expect(verify(makeToken(claims: claims(aud: #"["web","mobile"]"#))) == .failure(.audienceMismatch))
        #expect(verify(makeToken(claims: claims(aud: #"["web","admin"]"#))).isSuccess)
        #expect(verify(makeToken(claims: claims(aud: nil))) == .failure(.audienceMismatch))
        #expect(verify(makeToken(claims: claims(aud: "7"))) == .failure(.malformed))
        #expect(verify(makeToken(claims: claims(iss: "https://evil.test"))) == .failure(.issuerMismatch))
        #expect(verify(makeToken(claims: claims(iss: nil))) == .failure(.issuerMismatch))
    }

    @Test func algorithmIsPinned() {
        // alg "none" with an empty or any signature.
        let none = makeToken(header: #"{"alg":"none","typ":"JWT"}"#, claims: claims(), signature: "")
        #expect(verify(none) == .failure(.malformed))
        let noneSigned = makeToken(header: #"{"alg":"none"}"#, claims: claims())
        #expect(verify(noneSigned) == .failure(.unsupportedAlgorithm))
        for alg in ["None", "NONE", "HS384", "HS512", "RS256", "ES256", "PS256", "hs256", ""] {
            #expect(verify(makeToken(header: #"{"alg":"\#(alg)"}"#, claims: claims())) == .failure(.unsupportedAlgorithm), "\(alg)")
        }
        // RS256 alg confusion: an attacker signs with HMAC using a "public key" as the secret.
        let confused = makeToken(header: #"{"alg":"RS256"}"#, claims: claims(), secret: Array("-----BEGIN PUBLIC KEY-----".utf8))
        #expect(verify(confused) == .failure(.unsupportedAlgorithm))
        #expect(verify(makeToken(header: #"{"typ":"JWT"}"#, claims: claims())) == .failure(.unsupportedAlgorithm))
        #expect(verify(makeToken(header: #"{"alg":"HS256","crit":["exp"]}"#, claims: claims())) == .failure(.unsupportedAlgorithm))
        #expect(verify(makeToken(header: #"{"alg":"HS256","alg":"none"}"#, claims: claims())) == .failure(.malformed))
    }

    @Test func tamperingIsDetected() {
        let token = makeToken(claims: claims())
        let parts = token.split(separator: ".").map(String.init)
        // Another payload under the original signature.
        let forged = parts[0] + "." + base64url(Array(claims(sub: "root").utf8)) + "." + parts[2]
        #expect(verify(forged) == .failure(.badSignature))
        // A flipped signature character, a truncated signature, a wrong key.
        var signature = Array(parts[2])
        signature[5] = signature[5] == "A" ? "B" : "A"
        #expect(verify(parts[0] + "." + parts[1] + "." + String(signature)) == .failure(.badSignature))
        #expect(!verify(parts[0] + "." + parts[1] + "." + String(parts[2].dropLast(4))).isSuccess)
        #expect(verify(makeToken(claims: claims(), secret: Array("another-secret-another-secret-0000".utf8))) == .failure(.badSignature))
    }

    @Test func malformed() {
        for token in ["", "abc", "a.b", "a.b.c.d", ".e30.sig", makeToken(claims: "[]"), makeToken(claims: "{"),
                      makeToken(claims: #"{"exp":"soon"}"#), makeToken(claims: #"{"sub":"a","sub":"b","exp":1900000000}"#),
                      makeToken(header: "not json", claims: claims()), "e30!.e30.e30",
                      String(repeating: "a", count: 9000) + ".e30.e30"] {
            if case .success = verify(token) { Issue.record("accepted \(token.prefix(40))") }
        }
    }

    @Test func keyIDsSelectKeys() throws {
        let second = Array("second-secret-second-secret-second-secret".utf8)
        let verifier = try JWTVerifier(keys: [try .init(id: "k1", secret: jwtSecret), try .init(id: "k2", secret: second)])
        let claims = #"{"sub":"a","exp":\#(now + 60)}"#
        #expect(try verifier.verify(makeToken(header: #"{"alg":"HS256","kid":"k2"}"#, claims: claims, secret: second), now: now).keyID == "k2")
        #expect(try verifier.verify(makeToken(header: #"{"alg":"HS256","kid":"k1"}"#, claims: claims), now: now).keyID == "k1")
        #expect(throws: JWTError.badSignature) {
            try verifier.verify(makeToken(header: #"{"alg":"HS256","kid":"k1"}"#, claims: claims, secret: second), now: now)
        }
        #expect(throws: JWTError.unknownKey) { try verifier.verify(makeToken(header: #"{"alg":"HS256","kid":"k3"}"#, claims: claims), now: now) }
        #expect(throws: JWTError.unknownKey) { try verifier.verify(makeToken(claims: claims), now: now) }
    }

    @Test func configuration() {
        #expect(throws: AuthConfigurationError.self) { try JWTVerifier.Key(secret: Array("short".utf8)) }
        #expect(throws: AuthConfigurationError.self) { try JWTVerifier(keys: []) }
        #expect(throws: AuthConfigurationError.self) {
            try JWTVerifier(keys: [try .init(id: "a", secret: jwtSecret), try .init(id: "a", secret: jwtSecret)])
        }
    }

    @Test(.timeLimit(.minutes(1))) func bearerThroughTheAuthenticator() async throws {
        let clock = TestClock(now)
        let auth = try Authenticator(paths: ["/api"], realm: "api", jwt: verifier,
                                     tokens: [BearerToken(name: "ci", token: "static-ci-token")], clock: clock.clock)
        let ok = try await auth.run(AuthRequest("/api/x", authorization: "Bearer " + makeToken(claims: claims())))
        #expect(ok.status == .ok)
        #expect(ok.headers.firstValueString(for: .server) == "jwt:alice")
        let ci = try await auth.run(AuthRequest("/api/x", authorization: "Bearer static-ci-token"))
        #expect(ci.headers.firstValueString(for: .server) == "token:ci")
        let bad = try await auth.run(AuthRequest("/api/x", authorization: "Bearer " + makeToken(claims: claims(exp: now - 100))))
        #expect(bad.status == .unauthorized)
        #expect(bad.headers.firstValueString(for: .wwwAuthenticate) == #"Bearer realm="api", error="invalid_token""#)
        let missing = try await auth.run(AuthRequest("/api/x"))
        #expect(missing.headers.firstValueString(for: .wwwAuthenticate) == #"Bearer realm="api""#)
        #expect(try await auth.run(AuthRequest("/api/x", authorization: "Bearer wrong")).status == .unauthorized)
        #expect(try await auth.run(AuthRequest("/api/x", authorization: basicHeader("a", "b"))).status == .unauthorized)
        // Static token digests from hex.
        let hex = BearerToken(name: "ci", token: "static-ci-token").digest.map { String(format: "%02x", $0) }.joined()
        #expect(try BearerToken(name: "ci", sha256: hex).digest == BearerToken(name: "ci", token: "static-ci-token").digest)
        #expect(throws: AuthConfigurationError.self) { try BearerToken(name: "x", sha256: "abc") }
    }
}

extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}
