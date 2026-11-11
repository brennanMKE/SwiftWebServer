import Testing
import HTTPCore

/// Runs `body` with a span over the UTF-8 bytes of `text`.
private func withSpan<R>(_ text: String, _ body: (Span<UInt8>) -> R) -> R {
    ByteBuffer(bytes: Array(text.utf8)).withReadableSpan(body)
}

private func parseDecimal(_ text: String) -> UInt64? { withSpan(text) { ASCII.parseDecimal($0) } }
private func parseHex(_ text: String) -> UInt64? { withSpan(text) { ASCII.parseHex($0) } }

@Suite struct ASCIITests {
    // MARK: Token table

    @Test func tokenTableMatchesRFC9110ForAll256Bytes() {
        let tchar = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        for value in 0...255 {
            let byte = UInt8(value)
            #expect(ASCII.isTokenCharacter(byte) == tchar.contains(byte), "byte \(value)")
        }
        let table = ASCII.tokenTable
        #expect(table.2 == 0 && table.3 == 0)
        #expect([table.0, table.1, table.2, table.3].map(\.nonzeroBitCount).reduce(0, +) == tchar.count)
    }

    @Test func delimitersAreNotTokens() {
        for byte in Array("\"(),/:;<=>?@[\\]{} \t\r\n".utf8) + [0x00, 0x7F, 0x80, 0xFF] {
            #expect(!ASCII.isTokenCharacter(byte))
        }
    }

    @Test func fieldValueTableMatchesRFC9110ForAll256Bytes() {
        for value in 0...255 {
            let byte = UInt8(value)
            let expected = byte == 0x09 || byte == 0x20 || (0x21...0x7E).contains(byte) || byte >= 0x80
            #expect(ASCII.isFieldValueCharacter(byte) == expected, "byte \(value)")
        }
        #expect(!ASCII.isFieldValueCharacter(0x0D))
        #expect(!ASCII.isFieldValueCharacter(0x0A))
        #expect(!ASCII.isFieldValueCharacter(0x00))
        #expect(!ASCII.isFieldValueCharacter(0x7F))
    }

    // MARK: Scanning

    @Test func firstIndexOfByte() {
        #expect(withSpan("Host: a") { ASCII.firstIndex(of: UInt8(ascii: ":"), in: $0) } == 4)
        #expect(withSpan("a:b:c") { ASCII.firstIndex(of: UInt8(ascii: ":"), in: $0, from: 2) } == 3)
        #expect(withSpan("abc") { ASCII.firstIndex(of: UInt8(ascii: ":"), in: $0) } == nil)
        #expect(withSpan("abc") { ASCII.firstIndex(of: UInt8(ascii: "a"), in: $0, from: 3) } == nil)
        #expect(withSpan("") { ASCII.firstIndex(of: 0, in: $0) } == nil)
    }

    @Test func firstCRLFHandlesSplitsAndLoneBytes() {
        #expect(withSpan("GET / HTTP/1.1\r\nHost") { ASCII.firstCRLF(in: $0) } == 14)
        #expect(withSpan("\r\n") { ASCII.firstCRLF(in: $0) } == 0)
        #expect(withSpan("a\rb\nc\r\n") { ASCII.firstCRLF(in: $0) } == 5)   // lone CR and LF skipped
        #expect(withSpan("\r\r\n") { ASCII.firstCRLF(in: $0) } == 1)
        #expect(withSpan("abc\r") { ASCII.firstCRLF(in: $0) } == nil)       // needs more bytes
        #expect(withSpan("abc\n") { ASCII.firstCRLF(in: $0) } == nil)
        #expect(withSpan("") { ASCII.firstCRLF(in: $0) } == nil)
        #expect(withSpan("x\r\ny\r\n") { ASCII.firstCRLF(in: $0, from: 2) } == 4)
    }

    // MARK: Character classes and case folding

