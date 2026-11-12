/// A streaming UTF-8 validator (RFC 3629) for text messages split across frames and reads.
///
/// Bytes are fed in pieces; the validator keeps the position inside the current code point,
/// so a multi-byte character split across fragments validates. It fails fast: the first byte
/// that cannot continue a valid sequence fails (overlong forms, surrogates U+D800–DFFF and
/// code points above U+10FFFF are caught on their second byte at the latest), without
/// waiting for the message to end. ASCII runs are checked eight bytes at a time.
public struct UTF8Validator: Sendable, Hashable {
    /// Continuation bytes still expected for the current code point.
    var remaining: UInt8 = 0
    /// Allowed range of the next continuation byte (narrower than 0x80...0xBF right after
    /// E0, ED, F0 and F4).
    var lower: UInt8 = 0x80
    var upper: UInt8 = 0xBF
    /// Set once invalid input was seen; sticky.
    public private(set) var isFailed = false

    public init() {}

    /// True when the bytes so far form complete code points (a message may end here).
    public var isAtBoundary: Bool { !isFailed && remaining == 0 }

    /// Validates the next bytes. Returns false (and stays failed) on the first invalid byte.
    public mutating func validate(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard !isFailed else { return false }
        guard let base = bytes.baseAddress else { return true }
        let count = bytes.count
        var i = 0
        while i < count {
            if remaining == 0 {
                // Fast path: whole words of ASCII.
                while i &+ 8 <= count,
                      base.loadUnaligned(fromByteOffset: i, as: UInt64.self) & 0x8080_8080_8080_8080 == 0 {
                    i &+= 8
                }
                guard i < count else { break }
                let byte = base.load(fromByteOffset: i, as: UInt8.self)
                i &+= 1
                switch byte {
                case 0x00...0x7F:
                    continue
                case 0xC2...0xDF:
                    remaining = 1; lower = 0x80; upper = 0xBF
                case 0xE0:
                    remaining = 2; lower = 0xA0; upper = 0xBF   // no overlongs
                case 0xED:
                    remaining = 2; lower = 0x80; upper = 0x9F   // no surrogates
                case 0xE1...0xEC, 0xEE...0xEF:
                    remaining = 2; lower = 0x80; upper = 0xBF
                case 0xF0:
                    remaining = 3; lower = 0x90; upper = 0xBF   // no overlongs
                case 0xF1...0xF3:
                    remaining = 3; lower = 0x80; upper = 0xBF
                case 0xF4:
                    remaining = 3; lower = 0x80; upper = 0x8F   // nothing above U+10FFFF
                default:
                    // 0x80–0xC1 (stray continuation, overlong 2-byte lead) and 0xF5–0xFF.
                    isFailed = true
                    return false
                }
            } else {
                let byte = base.load(fromByteOffset: i, as: UInt8.self)
                i &+= 1
                guard byte >= lower && byte <= upper else {
                    isFailed = true
                    return false
                }
                remaining &-= 1
                lower = 0x80
                upper = 0xBF
            }
        }
        return true
    }

    /// Validates the bytes of a byte array (tests and edges).
    public mutating func validate(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { validate($0) }
    }

    /// Starts a new message.
    public mutating func reset() {
        self = UTF8Validator()
    }
}
