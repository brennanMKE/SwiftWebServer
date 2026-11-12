import HeaderCompression
import QPACK

/// QPACK static-table encode and decode cost (RFC 9204) for a typical 10-field request.
///
/// Not wired into `main` yet; the harness (`sws-bench qpack`) calls ``QPACKBench/encode(iterations:)``
/// and ``QPACKBench/decode(iterations:)`` and reports ns per field section. Both reuse
/// preallocated output, and the decoder keeps its Huffman scratch between iterations, so the
/// timed loops do not allocate once warm.
enum QPACKBench {
    /// A Safari navigation request: static indexed lines, static name references with
    /// Huffman values, and literal names.
    static let typicalRequest: [(name: [UInt8], value: [UInt8])] = [
        (":method", "GET"),
        (":scheme", "https"),
        (":authority", "www.example.com"),
        (":path", "/index.html"),
        ("accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
        ("accept-encoding", "gzip, deflate, br"),
        ("accept-language", "en-US,en;q=0.9"),
        (
            "user-agent",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"
        ),
        ("sec-fetch-mode", "navigate"),
        ("priority", "u=0, i"),
    ].map { (Array($0.0.utf8), Array($0.1.utf8)) }

    struct Result {
        var name: String
        var fields: Int
        /// Encoded field section bytes.
        var encodedBytes: Int
        var iterations: Int
        var elapsed: Duration
        /// Folded output so the work cannot be optimized away.
        var checksum: UInt64

        var nanosecondsPerIteration: Double {
            let ns = Double(elapsed.components.seconds) * 1e9
                + Double(elapsed.components.attoseconds) / 1e9
            return ns / Double(iterations)
        }

        var summary: String {
            "\(name): \(Int(nanosecondsPerIteration.rounded())) ns per \(fields)-field section "
                + "(\(encodedBytes) encoded bytes, checksum \(checksum))"
        }
    }

    /// Counts what it receives without storing it, standing in for reused `HTTPFields` storage.
    struct CountingSink: QPACKFieldSink {
        var fields = 0
        var checksum: UInt64 = 0

        mutating func field(name: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer, neverIndexed: Bool) {
            fields &+= 1
            checksum = checksum &* 31 &+ UInt64(name.count) &+ UInt64(value.count)
                &+ UInt64(value.first ?? 0)
        }
    }

    static func encodedRequest() -> [UInt8] {
        var out: [UInt8] = []
        QPACKEncoder().encode(typicalRequest, into: &out)
        return out
    }

    /// ns to encode ``typicalRequest`` into a reused output array.
    static func encode(iterations: Int = 500_000) -> Result {
        let encoder = QPACKEncoder()
        var output: [UInt8] = []
        output.reserveCapacity(512)
        var checksum: UInt64 = 0
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<iterations {
            output.removeAll(keepingCapacity: true)
            encoder.encodePrefix(into: &output)
            for field in typicalRequest {
                field.name.withUnsafeBytes { name in
                    field.value.withUnsafeBytes { value in
                        encoder.encodeField(name: name, value: value, into: &output)
                    }
                }
            }
            checksum = checksum &* 31 &+ UInt64(output.count) &+ UInt64(output[output.count / 2])
        }
        let elapsed = clock.now - start
        return Result(
            name: "qpack.encode", fields: typicalRequest.count, encodedBytes: output.count,
            iterations: iterations, elapsed: elapsed, checksum: checksum)
    }

    /// ns to decode the encoded ``typicalRequest`` with a reused decoder.
    static func decode(iterations: Int = 500_000) -> Result {
        let encoded = encodedRequest()
        var decoder = QPACKDecoder()
        var sink = CountingSink()
        let clock = ContinuousClock()
        let start = clock.now
        encoded.withUnsafeBytes { input in
            for _ in 0..<iterations {
                do throws(QPACKError) {
                    try decoder.decode(input, into: &sink)
                } catch {
                    fatalError("benchmark input failed to decode: \(error)")
                }
            }
        }
        let elapsed = clock.now - start
        precondition(sink.fields == typicalRequest.count * iterations, "QPACK field count mismatch")
        return Result(
            name: "qpack.decode", fields: typicalRequest.count, encodedBytes: encoded.count,
            iterations: iterations, elapsed: elapsed, checksum: sink.checksum)
    }

    /// ns to decode ``typicalRequest`` when every field is a dynamic table entry (#0106): one
    /// Indexed Field Line per field, plus taking the Section Acknowledgment it queues.
    static func decodeDynamic(iterations: Int = 500_000) -> Result {
        var decoder = QPACKDynamicDecoder(maxTableCapacity: 4096, maxBlockedStreams: 16)
        var instructions: [UInt8] = [0x3F, 0xE1, 0x1F]   // Set Dynamic Table Capacity 4096
        for field in typicalRequest {
            field.name.withUnsafeBytes {
                StringLiteral.encode($0, prefixBits: 5, flags: 0x40, huffman: .never, into: &instructions)
            }
            field.value.withUnsafeBytes { StringLiteral.encode($0, prefixBits: 7, huffman: .never, into: &instructions) }
        }
        instructions.withUnsafeBytes { bytes in
            do throws(QPACKError) {
                _ = try decoder.consumeEncoderStream(bytes)
            } catch {
                fatalError("benchmark encoder stream failed: \(error)")
            }
        }
        // Required Insert Count 10 (encoded 10 % 256 + 1), Base 10; entry k is relative 9 - k.
        var encoded: [UInt8] = [0x0B, 0x00]
        for k in 0..<typicalRequest.count { encoded.append(0x80 | UInt8(typicalRequest.count - 1 - k)) }
        var acknowledgments: [UInt8] = []
        acknowledgments.reserveCapacity(16)
        decoder.takeDecoderStreamOutput(into: &acknowledgments)
        var sink = CountingSink()
        let clock = ContinuousClock()
        let start = clock.now
        encoded.withUnsafeBytes { input in
            for _ in 0..<iterations {
                do throws(QPACKError) {
                    try decoder.decode(input, requiredInsertCount: 10, streamID: 0, into: &sink)
                } catch {
                    fatalError("benchmark input failed to decode: \(error)")
                }
                acknowledgments.removeAll(keepingCapacity: true)
                decoder.takeDecoderStreamOutput(into: &acknowledgments)
            }
        }
        let elapsed = clock.now - start
        precondition(sink.fields == typicalRequest.count * iterations, "QPACK field count mismatch")
        return Result(
            name: "qpack.decode.dynamic", fields: typicalRequest.count, encodedBytes: encoded.count,
            iterations: iterations, elapsed: elapsed, checksum: sink.checksum)
    }

    /// Runs every measurement.
    static func run(iterations: Int = 500_000) -> [Result] {
        [decode(iterations: iterations), encode(iterations: iterations), decodeDynamic(iterations: iterations)]
    }
}
