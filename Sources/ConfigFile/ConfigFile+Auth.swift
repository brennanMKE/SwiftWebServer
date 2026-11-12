import Auth
import Foundation

// The `auth` key (#0093): Basic and bearer-token authentication for path prefixes. Secrets come
// from the file or the environment, never a keychain.

extension ServerSettings {
    /// One protected area of the `auth` key.
    public struct AuthSettings: Sendable, Equatable {
        /// A secret given in the file or named by an environment variable.
        public enum Secret: Sendable, Equatable {
            case literal(String)
            case environment(String)
        }

        /// One JWT key.
        public struct JWTKey: Sendable, Equatable {
            public var id: String?
            public var secret: Secret
            public init(id: String? = nil, secret: Secret) {
                self.id = id
                self.secret = secret
            }
        }

        /// Path prefixes covered (whole segments). Default `["/"]`.
        public var paths = ["/"]
        /// Challenge realm. Default `"Restricted"`.
        public var realm = "Restricted"
        /// Credential file (`user:$pbkdf2-sha256$…` lines), relative to the config file.
        public var basicFile: String?
        /// Credential lines given in the file.
        public var basicUsers: [String] = []
        /// An environment variable holding credential lines.
        public var basicUsersEnv: String?
        /// JWT keys; empty turns JWT off.
        public var jwtKeys: [JWTKey] = []
        /// Required `iss`.
        public var jwtIssuer: String?
        /// Accepted `aud` values (any when empty).
        public var jwtAudiences: [String] = []
        /// Clock skew for `exp`/`nbf`, seconds. Default 60.
        public var jwtLeeway = 60
        /// Refuse tokens without `exp`. Default true.
        public var jwtRequireExp = true
        /// Static bearer tokens: name and hex SHA-256 of the token.
        public var tokens: [Token] = []

        public struct Token: Sendable, Equatable {
            public var name: String
            public var sha256: String
            public init(name: String, sha256: String) {
                self.name = name
                self.sha256 = sha256
            }
        }

        public init() {}

        var usesBasic: Bool { basicFile != nil || !basicUsers.isEmpty || basicUsersEnv != nil }
    }

    /// The `Authenticator` for ``auth``, or `nil` when there is none. Reads credential files
    /// and environment variables; throws naming the key when one is missing or invalid.
    func makeAuthenticator(environment: [String: String]) throws(ConfigFileError) -> Authenticator? {
        guard !auth.isEmpty else { return nil }
        var policies: [AuthPolicy] = []
        for (offset, area) in auth.enumerated() {
            let key = "auth[\(offset)]"
            func fail(_ path: String, _ message: String) -> ConfigFileError {
                ConfigFileError(key: "\(key)\(path)", "\"\(key)\(path)\": \(message)")
            }
            var store: CredentialStore?
            if area.usesBasic {
                var lines = area.basicUsers
                if let file = area.basicFile {
                    let path = Self.resolve(file, against: baseDirectory)
                    do {
                        lines += try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
                    } catch {
                        throw fail(".basic.file", "cannot read \(path): \(ConfigFile.reason(error))")
                    }
                }
                if let name = area.basicUsersEnv {
                    guard let value = environment[name] else { throw fail(".basic.usersEnv", "environment variable \(name) is not set") }
                    lines += value.split(whereSeparator: \.isNewline).map(String.init)
                }
                do {
                    store = try CredentialStore(lines: lines.joined(separator: "\n"))
                } catch {
                    throw fail(".basic", error.description)
                }
            }
            var verifier: JWTVerifier?
            if !area.jwtKeys.isEmpty {
                var keys: [JWTVerifier.Key] = []
                for (index, jwtKey) in area.jwtKeys.enumerated() {
                    let secret: String
                    switch jwtKey.secret {
                    case .literal(let text): secret = text
                    case .environment(let name):
                        guard let value = environment[name] else {
                            throw fail(".jwt.keys[\(index)].secretEnv", "environment variable \(name) is not set")
                        }
                        secret = value
                    }
                    do {
                        keys.append(try JWTVerifier.Key(id: jwtKey.id, secret: Array(secret.utf8)))
                    } catch {
                        throw fail(".jwt.keys[\(index)]", error.description)
                    }
                }
                do {
                    verifier = try JWTVerifier(keys: keys, issuer: area.jwtIssuer, audiences: area.jwtAudiences,
                                               leeway: Int64(area.jwtLeeway), requiresExpiration: area.jwtRequireExp)
                } catch {
                    throw fail(".jwt", error.description)
                }
            }
            var tokens: [BearerToken] = []
            for (index, token) in area.tokens.enumerated() {
                do {
                    tokens.append(try BearerToken(name: token.name, sha256: token.sha256))
                } catch {
                    throw fail(".tokens[\(index)]", error.description)
                }
            }
            do {
                policies.append(try AuthPolicy(paths: area.paths, realm: area.realm, basic: store, jwt: verifier, tokens: tokens))
            } catch {
                throw fail("", error.description)
            }
        }
        return Authenticator(policies)
    }
}

