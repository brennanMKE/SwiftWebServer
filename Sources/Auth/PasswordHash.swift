import CommonCrypto

/// A salted PBKDF2-HMAC-SHA256 password hash (RFC 8018), the only form passwords are stored in.
///
/// Text form, one per credential-file line after `user:`:
///
/// ```
/// $pbkdf2-sha256$600000$<salt, base64url>$<derived key, base64url>
/// ```
///
/// Make one with `sws-bench hash-password` (or ``make(password:iterations:salt:)``).
/// Derivation uses CommonCrypto (`CCKeyDerivationPBKDF`), a system library: no keychain.
public struct PasswordHash: Sendable, Equatable, CustomStringConvertible {
    /// PBKDF2 iterations. Default for new hashes: 600,000 (OWASP 2023 for PBKDF2-HMAC-SHA256).
    public let iterations: Int
    /// The salt (16 random bytes for new hashes).
    public let salt: [UInt8]
    /// The derived key (32 bytes).
    public let derivedKey: [UInt8]

    /// Iterations for new hashes.
    public static let defaultIterations = 600_000
    /// Accepted iteration range when parsing (the low end keeps tests fast; the high end
    /// bounds the CPU a single request can cost).
    public static let iterationRange = 1_000...10_000_000
    static let prefix = "$pbkdf2-sha256$"

    public init(iterations: Int, salt: [UInt8], derivedKey: [UInt8]) {
        self.iterations = iterations
        self.salt = salt
        self.derivedKey = derivedKey
    }

    /// Parses the text form; `nil` when malformed.
    public init?(_ text: some StringProtocol) {
        guard text.hasPrefix(Self.prefix) else { return nil }
        let parts = text.dropFirst(Self.prefix.count).split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 3, let iterations = Int(parts[0]), Self.iterationRange.contains(iterations),
              let salt = Base64.decode(String(parts[1]), alphabet: .url), salt.count >= 8,
              let key = Base64.decode(String(parts[2]), alphabet: .url), key.count == 32
        else { return nil }
        self.init(iterations: iterations, salt: salt, derivedKey: key)
    }

    /// The text form.
    public var description: String {
        "\(Self.prefix)\(iterations)$\(Base64.encode(salt, alphabet: .url, padded: false))$\(Base64.encode(derivedKey, alphabet: .url, padded: false))"
    }

    /// Hashes `password` with a fresh random salt (or `salt`).
    public static func make(password: String, iterations: Int = defaultIterations, salt: [UInt8]? = nil) -> PasswordHash {
        let salt = salt ?? (0..<16).map { _ in UInt8.random(in: 0...255) }
        var key = [UInt8](repeating: 0, count: 32)
        let bytes = Array(password.utf8)
        bytes.withUnsafeBytes { password in
            key.withUnsafeMutableBytes { output in
                derive(password: password, salt: salt, iterations: iterations, into: output)
            }
        }
        return PasswordHash(iterations: iterations, salt: salt, derivedKey: key)
    }

    /// True when `password` hashes to ``derivedKey``. Constant-time comparison; the derived
    /// key lives on the stack.
    public func verify(password: UnsafeRawBufferPointer) -> Bool {
        withUnsafeTemporaryAllocation(byteCount: 32, alignment: 8) { output in
            Self.derive(password: password, salt: salt, iterations: iterations, into: output)
            let equal = derivedKey.withUnsafeBytes { ConstantTime.equals($0.baseAddress!, output.baseAddress!, count: 32) }
            output.initializeMemory(as: UInt8.self, repeating: 0)
            return equal
        }
    }

    static func derive(password: UnsafeRawBufferPointer, salt: [UInt8], iterations: Int,
                       into output: UnsafeMutableRawBufferPointer) {
        guard let base = password.baseAddress else {
            // An empty password still needs a valid pointer.
            let zero: UInt8 = 0
            withUnsafeBytes(of: zero) { derive(password: UnsafeRawBufferPointer(start: $0.baseAddress, count: 0), salt: salt, iterations: iterations, into: output) }
            return
        }
        let status = salt.withUnsafeBufferPointer { salt in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                base.assumingMemoryBound(to: CChar.self), password.count,
                salt.baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                output.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count)
        }
        precondition(status == kCCSuccess, "CCKeyDerivationPBKDF failed: \(status)")
    }
}
