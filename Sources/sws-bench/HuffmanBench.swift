import HeaderCompression

/// Huffman codec throughput (RFC 7541 §5.2) on a typical header value.
///
/// Not wired into `main` yet; the harness (`sws-bench huffman`) calls
/// ``HuffmanBench/decode(iterations:)`` and ``HuffmanBench/encode(iterations:)`` and reports
/// the results. Both reuse one preallocated output array, so the timed loop does not allocate.
enum HuffmanBench {
    /// A browser `user-agent`: a long, mostly lowercase-and-punctuation value typical of
    /// what HPACK and QPACK encoders Huffman-code.
    static let typicalHeaderValue: [UInt8] = Array(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"
            .utf8)

    struct Result {
        /// Name of the measurement.
        var name: String
        /// Plain (decoded) bytes processed per iteration.
        var plainBytes: Int
        /// Huffman-coded bytes per iteration.
        var encodedBytes: Int
        var iterations: Int
        var elapsed: Duration
        /// Folded output so the work cannot be optimized away.
        var checksum: UInt64

        /// Plain bytes per second in MB/s (10^6 bytes).
        var megabytesPerSecond: Double {
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            return Double(plainBytes * iterations) / seconds / 1e6
        }

        var nanosecondsPerIteration: Double {
            let ns = Double(elapsed.components.seconds) * 1e9
                + Double(elapsed.components.attoseconds) / 1e9
            return ns / Double(iterations)
        }

        /// Nanoseconds per plain byte.
        var nanosecondsPerByte: Double { nanosecondsPerIteration / Double(plainBytes) }

        var summary: String {
            "\(name): \(Int(megabytesPerSecond.rounded())) MB/s, "
                + "\((nanosecondsPerByte * 100).rounded() / 100) ns/byte, "
                + "\(Int(nanosecondsPerIteration.rounded())) ns per \(plainBytes)-byte value "
                + "(\(encodedBytes) coded bytes, checksum \(checksum))"
        }
    }

    /// Decode MB/s (of decoded output) for ``typicalHeaderValue``.
    static func decode(iterations: Int = 500_000) -> Result {
        var encoded: [UInt8] = []
        typicalHeaderValue.withUnsafeBytes { Huffman.encode($0, into: &encoded) }
        var output: [UInt8] = []
        output.reserveCapacity(typicalHeaderValue.count * 2)
        var checksum: UInt64 = 0
        let clock = ContinuousClock()
        let start = clock.now
        encoded.withUnsafeBytes { input in
            for _ in 0..<iterations {
                output.removeAll(keepingCapacity: true)
                do {
                    try Huffman.decode(input, into: &output)
                } catch {
                    fatalError("benchmark input failed to decode: \(error)")
                }
                checksum = checksum &* 31 &+ UInt64(output.count) &+ UInt64(output[output.count / 2])
            }
        }
        let elapsed = clock.now - start
        precondition(output == typicalHeaderValue, "Huffman round trip mismatch")
        return Result(
            name: "huffman.decode", plainBytes: typicalHeaderValue.count, encodedBytes: encoded.count,
            iterations: iterations, elapsed: elapsed, checksum: checksum)
    }

    /// Encode MB/s (of plain input) for ``typicalHeaderValue``.
    static func encode(iterations: Int = 500_000) -> Result {
        var output: [UInt8] = []
        output.reserveCapacity(typicalHeaderValue.count)
        var checksum: UInt64 = 0
        let clock = ContinuousClock()
        let start = clock.now
        typicalHeaderValue.withUnsafeBytes { input in
            for _ in 0..<iterations {
                output.removeAll(keepingCapacity: true)
                Huffman.encode(input, into: &output)
                checksum = checksum &* 31 &+ UInt64(output.count) &+ UInt64(output[output.count / 2])
            }
        }
        let elapsed = clock.now - start
        return Result(
            name: "huffman.encode", plainBytes: typicalHeaderValue.count, encodedBytes: output.count,
            iterations: iterations, elapsed: elapsed, checksum: checksum)
    }

    /// Runs both measurements.
    static func run(iterations: Int = 500_000) -> [Result] {
        [decode(iterations: iterations), encode(iterations: iterations)]
    }
}
