import Compression
import HTTPCore
import Testing

/// Round trips through the system libraries: everything encoded is decoded with the same
/// library (libz for gzip/deflate, libcompression for Brotli).
@Suite struct CodecTests {
    @Test func brotliIsAvailableOnMacOS() {
        #expect(ContentCoding.brotli.isAvailable)
    }

    @Test(arguments: ContentCoding.allCases)
    func oneShotRoundTrip(_ coding: ContentCoding) throws {
        for size in [300, 1500, 50 * 1024, 700 * 1024] {
            let input = sampleText(size, seed: UInt64(size))
            let encoded = try #require(ContentCodec.encode(ByteBuffer(bytes: input), coding))
            #expect(encoded.readableBytes < input.count)
            let bytes = encoded.withUnsafeReadableBytes { Array($0) }
            #expect(ContentCodec.decode(bytes, coding) == input, "\(coding) \(size)")
        }
    }

    @Test func framing() throws {
        let input = ByteBuffer(bytes: sampleText(4096))
        let gzip = try #require(ContentCodec.encode(input, .gzip)).withUnsafeReadableBytes { Array($0) }
        #expect(gzip.prefix(3) == [0x1F, 0x8B, 0x08])           // gzip magic, deflate
        let deflate = try #require(ContentCodec.encode(input, .deflate)).withUnsafeReadableBytes { Array($0) }
        #expect(deflate[0] & 0x0F == 8 && (UInt16(deflate[0]) << 8 | UInt16(deflate[1])) % 31 == 0)  // zlib header
    }

    @Test(arguments: ContentCoding.allCases)
    func incompressibleInputIsRefused(_ coding: ContentCoding) {
        #expect(ContentCodec.encode(ByteBuffer(bytes: randomBytes(8192)), coding) == nil)
        #expect(ContentCodec.encode(ByteBuffer(), coding) == nil)
    }

    @Test(arguments: ContentCoding.allCases)
    func streamingRoundTrip(_ coding: ContentCoding) throws {
        let input = sampleText(300_000)
        let encoder = try #require(ContentEncoder(coding, level: 4))
        var output = ByteBuffer()
        // Feed in uneven pieces with a small output window.
        var offset = 0
        var window = [UInt8](repeating: 0, count: 777)
        let pieces = [1, 10, 4096, 65_536, 100_000]
        var index = 0
        func step(_ range: Range<Int>, finish: Bool) throws -> CodecProgress {
            let progress = try input.withUnsafeBytes { source in
                try window.withUnsafeMutableBytes { out in
                    try encoder.process(UnsafeRawBufferPointer(rebasing: source[range]), into: out, finish: finish)
                }
            }
            output.append(contentsOf: window[..<progress.produced])
            return progress
        }
        while offset < input.count {
            let end = min(offset + pieces[index % pieces.count], input.count)
            index += 1
            while offset < end {
                offset += try step(offset..<end, finish: false).consumed
            }
        }
        while try !step(offset..<offset, finish: true).finished {}
        let bytes = output.withUnsafeReadableBytes { Array($0) }
        #expect(ContentCodec.decode(bytes, coding) == input)
    }

    @Test func corruptInputFailsToDecode() throws {
        var bytes = try #require(ContentCodec.encode(ByteBuffer(bytes: sampleText(5000)), .gzip)).withUnsafeReadableBytes { Array($0) }
        bytes[bytes.count / 2] ^= 0xFF
        bytes[bytes.count - 3] ^= 0xFF        // CRC / size trailer
        #expect(ContentCodec.decode(bytes, .gzip) == nil)
        #expect(ContentCodec.decode([1, 2, 3, 4, 5], .brotli) == nil)
        // Trailing garbage after a complete stream.
        let good = try #require(ContentCodec.encode(ByteBuffer(bytes: sampleText(5000)), .deflate)).withUnsafeReadableBytes { Array($0) }
        #expect(ContentCodec.decode(good + [0], .deflate) == nil)
    }

    /// The raw-deflate primitive permessage-deflate (#0110) needs: sync flush per message,
    /// one LZ77 window across messages, decoded by a raw inflater.
    @Test func rawDeflateWithSyncFlush() throws {
        let encoder = try #require(DeflateEncoder(format: .raw, level: 6))
        let decoder = try #require(DeflateDecoder(format: .raw))
        for message in 0..<5 {
            let text = Array("message \(message): hello hello hello, compression".utf8)
            var out = [UInt8](repeating: 0, count: 1024)
            let progress = text.withUnsafeBytes { source in
                out.withUnsafeMutableBytes { encoder.process(source, into: $0, flush: .sync) }
            }
            #expect(progress.consumed == text.count)
            let frame = Array(out[..<progress.produced])
            #expect(frame.suffix(4) == [0x00, 0x00, 0xFF, 0xFF])       // empty stored block
            var plain = [UInt8](repeating: 0, count: 1024)
            let decoded = try frame.withUnsafeBytes { source in
                try plain.withUnsafeMutableBytes { try decoder.process(source, into: $0) }
            }
            #expect(Array(plain[..<decoded.produced]) == text)
        }
    }
}
