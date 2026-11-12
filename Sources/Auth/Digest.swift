import CommonCrypto

/// HMAC-SHA256 and SHA-256 into caller memory, through CommonCrypto (a system library).
///
/// CryptoKit's `HMAC<SHA256>` and `SHA256.hash` allocate on every call (8 and 2 heap blocks
/// per request measured in `sws-bench micro --filter Auth`); these one-shot C calls do not, so
/// the request path uses them.
enum Digest {
    static let length = 32

    /// `output` (32 bytes) = HMAC-SHA256(`key`, `data`).
    @inline(__always)
    static func hmacSHA256(key: UnsafeRawBufferPointer, data: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) {
        precondition(output.count >= length)
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key.baseAddress, key.count, data.baseAddress, data.count, output.baseAddress)
    }

    /// `output` (32 bytes) = SHA-256(`data`).
    @inline(__always)
    static func sha256(_ data: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) {
        precondition(output.count >= length)
        _ = CC_SHA256(data.baseAddress, CC_LONG(data.count), output.baseAddress!.assumingMemoryBound(to: UInt8.self))
    }

    /// SHA-256 of `bytes` (allocates; for configuration).
    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: length)
        bytes.withUnsafeBytes { data in output.withUnsafeMutableBytes { sha256(data, into: $0) } }
        return output
    }
}
