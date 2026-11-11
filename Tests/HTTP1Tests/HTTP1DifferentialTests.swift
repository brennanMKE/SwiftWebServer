import Testing
import HTTPCore
import HTTP1
import HTTPTestSupport

/// `HTTP1Parser` against `ReferenceHTTP1Parser` (docs/ROADMAP.md §7, "keep a validating path").
@Suite struct HTTP1DifferentialTests {
    /// A small deterministic PRNG so failures reproduce.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let interestingBytes: [UInt8] = [
        0x0D, 0x0A, 0x20, 0x09, UInt8(ascii: ":"), 0x00, 0x01, 0x7F, 0x80, 0xFF,
        UInt8(ascii: "%"), UInt8(ascii: "?"), UInt8(ascii: "/"), UInt8(ascii: "*"), UInt8(ascii: "@"),
        UInt8(ascii: "#"), UInt8(ascii: ","), UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "("),
        UInt8(ascii: "."), UInt8(ascii: "a"), UInt8(ascii: "Z"), UInt8(ascii: "0"), UInt8(ascii: "9"),
    ]

    static let insertedLines: [String] = [
        "Transfer-Encoding: chunked\r\n", "Content-Length: 5\r\n", "Content-Length: 6\r\n",
        "Content-Length: 5, 5\r\n", "Host: z\r\n", "Transfer-Encoding: gzip, chunked\r\n",
        "Transfer-Encoding: chunked, chunked\r\n", " folded\r\n", "X:\r\n", "\r\n", "\n",
        "transfer-encoding: identity\r\n", "content-length: 00\r\n",
    ]

    static func mutate(_ input: [UInt8], using rng: inout SplitMix64) -> [UInt8] {
        var bytes = input
        for _ in 0..<Int.random(in: 1...3, using: &rng) {
            let position = bytes.isEmpty ? 0 : Int.random(in: 0..<bytes.count, using: &rng)
            switch Int.random(in: 0..<8, using: &rng) {
            case 0 where !bytes.isEmpty:
                bytes[position] = interestingBytes.randomElement(using: &rng)!
            case 1:
                bytes.insert(interestingBytes.randomElement(using: &rng)!, at: position)
            case 2 where !bytes.isEmpty:
                bytes.remove(at: position)
            case 3:
                bytes.removeLast(bytes.count - position)
            case 4:
                // Duplicate a line.
                let starts = [0] + bytes.indices.filter { $0 > 0 && bytes[$0 - 1] == 0x0A }
                let start = starts.randomElement(using: &rng)!
                let end = bytes[start...].firstIndex(of: 0x0A).map { $0 + 1 } ?? bytes.count
                bytes.insert(contentsOf: bytes[start..<end], at: end)
            case 5:
                // Insert a field line after the request line.
                let line = HTTP1Corpus.bytes(insertedLines.randomElement(using: &rng)!)
                let at = bytes.firstIndex(of: 0x0A).map { $0 + 1 } ?? bytes.count
                bytes.insert(contentsOf: line, at: at)
            case 6 where !bytes.isEmpty:
                bytes[position] = ASCII.lowercased(bytes[position]) == bytes[position]
                    ? (bytes[position] &- 0x61 < 26 ? bytes[position] - 0x20 : bytes[position])
                    : bytes[position] | 0x20
            default:
                bytes.insert(UInt8.random(in: 0...255, using: &rng), at: position)
            }
        }
        return bytes
    }

    static func randomLimits(using rng: inout SplitMix64) -> HTTP1ParserLimits {
        guard Int.random(in: 0..<4, using: &rng) == 0 else { return HTTP1ParserLimits() }
        return HTTP1ParserLimits(maxRequestLineLength: Int.random(in: 1...48, using: &rng),
                                 maxHeaderCount: Int.random(in: 0...6, using: &rng),
                                 maxHeadBytes: Int.random(in: 1...160, using: &rng))
    }

    struct Mismatch: CustomStringConvertible {
        var input: [UInt8]
        var limits: HTTP1ParserLimits
        var fast: HTTP1HeadOutcome
        var reference: HTTP1HeadOutcome
        var description: String {
            let text = String(String.UnicodeScalarView(input.map { Unicode.Scalar($0) }))
            return "\(text.debugDescription) limits \(limits): fast \(fast) reference \(reference)"
        }
    }

    /// Both parsers agree on the hand-written corpus, with default and tight limits.
    @Test func corpusMatchesReference() {
        let limitSets = [HTTP1ParserLimits(),
                         HTTP1ParserLimits(maxRequestLineLength: 20, maxHeaderCount: 3, maxHeadBytes: 90),
                         HTTP1ParserLimits(maxRequestLineLength: 1, maxHeaderCount: 0, maxHeadBytes: 1)]
        var compared = 0
        for text in HTTP1Corpus.all + HTTP1Corpus.issue0006Fragments {
            let bytes = HTTP1Corpus.bytes(text)
            for limits in limitSets {
                let fast = ParserDriver.oneShot(bytes, limits: limits)
                let reference = ReferenceHTTP1Parser.parse(bytes, limits: limits)
                #expect(fast == reference, "\(Mismatch(input: bytes, limits: limits, fast: fast, reference: reference))")
                compared += 1
            }
        }
        // The corpus exercises every outcome.
        let outcomes = Set(HTTP1Corpus.all.map { text -> Int in
            switch ReferenceHTTP1Parser.parse(HTTP1Corpus.bytes(text)) {
            case .needMoreBytes: 0
            case .complete: 200
            case .error(let status): status
            }
        })
        #expect(outcomes == [200, 400, 501, 505])
        #expect(compared > 300)
    }

    /// Fed one byte at a time, the parser's outcome after every call equals the reference
    /// outcome for the bytes received so far.
    @Test func everyPrefixMatchesReference() {
        for text in HTTP1Corpus.all {
            let bytes = HTTP1Corpus.bytes(text)
            let outcomes = ParserDriver.feed(bytes, chunks: Array(repeating: 1, count: bytes.count))
            for (step, fast) in outcomes.enumerated() {
                let reference = ReferenceHTTP1Parser.parse(Array(bytes.prefix(step + 1)))
                #expect(fast == reference, "\(text.debugDescription) after \(step + 1) bytes: fast \(fast) reference \(reference)")
            }
        }
    }

    /// At least 10,000 generated mutations of the corpus, with zero mismatches; each is also
    /// fed in two random pieces and must give the same outcome.
    @Test func generatedInputsMatchReference() {
        var rng = SplitMix64(state: 0x0075)
        let seeds = (HTTP1Corpus.all + HTTP1Corpus.issue0006Fragments).map(HTTP1Corpus.bytes)
        var mismatches: [Mismatch] = []
        var splitMismatches = 0
        var statuses: [Int: Int] = [:]
        let count = 12_000
        for _ in 0..<count {
            let input = Self.mutate(seeds.randomElement(using: &rng)!, using: &rng)
            let limits = Self.randomLimits(using: &rng)
            let fast = ParserDriver.oneShot(input, limits: limits)
            let reference = ReferenceHTTP1Parser.parse(input, limits: limits)
            if fast != reference {
                mismatches.append(Mismatch(input: input, limits: limits, fast: fast, reference: reference))
            }
            let split = Int.random(in: 0...input.count, using: &rng)
            let pieces = ParserDriver.feed(input, chunks: [split], limits: limits).last
            if pieces != fast {
                splitMismatches += 1
                if splitMismatches <= 3 {
                    Issue.record("split at \(split): \(Mismatch(input: input, limits: limits, fast: pieces ?? .needMoreBytes, reference: fast))")
                }
            }
            switch fast {
            case .needMoreBytes: statuses[0, default: 0] += 1
            case .complete: statuses[200, default: 0] += 1
            case .error(let status): statuses[status, default: 0] += 1
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(count) differ; first: \(mismatches.prefix(5).map(\.description).joined(separator: "\n"))")
        #expect(splitMismatches == 0)
        // The mutations reach every outcome.
        #expect(Set(statuses.keys) == [0, 200, 400, 414, 431, 501, 505], "\(statuses)")
        print("HTTP1 differential: \(count) inputs, outcomes \(statuses.sorted { $0.key < $1.key })")
    }
}
