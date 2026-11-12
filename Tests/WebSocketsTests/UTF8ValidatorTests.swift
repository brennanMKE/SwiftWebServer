import Testing
@testable import WebSockets

@Suite struct UTF8ValidatorTests {
    func isValid(_ bytes: [UInt8]) -> Bool {
        var validator = UTF8Validator()
        return validator.validate(bytes) && validator.isAtBoundary
    }

    @Test func validText() {
        for text in ["", "hello", "κόσμε", "日本語テキスト", "emoji 😀🎉", "\u{10FFFF}", "\u{FFFD}", "a\u{0}b",
                     String(repeating: "abcdefgh", count: 20) + "é"] {
            #expect(isValid(Array(text.utf8)), "\(text)")
        }
        // Boundaries of each sequence length.
        for scalar in [0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF] {
            #expect(isValid(Array(String(Unicode.Scalar(scalar)!).utf8)), "U+\(String(scalar, radix: 16))")
        }
    }

    @Test(arguments: [
        [0xC0, 0x80] as [UInt8],          // overlong NUL
        [0xC1, 0xBF],                     // overlong 2-byte
        [0xE0, 0x80, 0x80],               // overlong 3-byte
        [0xE0, 0x9F, 0xBF],               // overlong 3-byte (U+07FF)
        [0xF0, 0x80, 0x80, 0x80],         // overlong 4-byte
        [0xF0, 0x8F, 0xBF, 0xBF],         // overlong 4-byte (U+FFFF)
        [0xED, 0xA0, 0x80],               // surrogate U+D800
        [0xED, 0xBF, 0xBF],               // surrogate U+DFFF
        [0xED, 0xA0, 0x80, 0xED, 0xB0, 0x80], // surrogate pair (CESU-8)
        [0xF4, 0x90, 0x80, 0x80],         // U+110000
        [0xF5, 0x80, 0x80, 0x80],         // invalid lead
        [0xFF],                           // invalid byte
        [0xFE],
        [0x80],                           // stray continuation
        [0x41, 0xBF, 0x41],
        [0xC2, 0x41],                     // missing continuation
        [0xE2, 0x82],                     // truncated at the end
        [0xF0, 0x9F, 0x98],               // truncated 4-byte at the end
        [0xCE, 0xBA, 0xE1, 0xBD, 0xB9, 0xCF, 0x83, 0xCE, 0xBC, 0xCE, 0xB5, 0xED, 0xA0, 0x80, 0x65, 0x64, 0x69, 0x74, 0x65, 0x64],
    ])
    func invalidSequences(bytes: [UInt8]) {
        #expect(!isValid(bytes))
    }

    @Test func failsFastBeforeTheSequenceEnds() {
        // The second byte already rules these out.
        for prefix: [UInt8] in [[0xE0, 0x80], [0xED, 0xA0], [0xF0, 0x80], [0xF4, 0x90], [0xC0]] {
            var validator = UTF8Validator()
            do { let ok = validator.validate(prefix); #expect(!ok, "\(prefix)") }
            #expect(validator.isFailed)
        }
        // A valid prefix is not a failure, only not a boundary.
        var validator = UTF8Validator()
        do { let ok = validator.validate([0xF0, 0x9F, 0x98]); #expect(ok) }
        #expect(!validator.isAtBoundary)
        do { let ok = validator.validate([0x80]); #expect(ok) }
        #expect(validator.isAtBoundary)
    }

    @Test func codePointsSplitAtEveryOffset() {
        let text = Array("aé日😀κόσμε\u{10FFFF}z".utf8)
        for split in 0...text.count {
            var validator = UTF8Validator()
            do { let ok = validator.validate(Array(text[..<split])); #expect(ok) }
            do { let ok = validator.validate(Array(text[split...])); #expect(ok) }
            #expect(validator.isAtBoundary, "split at \(split)")
        }
        // Byte at a time.
        var validator = UTF8Validator()
        for byte in text { do { let ok = validator.validate([byte]); #expect(ok) } }
        #expect(validator.isAtBoundary)
    }

    @Test func longASCIIRunsWithAnInvalidByteAnywhere() {
        let base = Array(repeating: UInt8(ascii: "a"), count: 40)
        for position in 0..<base.count {
            var bytes = base
            bytes[position] = 0xFF
            #expect(!isValid(bytes), "0xFF at \(position)")
        }
    }

    @Test func failureIsSticky() {
        var validator = UTF8Validator()
        do { let ok = validator.validate([0xFF]); #expect(!ok) }
        do { let ok = validator.validate([0x41]); #expect(!ok) }
        #expect(!validator.isAtBoundary)
        validator.reset()
        do { let ok = validator.validate([0x41]); #expect(ok) }
    }
}
