import Auth
import CryptoKit
import Foundation
import HTTPCore

/// Auth microbenchmarks (#0093). Select with `sws-bench micro --filter Auth`.
///
/// Each op is the authenticator's work for one request, without the next handler: the policy
/// lookup by path, and for covered paths the `Authorization` check. Bearer tokens are a
/// typical HS256 JWT (header with `kid`, five claims) and a static token; Basic is measured on
/// the verified-value cache (a full PBKDF2 at 600,000 iterations takes hundreds of
/// milliseconds by design and is listed separately at 1,000 iterations).
func registerAuthBenchmarks() {
    let now = Int64(time(nil))
    let secret = Array("bench-secret-bench-secret-bench-secret!!".utf8)
    let verifier = try! JWTVerifier(keys: [try! .init(id: "k1", secret: secret)], issuer: "https://issuer.example",
                                    audiences: ["api"], leeway: 60)
    let token = benchToken(
        header: #"{"alg":"HS256","typ":"JWT","kid":"k1"}"#,
        claims: #"{"sub":"user-1234","iss":"https://issuer.example","aud":"api","iat":\#(now),"exp":\#(now + 3600)}"#,
        secret: secret)
    let users = try! CredentialStore([("alice", PasswordHash.make(password: "wonderland", iterations: 1_000))])
    let fastUsers = try! CredentialStore([("alice", PasswordHash.make(password: "wonderland", iterations: 1_000))], cacheLifetime: 0)
    let auth = try! Authenticator(paths: ["/api", "/admin"], basic: users, jwt: verifier,
                                  tokens: [BearerToken(name: "ci", token: "static-ci-token-0123456789")])
    let fastAuth = try! Authenticator(paths: ["/admin"], basic: fastUsers, limiter: nil)
    let context = RequestContext(connection: ConnectionInfo(remoteAddress: TransportAddress(host: "127.0.0.1", port: 50_000)))

    func register(_ name: String, _ authenticator: Authenticator, _ path: String, _ authorization: String?) {
        let (storage, request) = authRequest(path, authorization)
        // Warm the Basic cache.
        if let index = authenticator.policy(for: request) { _ = authenticator.authenticate(request, context: context, policy: index) }
        Benchmark.register(name: name) {
            if let index = authenticator.policy(for: request) {
                blackHole(authenticator.authenticate(request, context: context, policy: index))
            } else {
                blackHole(0)
            }
        }
        blackHole(storage)
    }
    register("Auth outside every policy (pass-through)", auth, "/assets/app.js", nil)
    register("Auth Bearer JWT HS256 verify", auth, "/api/orders", "Bearer " + token)
    register("Auth Bearer static token", auth, "/api/orders", "Bearer static-ci-token-0123456789")
    register("Auth Basic (verified-value cache hit)", auth, "/admin", "Basic " + Data("alice:wonderland".utf8).base64EncodedString())
    register("Auth Basic PBKDF2 1,000 iterations (no cache)", fastAuth, "/admin", "Basic " + Data("alice:wonderland".utf8).base64EncodedString())
    register("Auth missing credentials (401)", auth, "/api/orders", nil)

    let tokenBytes = Array(token.utf8)
    Benchmark.register(name: "Auth JWTVerifier.verify only") {
        tokenBytes.withUnsafeBufferPointer { buffer in
            blackHole(try? verifier.verify(Span(_unsafeElements: buffer), from: 0, to: buffer.count, now: now))
        }
    }
}

private func benchToken(header: String, claims: String, secret: [UInt8]) -> String {
    func encode(_ bytes: some Sequence<UInt8>) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let input = encode(Array(header.utf8)) + "." + encode(Array(claims.utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: Array(input.utf8), using: SymmetricKey(data: secret))
    return input + "." + encode(Array(mac))
}

/// A `GET path` request with an optional `Authorization` field, in its own storage.
private func authRequest(_ path: String, _ authorization: String?) -> (HTTPRequestStorage, HTTPRequest) {
    let storage = HTTPRequestStorage(bufferCapacity: 1024, fieldCapacity: 4)
    func add(_ text: String) -> ByteView {
        let start = storage.buffer.writerIndex
        storage.buffer.append(contentsOf: Array(text.utf8))
        return ByteView(offset: start, length: text.utf8.count)
    }
    let pathView = add(path)
    if let authorization {
        let name = add("Authorization")
        storage.appendField(nameView: name, hash: ASCII.fnv1aLowercased("authorization"), valueView: add(authorization))
    }
    return (storage, HTTPRequest(method: .get, path: pathView, headers: storage.fieldsView))
}

/// `sws-bench hash-password --user NAME [--iterations N]`: reads a password from standard input
/// (first line) and prints a credential line for a `CredentialStore` / the `auth.basic` config.
enum HashPasswordCommand {
    static let usage = """
        usage: sws-bench hash-password --user NAME [--iterations N]

        Reads the password from the first line of standard input and prints
        NAME:$pbkdf2-sha256$ITERATIONS$SALT$KEY for an auth credential file (#0093).
        Default iterations: \(PasswordHash.defaultIterations).

          printf '%s\\n' "$PASSWORD" | sws-bench hash-password --user alice >> users.htpasswd
        """

    static func run(_ arguments: [String]) throws -> Int32 {
        var options = try Arguments(arguments, valueOptions: ["user", "iterations"])
        if options.flag("help") == true {
            print(usage)
            return 0
        }
        let iterations = try options.int("iterations") ?? PasswordHash.defaultIterations
        guard PasswordHash.iterationRange.contains(iterations) else {
            throw Arguments.Failure.invalidValue("iterations", String(iterations))
        }
        guard let user = options.string("user") else { throw Arguments.Failure.missingValue("user") }
        guard !user.isEmpty, !user.contains(":") else { throw Arguments.Failure.invalidValue("user", user) }
        try options.checkAllConsumed()
        guard let password = readLine(strippingNewline: true) else {
            printError("sws-bench hash-password: no password on standard input")
            return 2
        }
        print("\(user):\(PasswordHash.make(password: password, iterations: iterations))")
        return 0
    }
}
