import Auth
import Foundation
import HTTPCore
import Testing
@testable import ConfigFile

/// The `auth` key (#0093).
@Suite struct ConfigFileAuthTests {
    typealias Directory = ConfigFileTests.Directory

    func parse(_ json: String, base: String = ".") throws(ConfigFileError) -> ConfigFile {
        var defaults = ServerSettings()
        defaults.baseDirectory = base
        return try ConfigFile.parse(Data(json.utf8), source: "test.json", defaults: defaults)
    }

    static let hash = PasswordHash.make(password: "wonderland", iterations: 1_000).description

    @Test func parsesEveryKey() throws {
        let file = try parse("""
            {"auth": [{"paths": ["/admin", "/ops"], "realm": "Admin",
                       "basic": {"file": "users.htpasswd", "users": ["bob:\(Self.hash)"], "usersEnv": "USERS"},
                       "jwt": {"keys": [{"id": "k1", "secret": "s"}, {"secretEnv": "JWT_KEY"}],
                               "issuer": "https://issuer", "audience": ["api"], "leeway": 5, "requireExp": false},
                       "tokens": [{"name": "ci", "sha256": "\(String(repeating: "ab", count: 32))"}]},
                      {"basic": "other.htpasswd"}]}
            """)
        #expect(file.warnings.isEmpty)
        let first = file.settings.auth[0]
        #expect(first.paths == ["/admin", "/ops"])
        #expect(first.realm == "Admin")
        #expect(first.basicFile == "users.htpasswd")
        #expect(first.basicUsers.count == 1)
        #expect(first.basicUsersEnv == "USERS")
        #expect(first.jwtKeys == [.init(id: "k1", secret: .literal("s")), .init(id: nil, secret: .environment("JWT_KEY"))])
        #expect(first.jwtIssuer == "https://issuer")
        #expect(first.jwtAudiences == ["api"])
        #expect(first.jwtLeeway == 5)
        #expect(!first.jwtRequireExp)
        #expect(first.tokens.count == 1)
        #expect(file.settings.auth[1].basicFile == "other.htpasswd")
        #expect(file.settings.auth[1].paths == ["/"])
        // A single object works too.
        #expect(try parse(#"{"auth": {"paths": "/x", "basic": "u"}}"#).settings.auth.count == 1)
    }

    @Test(arguments: [
        #"{"auth": 1}"#,
        #"{"auth": [{"paths": ["/x"]}]}"#,
        #"{"auth": [{"paths": ["x"], "basic": "u"}]}"#,
        #"{"auth": [{"basic": {}}]}"#,
        #"{"auth": [{"jwt": {"keys": []}}]}"#,
        #"{"auth": [{"jwt": {"keys": [{"id": "a"}]}}]}"#,
        #"{"auth": [{"jwt": {"keys": [{"secret": "a", "secretEnv": "B"}]}}]}"#,
        #"{"auth": [{"tokens": [{"name": "ci", "token": "plaintext"}]}]}"#,
    ])
    func badAuthNamesTheKey(json: String) {
        do {
            _ = try parse(json)
            Issue.record("accepted \(json)")
        } catch {
            #expect(error.key?.hasPrefix("auth") == true, "\(json): \(error)")
        }
    }

    @Test(.timeLimit(.minutes(1))) func protectsConfiguredPaths() async throws {
        let directory = try Directory()
        try directory.write("public\n", to: "Public/index.html")
        try directory.write("secret\n", to: "Public/admin/index.html")
        try directory.write("# users\nalice:\(Self.hash)\n", to: "users.htpasswd")
        let file = try parse("""
            {"root": "Public", "auth": [{"paths": ["/admin"], "realm": "Admin", "basic": {"file": "users.htpasswd"}},
                                       {"paths": ["/api"], "jwt": {"keys": [{"secretEnv": "JWT_KEY"}]}}]}
            """, base: directory.path)
        let handler = try file.settings.makeHandler(environment: ["JWT_KEY": String(repeating: "k", count: 32)])
        func run(_ path: String, _ authorization: String? = nil) async throws -> HTTPResponse {
            let storage = HTTPRequestStorage(bufferCapacity: 512, fieldCapacity: 2)
            func add(_ text: String) -> ByteView {
                let start = storage.buffer.writerIndex
                storage.buffer.append(contentsOf: Array(text.utf8))
                return ByteView(offset: start, length: text.utf8.count)
            }
            let pathView = add(path)
            if let authorization {
                storage.appendField(nameView: add("authorization"), hash: ASCII.fnv1aLowercased("authorization"), valueView: add(authorization))
            }
            let request = HTTPRequest(method: .get, path: pathView, headers: storage.fieldsView)
            return try await handler.handle(request, context: RequestContext())
        }
        #expect(try await run("/").status == .ok)
        let refused = try await run("/admin/")
        #expect(refused.status == .unauthorized)
        #expect(refused.headers.firstValueString(for: .wwwAuthenticate) == #"Basic realm="Admin", charset="UTF-8""#)
        let basic = "Basic " + Data("alice:wonderland".utf8).base64EncodedString()
        #expect(try await run("/admin/", basic).status == .ok)
        #expect(try await run("/admin/", "Basic " + Data("alice:nope".utf8).base64EncodedString()).status == .unauthorized)
        #expect(try await run("/api/x").headers.firstValueString(for: .wwwAuthenticate) == #"Bearer realm="Restricted""#)
    }

    @Test func missingSecretsAndFilesNameTheKey() throws {
        let file = try parse(#"{"auth": [{"jwt": {"keys": [{"secretEnv": "NOPE"}]}}]}"#)
        #expect(throws: ConfigFileError.self) { _ = try file.settings.makeHandler(environment: [:]) }
        do { _ = try file.settings.makeHandler(environment: [:]) } catch { #expect(error.key == "auth[0].jwt.keys[0].secretEnv") }

        let short = try parse(#"{"auth": [{"jwt": {"keys": [{"secret": "short"}]}}]}"#)
        do { _ = try short.settings.makeHandler(); Issue.record("short key accepted") } catch { #expect(error.key == "auth[0].jwt.keys[0]") }

        let noFile = try parse(#"{"auth": [{"basic": "/nonexistent/users"}]}"#)
        do { _ = try noFile.settings.makeHandler(); Issue.record("missing file accepted") } catch { #expect(error.key == "auth[0].basic.file") }

        let plaintext = try parse(#"{"auth": [{"basic": {"users": ["alice:wonderland"]}}]}"#)
        do { _ = try plaintext.settings.makeHandler(); Issue.record("plaintext accepted") } catch { #expect(error.key == "auth[0].basic") }
    }
}
