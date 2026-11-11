import Testing
import HTTPCore
@testable import HTTP1

/// What decoding a whole input produced.
struct ChunkedOutcome: Equatable {
    var data: [UInt8] = []
    var trailers: [UInt8] = []
    /// Bytes consumed when the body ended, or `nil` if it did not end.
    var endOffset: Int?
    var error: ChunkedDecodingError?
}

/// Decodes `bytes` fed in pieces cut at `splits` (offsets into `bytes`).
func decodeChunked(_ bytes: [UInt8], splits: [Int] = [], limits: ChunkedDecoderLimits = ChunkedDecoderLimits()) -> ChunkedOutcome {
    var decoder = ChunkedDecoder(limits: limits)
    var outcome = ChunkedOutcome()
    let cuts = [0] + splits + [bytes.count]
    for piece in 0..<(cuts.count - 1) {
        let segment = Array(bytes[cuts[piece]..<cuts[piece + 1]])
        var offset = 0
        pieceLoop: while true {
            let result = decode(&decoder, Array(segment[offset...]))
            let range = (offset + result.range.lowerBound)..<(offset + result.range.upperBound)
            switch result.kind {
            case .data:
                outcome.data += segment[range]
                offset += result.consumed
            case .needMoreBytes:
                outcome.trailers += segment[range]
                break pieceLoop
            case .end:
                outcome.trailers += segment[range]
                outcome.endOffset = cuts[piece] + offset + result.consumed
                return outcome
            case .error(let error):
                outcome.error = error
                return outcome
            }
        }
    }
    return outcome
}

func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

/// One decoder step over `input` (through a ByteBuffer: `Array.span` needs macOS 26).
func decode(_ decoder: inout ChunkedDecoder, _ input: [UInt8]) -> ChunkedDecoder.Step {
    ByteBuffer(bytes: input).withReadableSpan { decoder.decode($0) }
}

@Suite struct ChunkedDecoderTests {
    static let withExtensionsAndTrailers = bytes(
        "5;name=value;q=\"a;b\"\r\nhello\r\n" +
        "1 ; ext\r\n \r\n" +
        "A\r\n0123456789\r\n" +
        "0;last\r\n" +
        "Checksum: abc123\r\n" +
        "X-Empty:\r\n" +
        "X-Spaced:   padded value  \r\n" +
        "\r\n" +
        "NEXT")

    @Test func simpleBody() {
        let input = bytes("3\r\nabc\r\n0\r\n\r\nGET")
        let outcome = decodeChunked(input)
        #expect(outcome.data == bytes("abc"))
        #expect(outcome.trailers.isEmpty)
        #expect(outcome.endOffset == input.count - 3)
        #expect(outcome.error == nil)
    }

    @Test func extensionsAreIgnoredAndTrailersCollected() {
        let outcome = decodeChunked(Self.withExtensionsAndTrailers)
        #expect(outcome.error == nil)
        #expect(String(decoding: outcome.data, as: UTF8.self) == "hello 0123456789")
        #expect(String(decoding: outcome.trailers, as: UTF8.self)
                == "Checksum: abc123\r\nX-Empty:\r\nX-Spaced:   padded value  \r\n")
        #expect(outcome.endOffset == Self.withExtensionsAndTrailers.count - 4)