    @Test func lowercasingFoldsOnlyUppercaseLetters() {
        for value in 0...255 {
            let byte = UInt8(value)
            let expected = (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
            #expect(ASCII.lowercased(byte) == expected, "byte \(value)")
        }
    }

    @Test func digitAndHexClassification() {
        for value in 0...255 {
            let byte = UInt8(value)
            let scalar = Character(Unicode.Scalar(byte))
            #expect(ASCII.isDigit(byte) == ("0"..."9").contains(scalar))
            #expect(ASCII.isHexDigit(byte) == (scalar.isASCII && scalar.isHexDigit))
            if let value = ASCII.hexDigitValue(byte) {
                #expect(UInt8(String(scalar), radix: 16) == value)
            }
        }
        for nibble in UInt8(0)..<16 {
            #expect(ASCII.hexDigitValue(ASCII.lowercaseHexDigit(nibble)) == nibble)
        }
        #expect(ASCII.lowercaseHexDigit(10) == UInt8(ascii: "a"))
    }

    @Test func caseInsensitiveAndExactComparison() {
        #expect(withSpan("Content-Length") { ASCII.equalsCaseInsensitive($0, "content-length") })
        #expect(withSpan("HOST") { ASCII.equalsCaseInsensitive($0, "host") })
        #expect(!withSpan("hosts") { ASCII.equalsCaseInsensitive($0, "host") })
        #expect(!withSpan("hos") { ASCII.equalsCaseInsensitive($0, "host") })
        #expect(!withSpan("h0st") { ASCII.equalsCaseInsensitive($0, "host") })
        #expect(withSpan("") { ASCII.equalsCaseInsensitive($0, "") })
        // '@' (0x40) and '`' (0x60) differ only in bit 5 but are not letters.
        #expect(!withSpan("@") { ASCII.equalsCaseInsensitive($0, "`") })
        #expect(!withSpan("[") { ASCII.equalsCaseInsensitive($0, "{") })
        #expect(withSpan("GET") { ASCII.equals($0, "GET") })
        #expect(!withSpan("get") { ASCII.equals($0, "GET") })
        #expect(!withSpan("GE") { ASCII.equals($0, "GET") })
    }

    // MARK: FNV-1a

    @Test func fnv1aMatchesReferenceVectors() {
        // Published FNV-1a 32-bit test vectors.
        #expect(withSpan("") { ASCII.fnv1aLowercased($0) } == 0x811C_9DC5)
        #expect(withSpan("a") { ASCII.fnv1aLowercased($0) } == 0xE40C_292C)
        #expect(withSpan("foobar") { ASCII.fnv1aLowercased($0) } == 0xBF9C_F968)
    }

    @Test func fnv1aIsCaseInsensitive() {
        let lower = ASCII.fnv1aLowercased("content-type")
        #expect(withSpan("Content-Type") { ASCII.fnv1aLowercased($0) } == lower)
        #expect(withSpan("CONTENT-TYPE") { ASCII.fnv1aLowercased($0) } == lower)
        #expect(ASCII.fnv1aLowercased("FOOBAR") == 0xBF9C_F968)
        #expect(ASCII.fnv1aLowercased("content-length") != lower)
    }

    @Test func incrementalHasherMatchesOneShot() {
        var hasher = ASCII.FNV1a()
        #expect(hasher.value == ASCII.FNV1a.offsetBasis)
        for byte in "Accept-Encoding".utf8 { hasher.combineLowercased(byte) }
        #expect(hasher.value == ASCII.fnv1aLowercased("accept-encoding"))
    }

    // MARK: Decimal parsing

    @Test(arguments: [
        ("0", UInt64(0)), ("7", 7), ("10", 10), ("0042", 42), ("1234567890", 1_234_567_890),
        ("18446744073709551615", UInt64.max),
        ("000000000000000000000018446744073709551615", UInt64.max),
    ])
    func parseDecimalAccepts(text: String, expected: UInt64) {
        #expect(parseDecimal(text) == expected)
    }

    @Test(arguments: [
        "", " 1", "1 ", "+1", "-1", "1a", "0x10", "1.0", "/", ":",
        "18446744073709551616",       // UInt64.max + 1: overflow on add
        "18446744073709551620",       // overflow on add, last digit
        "184467440737095516150",      // overflow on multiply
        "99999999999999999999999",
    ])
    func parseDecimalRejects(text: String) {
        #expect(parseDecimal(text) == nil)
    }

    // MARK: Hex parsing

    @Test(arguments: [
        ("0", UInt64(0)), ("f", 15), ("F", 15), ("10", 16), ("aBcD", 0xABCD), ("000a", 10),
        ("ffffffffffffffff", UInt64.max), ("FFFFFFFFFFFFFFFF", UInt64.max),
        ("0000ffffffffffffffff", UInt64.max), ("8000000000000000", 1 << 63),
    ])
    func parseHexAccepts(text: String, expected: UInt64) {
        #expect(parseHex(text) == expected)
    }

    @Test(arguments: [
        "", "g", "G", "0x1", "-1", "1 ", " 1", "1;ext", "1\r\n", "@", "`", "/", ":",
        "10000000000000000",          // 2^64: overflow
        "fffffffffffffffff",          // 17 significant digits
    ])
    func parseHexRejects(text: String) {
        #expect(parseHex(text) == nil)
    }

    // MARK: Digit counts and round trips

    @Test func digitCounts() {
        #expect(ASCII.decimalDigitCount(0) == 1)
        #expect(ASCII.decimalDigitCount(9) == 1)
        #expect(ASCII.decimalDigitCount(10) == 2)
        #expect(ASCII.decimalDigitCount(UInt64.max) == 20)
        #expect(ASCII.hexDigitCount(0) == 1)
        #expect(ASCII.hexDigitCount(0xF) == 1)
        #expect(ASCII.hexDigitCount(0x10) == 2)
        #expect(ASCII.hexDigitCount(UInt64.max) == 16)
        for shift in 0..<64 {
            let value = UInt64(1) << UInt64(shift)
            #expect(ASCII.hexDigitCount(value) == String(value, radix: 16).count)
            #expect(ASCII.decimalDigitCount(value) == String(value).count)
            #expect(ASCII.decimalDigitCount(value - 1) == String(value - 1).count)
        }
    }

    @Test func integerToASCIIRoundTrips() {
        var values: [UInt64] = [0, 1, UInt64.max, UInt64.max - 1]
        var x: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<200 {
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            values.append(x >> (x & 63))
        }
        for value in values {
            var buffer = ByteBuffer()
            buffer.append(decimal: value)
            #expect(buffer.withReadableSpan { ASCII.parseDecimal($0) } == value)
            #expect(buffer.bytes == Array(String(value).utf8))
            buffer.clear()
            buffer.append(hex: value)
            #expect(buffer.withReadableSpan { ASCII.parseHex($0) } == value)
            #expect(buffer.bytes == Array(String(value, radix: 16).utf8))
        }
    }

    @Test func stringFromSpanReplacesInvalidUTF8() {
        #expect(withSpan("héllo") { ASCII.string(from: $0) } == "héllo")
        let invalid = ByteBuffer(bytes: [0x61, 0xFF, 0x62])
        #expect(invalid.withReadableSpan { ASCII.string(from: $0) } == "a\u{FFFD}b")
    }
}