extension Parser {
    /// `"auth": [{"paths": ["/admin"], "realm": "Admin", "basic": {"file": "users.htpasswd"},
    /// "jwt": {"keys": [{"id": "k1", "secretEnv": "JWT_KEY"}], "issuer": "…", "audience": "api"},
    /// "tokens": [{"name": "ci", "sha256": "…"}]}]`; a single object is accepted too.
    mutating func auth(_ value: Any, _ key: String) throws(ConfigFileError) -> [ServerSettings.AuthSettings] {
        let elements: [Any]
        if let array = value as? [Any] { elements = array } else { elements = [try dictionary(value, key, expectation: "must be an object or an array of objects")] }
        var result: [ServerSettings.AuthSettings] = []
        for (offset, element) in elements.enumerated() {
            let path = value is [Any] ? "\(key)[\(offset)]" : key
            let object = try dictionary(element, path)
            var area = ServerSettings.AuthSettings()
            for name in object.keys.sorted() {
                let field = "\(path).\(name)"
                let item = object[name]!
                switch name {
                case "paths":
                    area.paths = item is String ? [try string(item, field)] : try strings(item, field)
                    guard !area.paths.isEmpty, area.paths.allSatisfy({ $0.hasPrefix("/") }) else {
                        throw fail(field, "must be path prefixes starting with \"/\"")
                    }
                case "realm":
                    area.realm = try string(item, field)
                case "basic":
                    try basic(item, field, into: &area)
                case "jwt":
                    try jwt(item, field, into: &area)
                case "tokens":
                    guard let array = item as? [Any] else { throw fail(field, "must be an array of {\"name\", \"sha256\"}") }
                    for (index, entry) in array.enumerated() {
                        let tokenPath = "\(field)[\(index)]"
                        let token = try dictionary(entry, tokenPath)
                        guard let name = token["name"], let digest = token["sha256"] else {
                            throw fail(tokenPath, "needs \"name\" and \"sha256\" (hex SHA-256 of the token; plaintext tokens are not accepted)")
                        }
                        area.tokens.append(.init(name: try string(name, "\(tokenPath).name"), sha256: try string(digest, "\(tokenPath).sha256")))
                    }
                default:
                    warn("unknown key \"\(field)\" ignored")
                }
            }
            guard area.usesBasic || !area.jwtKeys.isEmpty || !area.tokens.isEmpty else {
                throw fail(path, "needs \"basic\", \"jwt\" or \"tokens\"")
            }
            result.append(area)
        }
        return result
    }

    /// `"basic": {"file": "users.htpasswd", "users": ["alice:$pbkdf2-sha256$…"], "usersEnv": "VAR"}`,
    /// or a file name alone.
    mutating func basic(_ value: Any, _ key: String, into area: inout ServerSettings.AuthSettings) throws(ConfigFileError) {
        if value is String {
            area.basicFile = try string(value, key)
            return
        }
        let object = try dictionary(value, key, expectation: "must be a credential file name or {\"file\", \"users\", \"usersEnv\"}")
        for name in object.keys.sorted() {
            let field = "\(key).\(name)"
            switch name {
            case "file": area.basicFile = try string(object[name]!, field)
            case "users": area.basicUsers = try strings(object[name]!, field)
            case "usersEnv": area.basicUsersEnv = try string(object[name]!, field)
            default: warn("unknown key \"\(field)\" ignored")
            }
        }
        guard area.usesBasic else { throw fail(key, "needs \"file\", \"users\" or \"usersEnv\"") }
    }

    /// `"jwt": {"keys": [{"id": "k1", "secret": "…" | "secretEnv": "VAR"}], "issuer": "…",
    /// "audience": "api" | ["api"], "leeway": 60, "requireExp": true}`.
    mutating func jwt(_ value: Any, _ key: String, into area: inout ServerSettings.AuthSettings) throws(ConfigFileError) {
        let object = try dictionary(value, key)
        for name in object.keys.sorted() {
            let field = "\(key).\(name)"
            let item = object[name]!
            switch name {
            case "keys":
                guard let array = item as? [Any], !array.isEmpty else { throw fail(field, "must be a non-empty array of {\"secret\" or \"secretEnv\"}") }
                for (index, entry) in array.enumerated() {
                    let keyPath = "\(field)[\(index)]"
                    let keyObject = try dictionary(entry, keyPath)
                    let id = try keyObject["id"].map { (id) throws(ConfigFileError) in try string(id, "\(keyPath).id") }
                    let secret: ServerSettings.AuthSettings.Secret
                    switch (keyObject["secret"], keyObject["secretEnv"]) {
                    case (let text?, nil): secret = .literal(try string(text, "\(keyPath).secret"))
                    case (nil, let env?): secret = .environment(try string(env, "\(keyPath).secretEnv"))
                    default: throw fail(keyPath, "needs \"secret\" or \"secretEnv\" (not both)")
                    }
                    area.jwtKeys.append(.init(id: id, secret: secret))
                }
            case "issuer": area.jwtIssuer = try string(item, field)
            case "audience", "audiences": area.jwtAudiences = item is String ? [try string(item, field)] : try strings(item, field)
            case "leeway": area.jwtLeeway = try integer(item, field, in: 0...3600)
            case "requireExp": area.jwtRequireExp = try bool(item, field)
            default: warn("unknown key \"\(field)\" ignored")
            }
        }
        guard !area.jwtKeys.isEmpty else { throw fail("\(key).keys", "must list at least one key") }
    }
}
