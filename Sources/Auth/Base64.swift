/// Base64 (RFC 4648 §4) and base64url (§5) without Foundation, decoding into caller memory.
enum Base64 {
    /// The alphabet: standard (`+/`) or URL-safe (`-_`).
    enum Alphabet {
        case standard
        case url
    }

    /// Byte value to sextet, 0xFF for invalid; one table per alphabet.
    static let standardTable: [UInt8] = table(plus: UInt8(ascii: "+"), slash: UInt8(ascii: "/"))
    static let urlTable: [UInt8] = table(plus: UInt8(ascii: "-"), slash: UInt8(ascii: "_"))

    private static func table(plus: UInt8, slash: UInt8) -> [UInt8] {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (i, byte) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8.enumerated() {
            table[Int(byte)] = UInt8(i)
        }
        table[Int(plus)] = 62
        table[Int(slash)] = 63
        return table
    }

    /// Most bytes `length` encoded characters decode to.
    @inline(__always)
    static func maximumDecodedLength(_ length: Int) -> Int { (length / 4) * 3 + 3 }

    /// Decodes `input[start..<end]` into `output`, returning the decoded length, or `nil` for
    /// a character outside the alphabet, a bad length, nonzero trailing bits, or too little
    /// room. Padding (`=`) is accepted only at the end and only for `.standard` (base64url in
    /// JWTs is unpadded, RFC 7515 §2).
    static func decode(_ input: Span<UInt8>, from start: Int, to end: Int, alphabet: Alphabet,
                       into output: UnsafeMutableRawBufferPointer) -> Int? {
        var stop = end
        if alphabet == .standard {
            var padding = 0
            while stop > start && input[stop &- 1] == UInt8(ascii: "=") && padding < 2 { stop &-= 1; padding &+= 1 }
            if padding > 0 && (stop &- start + padding) % 4 != 0 { return nil }
        }
        let length = stop &- start
        if length % 4 == 1 { return nil }
        let decodedLength = (length / 4) * 3 + Swift.max(0, length % 4 &- 1)
        guard decodedLength <= output.count else { return nil }
        return (alphabet == .standard ? standardTable : urlTable).withUnsafeBufferPointer { table -> Int? in
            var accumulator: UInt32 = 0
            var bits = 0
            var written = 0
            var i = start
            while i < stop {
                let value = table[Int(input[i])]
                if value == 0xFF { return nil }
                accumulator = accumulator << 6 | UInt32(value)
                bits &+= 6
                if bits >= 8 {
                    bits &-= 8
                    output[written] = UInt8(truncatingIfNeeded: accumulator >> UInt32(bits))
                    written &+= 1
                }
                i &+= 1
            }
            // Leftover bits must be zero (canonical encoding).
            if bits > 0 && accumulator & ((1 << UInt32(bits)) &- 1) != 0 { return nil }
            return written
        }
    }

    /// Encodes `bytes` (allocates; for tools and tests).
    static func encode(_ bytes: [UInt8], alphabet: Alphabet, padded: Bool) -> String {
        let characters = Array((alphabet == .standard
            ? "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
            : "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").utf8)
        var output: [UInt8] = []
        output.reserveCapacity((bytes.count + 2) / 3 * 4)
        var i = 0
        while i + 2 < bytes.count {
            let n = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
            for shift in [18, 12, 6, 0] { output.append(characters[Int(n >> UInt32(shift) & 63)]) }
            i += 3
        }
        let rest = bytes.count - i
        if rest > 0 {
            var n = UInt32(bytes[i]) << 16
            if rest == 2 { n |= UInt32(bytes[i + 1]) << 8 }
            output.append(characters[Int(n >> 18 & 63)])
            output.append(characters[Int(n >> 12 & 63)])
            if rest == 2 { output.append(characters[Int(n >> 6 & 63)]) }
            if padded { output.append(contentsOf: Array(String(repeating: "=", count: 3 - rest).utf8)) }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Decodes a whole string (allocates; for configuration).
    static func decode(_ text: String, alphabet: Alphabet) -> [UInt8]? {
        let bytes = Array(text.utf8)
        var output = [UInt8](repeating: 0, count: maximumDecodedLength(bytes.count))
        let count = bytes.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBytes { decode(Span(_unsafeElements: input), from: 0, to: bytes.count, alphabet: alphabet, into: $0) }
        }
        guard let count else { return nil }
        return Array(output.prefix(count))
    }
}
