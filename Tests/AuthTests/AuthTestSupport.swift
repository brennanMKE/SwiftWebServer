import CryptoKit
import Foundation
import HTTPCore
import Synchronization
@testable import Auth

/// A request built the way a connection builds one: path and fields in request storage.
struct AuthRequest {
    let storage: HTTPRequestStorage
    let request: HTTPRequest

    init(_ path: String, authorization: String? = nil, method: HTTPMethod = .get) {
        let storage = HTTPRequestStorage(bufferCapacity: 1024, fieldCapacity: 4)
        self.storage = storage
        storage.buffer.append(contentsOf: Array("GARBAGE ".utf8))
        func add(_ text: String) -> ByteView {
            let start = storage.buffer.writerIndex
            storage.buffer.append(contentsOf: Array(text.utf8))
            return ByteView(offset: start, length: storage.buffer.writerIndex - start)
        }
        let pathView = add(path)
        if let authorization {
            let name = add("Authorization")
            storage.appendField(nameView: name, hash: ASCII.fnv1aLowercased("authorization"), valueView: add(authorization))
        }
        request = HTTPRequest(method: method, path: pathView, headers: storage.fieldsView)
    }
}

/// A clock the test moves.
final class TestClock: Sendable {
    let seconds: Mutex<Int64>
    init(_ start: Int64 = 1_800_000_000) { seconds = Mutex(start) }
    func advance(_ by: Int64) { seconds.withLock { $0 += by } }
    var now: Int64 { seconds.withLock { $0 } }
    var clock: AuthClock { AuthClock { [self] in self.now } }
}

/// Answers `200` with the principal's name in `x-principal` (as `Server` here) and its scheme.
struct Echo: HTTPHandler {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        var headers = HTTPFields()
        if let principal = context.principal {
            headers.append(.server, string: "\(principal.scheme):\(principal.name)")
        }
        return HTTPResponse(status: .ok, headers: headers)
    }
}

/// A context for a request from `peer`.
func peerContext(_ peer: String = "10.0.0.1") -> RequestContext {
    RequestContext(connection: ConnectionInfo(remoteAddress: TransportAddress(host: peer, port: 50_000)))
}

func basicHeader(_ user: String, _ password: String) -> String {
    "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
}

/// Fast hashes for tests (production default is 600,000 iterations).
let testIterations = 1_000

func store(_ users: [(String, String)], cacheLifetime: Int64 = 300) throws -> CredentialStore {
    try CredentialStore(users.map { ($0.0, PasswordHash.make(password: $0.1, iterations: testIterations)) },
                        cacheLifetime: cacheLifetime)
}

// MARK: JWT

let jwtSecret = Array("0123456789abcdef0123456789abcdef-test-secret".utf8)

func base64url(_ bytes: some Sequence<UInt8>) -> String {
    Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// A compact JWS of `header` and `claims` (raw JSON text), signed with HMAC-SHA256 under
/// `secret` (or with `signature` verbatim).
func makeToken(header: String = #"{"alg":"HS256","typ":"JWT"}"#, claims: String,
               secret: [UInt8] = jwtSecret, signature: String? = nil) -> String {
    let signingInput = base64url(Array(header.utf8)) + "." + base64url(Array(claims.utf8))
    if let signature { return signingInput + "." + signature }
    let mac = HMAC<SHA256>.authenticationCode(for: Array(signingInput.utf8), using: SymmetricKey(data: secret))
    return signingInput + "." + base64url(Array(mac))
}

extension Authenticator {
    /// Runs `request` through the authenticator in front of ``Echo``.
    func run(_ request: AuthRequest, context: RequestContext = peerContext()) async throws -> HTTPResponse {
        try await handle(request.request, context: context, next: Echo())
    }
}
