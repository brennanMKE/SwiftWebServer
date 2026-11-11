import HPACK

/// HPACK encode and decode cost (RFC 7541) for a typical browser request header set.
///
/// Not wired into the harness yet: a later change registers it (for example as an `hpack`
/// suite in `BenchmarkRegistry.swift`) and reports ns per header block.
///
/// Both measurements are steady state, which is what a long-lived HTTP/2 connection sees: the
/// first block populates the dynamic table, then every timed iteration encodes or decodes the
/// same request again (mostly one-byte indexed fields, a never-indexed `cookie`, and the
/// literal `:path`). The output array, the encoder and decoder tables, and the decoder's
/// Huffman scratch are reused, so the timed loops do not allocate.
enum HPACKBench {
    static let typicalRequest: [(name: [UInt8], value: [UInt8])] = [
        (":method", "GET"),
        (":scheme", "https"),
        (":authority", "www.example.com"),
        (":path", "/articles/2026/11/hpack-ring-buffers?ref=home"),
        ("accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
        ("accept-encoding", "gzip, deflate, br"),
        ("accept-language", "en-US,en;q=0.9"),
        (
            "user-agent",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"
        ),
        ("sec-fetch-mode", "navigate"),
        ("priority", "u=0, i"),
        ("cookie", "session=4f1c2a9e8b7d6c5e; theme=dark"),
    ].map { (Array($0.0.utf8), Array($0.1.utf8)) }

    struct Result {
        var name: String
        var fields: Int
        /// Encoded header block bytes.
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
            "\(name): \(Int(nanosecondsPerIteration.rounded())) ns per \(fields)-field block "
                + "(\(encodedBytes) encoded bytes, checksum \(checksum))"
        }
    }

    /// Counts what it receives without storing it, standing in for reused `HTTPFields` storage.
    struct CountingSink: HPACKFieldSink {
        var fields = 0
        var checksum: UInt64 = 0

        mutating func field(name: Span<UInt8>, value: Span<UInt8>, representation: HPACKRepresentation) {
            fields &+= 1
            checksum = checksum &* 31 &+ UInt64(name.count) &+ UInt64(value.count)
                &+ UInt64(value.isEmpty ? 0 : value[0])
        }
    }

    static func encodeBlock(_ encoder: inout HPACKEncoder, into output: inout [UInt8]) {
        encoder.beginHeaderBlock(into: &output)
        for field in typicalRequest {
            field.name.withUnsafeBufferPointer { name in
                field.value.withUnsafeBufferPointer { value in
                    encoder.encode(name: name.span, value: value.span, into: &output)
                }
            }
        }
    }

    static func decodeBlock(_ decoder: inout HPACKDecoder, _ block: [UInt8], into sink: inout CountingSink) {
        block.withUnsafeBufferPointer { buffer in
            do throws(HPACKError) {
                try decoder.decode(buffer.span, into: &sink)
            } catch {
                fatalError("benchmark input failed to decode: \(error)")
            }
        }
    }

    /// ns to encode ``typicalRequest`` on a warm connection into a reused output array.
    static func encode(iterations: Int = 500_000) -> Result {
        var encoder = HPACKEncoder()
        var output: [UInt8] = []
        output.reserveCapacity(1024)
        encodeBlock(&encoder, into: &output)
        let tableCount = encoder.dynamicTable.count
        var checksum: UInt64 = 0
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<iterations {
            output.removeAll(keepingCapacity: true)
            encodeBlock(&encoder, into: &output)
            checksum = checksum &* 31 &+ UInt64(output.count) &+ UInt64(output[output.count / 2])
        }
        let elapsed = clock.now - start
        precondition(encoder.dynamicTable.count == tableCount, "steady-state block changed the table")
        return Result(
            name: "hpack.encode", fields: typicalRequest.count, encodedBytes: output.count,
            iterations: iterations, elapsed: elapsed, checksum: checksum)
    }

    /// ns to decode the warm-connection encoding of ``typicalRequest`` with a reused decoder.
    static func decode(iterations: Int = 500_000) -> Result {
        var encoder = HPACKEncoder()
        var first: [UInt8] = []
        encodeBlock(&encoder, into: &first)
        var steady: [UInt8] = []
        encodeBlock(&encoder, into: &steady)

        var decoder = HPACKDecoder()
        var sink = CountingSink()
        decodeBlock(&decoder, first, into: &sink)
        sink = CountingSink()
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<iterations {
            decodeBlock(&decoder, steady, into: &sink)
        }
        let elapsed = clock.now - start
        precondition(sink.fields == typicalRequest.count * iterations, "HPACK field count mismatch")
        precondition(decoder.dynamicTable.count == encoder.dynamicTable.count, "HPACK tables diverged")
        return Result(
            name: "hpack.decode", fields: typicalRequest.count, encodedBytes: steady.count,
            iterations: iterations, elapsed: elapsed, checksum: sink.checksum)
    }

    /// Runs both measurements.
    static func run(iterations: Int = 500_000) -> [Result] {
        [decode(iterations: iterations), encode(iterations: iterations)]
    }
}