        var section = ByteBuffer()
        section.append(contentsOf: outcome.trailers)
        let fields = ChunkedDecoder.parseTrailers(section)
        #expect(fields.count == 3)
        #expect(fields.nameString(at: 0) == "Checksum")
        #expect(fields.valueString(at: 0) == "abc123")
        #expect(fields.valueString(at: 1) == "")
        #expect(fields.valueString(at: 2) == "padded value")
    }

    @Test func everySplitOffsetDecodesIdentically() {
        let input = Self.withExtensionsAndTrailers
        let whole = decodeChunked(input)
        for split in 1..<input.count {
            #expect(decodeChunked(input, splits: [split]) == whole, "split at \(split)")
        }
        for first in stride(from: 1, to: input.count, by: 3) {
            for second in stride(from: first + 1, to: input.count, by: 5) {
                #expect(decodeChunked(input, splits: [first, second]) == whole, "splits \(first), \(second)")
            }
        }
        // One byte at a time.
        #expect(decodeChunked(input, splits: Array(1..<input.count)) == whole)
    }

    @Test func uppercaseAndLeadingZeroHex() {
        let outcome = decodeChunked(bytes("00A\r\n0123456789\r\n000\r\n\r\n"))
        #expect(outcome.data.count == 10)
        #expect(outcome.error == nil)
    }

    @Test func rejectsBadHex() {
        for input in ["g\r\nx\r\n0\r\n\r\n", "\r\n", " 5\r\nhello\r\n0\r\n\r\n", "0x5\r\nhello\r\n", "-1\r\n", "5 x\r\nhello\r\n"] {
            #expect(decodeChunked(bytes(input)).error == .invalidChunkSize, "\(input.debugDescription)")
        }
    }

    @Test func rejectsOversizedChunks() {
        #expect(decodeChunked(bytes("FFFFFFFFFFFFFFFFF\r\n")).error == .chunkTooLarge)
        #expect(decodeChunked(bytes("10000000001\r\n")).error == .chunkTooLarge)   // just over the 2^40 default
        let limits = ChunkedDecoderLimits(maxChunkSize: 16)
        #expect(decodeChunked(bytes("11\r\n"), limits: limits).error == .chunkTooLarge)
        #expect(decodeChunked(bytes("10\r\n0123456789abcdef\r\n0\r\n\r\n"), limits: limits).error == nil)
    }

    @Test func rejectsMissingCRLF() {
        for input in [
            "3\nabc\r\n0\r\n\r\n",       // bare LF after size
            "3\rabc\r\n0\r\n\r\n",       // CR without LF
            "3\r\nabcd\r\n0\r\n\r\n",    // data longer than the size
            "3\r\nabc\n0\r\n\r\n",       // bare LF after data
            "3\r\nabc\r\n0\r\n\n",       // bare LF at the end
            "3\r\nabc\r\n0\r\nX: y\n\r\n",  // bare LF after a trailer
        ] {
            #expect(decodeChunked(bytes(input)).error == .missingCRLF, "\(input.debugDescription)")
        }
    }

    @Test func rejectsBadExtensions() {
        #expect(decodeChunked(bytes("3;a\u{01}b\r\nabc\r\n0\r\n\r\n")).error == .invalidExtension)
        let long = "3;" + String(repeating: "e", count: 2000) + "\r\nabc\r\n0\r\n\r\n"
        #expect(decodeChunked(bytes(long)).error == .invalidExtension)
        #expect(decodeChunked(bytes("3;" + String(repeating: "e", count: 1000) + "\r\nabc\r\n0\r\n\r\n")).error == nil)
    }

    @Test func rejectsBadTrailers() {
        for input in [
            "0\r\nNo colon\r\n\r\n",
            "0\r\n: empty name\r\n\r\n",
            "0\r\nX: a\r\n folded\r\n\r\n",
            "0\r\nX: bad\u{01}\r\n\r\n",
        ] {
            #expect(decodeChunked(bytes(input)).error == .invalidTrailer, "\(input.debugDescription)")
        }
        let limits = ChunkedDecoderLimits(maxTrailerBytes: 16, maxTrailerFields: 2)
        #expect(decodeChunked(bytes("0\r\nA: 1\r\nB: 2\r\n\r\n"), limits: limits).error == nil)
        #expect(decodeChunked(bytes("0\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n"), limits: limits).error == .invalidTrailer)
        #expect(decodeChunked(bytes("0\r\nA: 0123456789abcdef\r\n\r\n"), limits: limits).error == .invalidTrailer)
    }

    @Test func incompleteInputNeedsMoreBytes() {
        let outcome = decodeChunked(bytes("5\r\nhel"))
        #expect(outcome.data == bytes("hel"))
        #expect(outcome.endOffset == nil)
        #expect(outcome.error == nil)
    }

    @Test func errorsAreSticky() {
        var decoder = ChunkedDecoder()
        let bad = bytes("z")
        #expect(decode(&decoder, bad).kind == .error(.invalidChunkSize))
        let good = bytes("0\r\n\r\n")
        #expect(decode(&decoder, good).kind == .error(.invalidChunkSize))
        decoder.reset()
        #expect(decode(&decoder, good).kind == .end)
        #expect(decoder.isComplete)
    }
}
