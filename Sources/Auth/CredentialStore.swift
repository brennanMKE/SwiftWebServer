#if canImport(Darwin)
import Darwin
#endif
import Synchronization

/// Why an auth configuration could not be used.
public struct AuthConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Users and their salted password hashes for HTTP Basic (#0093). Plaintext passwords are
/// never stored or accepted.
///
/// Text form (a credential file, or lines in the config): one `user:hash` per line, where
/// `hash` is a ``PasswordHash`` (`$pbkdf2-sha256$…`); blank lines and `#` comments are
/// skipped. Generate a line with `sws-bench hash-password --user NAME` (the password is read
/// from standard input).
///
/// Verification derives the key with PBKDF2 (hundreds of milliseconds at 600,000
/// iterations, by design), so a successful `Authorization` value is remembered for
/// ``cacheLifetime`` seconds in a small table keyed by a per-process keyed SHA-256 of the value:
/// repeat requests cost one hash. An unknown user is verified against a dummy hash so it takes
/// as long as a wrong password.
public struct CredentialStore: Sendable {
    struct User {
        let name: String
        let bytes: [UInt8]
        let fingerprint: UInt32
        let hash: PasswordHash
    }

    let users: [User]
    let dummy: PasswordHash
    let cache: VerifiedCache?

    /// How long a verified `Authorization` value is remembered (seconds); 0 disables the cache.
    public let cacheLifetime: Int64

    /// A store of `entries`; names must be unique, non-empty and contain no `:`.
    public init(_ entries: [(user: String, hash: PasswordHash)], cacheLifetime: Int64 = 300) throws(AuthConfigurationError) {
        var users: [User] = []
        for (name, hash) in entries {
            let bytes = Array(name.utf8)
            guard !bytes.isEmpty, !bytes.contains(UInt8(ascii: ":")) else {
                throw AuthConfigurationError("user name \"\(name)\" must be non-empty and contain no ':'")
            }
            guard !users.contains(where: { $0.bytes == bytes }) else {
                throw AuthConfigurationError("user \"\(name)\" is listed twice")
            }
            users.append(User(name: name, bytes: bytes, fingerprint: Self.fingerprint(bytes), hash: hash))
        }
        self.users = users
        let iterations = users.first?.hash.iterations ?? PasswordHash.defaultIterations
        dummy = PasswordHash(iterations: iterations, salt: Array(repeating: 0x5A, count: 16), derivedKey: Array(repeating: 0, count: 32))
        self.cacheLifetime = cacheLifetime
        cache = cacheLifetime > 0 ? VerifiedCache() : nil
    }

    /// Parses `user:hash` lines (see the type's documentation).
    public init(lines text: String, cacheLifetime: Int64 = 300) throws(AuthConfigurationError) {
        var entries: [(String, PasswordHash)] = []
        for (number, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingWhitespace
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else {
                throw AuthConfigurationError("line \(number + 1): expected user:$pbkdf2-sha256$…")
            }
            let user = String(line[..<colon])
            guard let hash = PasswordHash(line[line.index(after: colon)...]) else {
                throw AuthConfigurationError("line \(number + 1): user \"\(user)\" has no valid $pbkdf2-sha256$ hash (plaintext passwords are not accepted)")
            }
            entries.append((user, hash))
        }
        try self.init(entries, cacheLifetime: cacheLifetime)
    }

    /// The user names, in order.
    public var names: [String] { users.map(\.name) }

    static func fingerprint(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in bytes { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
        return hash
    }

    /// Checks `user`/`password`. Returns the user's position, or `nil`. Always runs one PBKDF2
    /// derivation, for known and unknown users alike.
    public func verify(user: UnsafeRawBufferPointer, password: UnsafeRawBufferPointer) -> Int? {
        let fingerprint = Self.fingerprint(user)
        var found = -1
        for (i, entry) in users.enumerated()
        where entry.fingerprint == fingerprint && entry.bytes.count == user.count && found < 0 {
            if entry.bytes.withUnsafeBytes({ ConstantTime.equals($0.baseAddress!, user.baseAddress!, count: user.count) }) {
                found = i
            }
        }
        let hash = found >= 0 ? users[found].hash : dummy
        let ok = hash.verify(password: password)
        return ok && found >= 0 ? found : nil
    }

    /// The name of the user at `index`.
    public func name(at index: Int) -> String { users[index].name }

    // MARK: Verified-value cache

    /// Recently verified `Authorization` values, by keyed digest: 256 slots, direct-mapped.
    final class VerifiedCache: Sendable {
        struct Entry {
            var digest: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
            var user: Int32 = -1
            var expires: Int64 = 0
        }

        static let slots = 256
        /// A random per-process HMAC key: the table never holds anything derived from a
        /// credential without it.
        let key: [UInt8]
        let entries: Mutex<[Entry]>

        init() {
            var generator = SystemRandomNumberGenerator()
            key = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
            entries = Mutex(Array(repeating: Entry(), count: Self.slots))
        }

        /// HMAC-SHA256 of `value` under the per-process key, as four words. Does not allocate.
        func digest(_ value: UnsafeRawBufferPointer) -> (UInt64, UInt64, UInt64, UInt64) {
            var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
            withUnsafeMutableBytes(of: &words) { output in
                key.withUnsafeBytes { Digest.hmacSHA256(key: $0, data: value, into: output) }
            }
            return words
        }

        func lookup(_ digest: (UInt64, UInt64, UInt64, UInt64), now: Int64) -> Int? {
            let slot = Int(truncatingIfNeeded: digest.0 & UInt64(Self.slots - 1))
            return entries.withLock { entries -> Int? in
                let entry = entries[slot]
                guard entry.user >= 0, entry.expires > now, entry.digest == digest else { return nil }
                return Int(entry.user)
            }
        }

        func store(_ digest: (UInt64, UInt64, UInt64, UInt64), user: Int, expires: Int64) {
            let slot = Int(truncatingIfNeeded: digest.0 & UInt64(Self.slots - 1))
            entries.withLock { $0[slot] = Entry(digest: digest, user: Int32(user), expires: expires) }
        }
    }
}

extension StringProtocol {
    var trimmingWhitespace: Substring {
        var view = Substring(self)
        while let first = view.first, first == " " || first == "\t" || first == "\r" { view = view.dropFirst() }
        while let last = view.last, last == " " || last == "\t" || last == "\r" { view = view.dropLast() }
        return view
    }
}
