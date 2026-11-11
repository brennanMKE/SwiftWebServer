import HTTP3

/// HTTP/3 frame parse cost (RFC 9114 §7) in nanoseconds per frame.
///
/// Not wired into `main` yet. The harness (`sws-bench h3frames`) calls
/// ``H3FrameBench/run(iterations:)`` and reports the results. The input is built once, and
/// each timed pass makes a fresh parser. Whole-buffer parsing reports every payload in place
/// and does not allocate. The chunked pass forces partial varints and buffered HEADERS; its
/// buffer allocates once per pass, on the first split HEADERS, and keeps its capacity for
/// the remaining frames.
enum H3FrameBench {
    /// One request stream's worth of frames: HEADERS, three DATA frames and a reserved frame,
    /// repeated `repeats` times.
    static func requestStream(repeats: Int = 200) -> (bytes: [UInt8], frames: Int) {
        let fieldSection = [UInt8](repeating: 0x51, count: 48)
        let body = [UInt8](repeating: 0x61, count: 256)
        var bytes: [UInt8] = []
        var frames = 0
        do {
            for index in 0..<repeats {
                try fieldSection.withUnsafeBytes { p throws in try H3FrameEncoder.encodeHeaders(fieldSection: p, into: &bytes) }
                for _ in 0..<3 {
                    try body.withUnsafeBytes { p throws in try H3FrameEncoder.encodeData(p, into: &bytes) }
                }
                try [UInt8(index & 0xff)].withUnsafeBytes { p throws in
                    try H3FrameEncoder.encodeFrame(type: .reserved(UInt64(index)), payload: p, into: &bytes)
                }
                frames += 5
            }
        } catch {
            fatalError("benchmark input failed to encode: \(error)")
        }
        return (bytes, frames)
    }

    struct Result {
        var name: String
        var frames: Int
        var bytes: Int
        var iterations: Int
        var elapsed: Duration
        /// Folded output so the work cannot be optimized away.
        var checksum: UInt64

        var nanosecondsPerFrame: Double {
            let ns = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            return ns / Double(frames * iterations)
        }

        var summary: String {
            "\(name): \((nanosecondsPerFrame * 100).rounded() / 100) ns/frame "
                + "(\(frames) frames, \(bytes) bytes per pass, checksum \(checksum))"
        }
    }

    /// Parses `bytes` in `chunkSize` pieces (or whole when `nil`) and folds the events.
    @inline(__always)
    static func parsePass(_ input: UnsafeRawBufferPointer, chunkSize: Int?) -> UInt64 {
        var parser = H3FrameParser()
        var checksum: UInt64 = 0
        let step = chunkSize ?? input.count
        var chunkStart = 0
        do {
            while chunkStart < input.count {
                let chunkEnd = min(chunkStart + step, input.count)
                var offset = chunkStart
                parsing: while true {
                    let output = try parser.parse(UnsafeRawBufferPointer(rebasing: input[offset..<chunkEnd]))
                    offset += output.consumed
                    switch output.event {
                    case .needsMoreData: break parsing
                    case .dataHeader(let length): checksum = checksum &* 31 &+ length
                    case .data(let range): checksum = checksum &+ UInt64(range.count)
                    case .headers(let location):
                        if case .input(let range) = location { checksum = checksum &* 31 &+ UInt64(range.count) }
                        else { checksum = checksum &* 37 }
                    default: checksum = checksum &+ 1
                    }
                }
                chunkStart = chunkEnd
            }
            try parser.finish()
        } catch {
            fatalError("benchmark input failed to parse: \(error)")
        }
        return checksum
    }

    static func measure(name: String, chunkSize: Int?, iterations: Int) -> Result {
        let (bytes, frames) = requestStream()
        var checksum: UInt64 = 0
        let clock = ContinuousClock()
        let start = clock.now
        bytes.withUnsafeBytes { input in
            for _ in 0..<iterations {
                checksum = checksum &* 31 &+ parsePass(input, chunkSize: chunkSize)
            }
        }
        let elapsed = clock.now - start
        return Result(
            name: name, frames: frames, bytes: bytes.count, iterations: iterations,
            elapsed: elapsed, checksum: checksum)
    }

    /// Whole-buffer parse: every frame header and payload is in one contiguous input.
    static func whole(iterations: Int = 5_000) -> Result {
        measure(name: "h3frames.parse.whole", chunkSize: nil, iterations: iterations)
    }

    /// 37-byte chunks, so frame headers and HEADERS payloads straddle chunk boundaries.
    static func chunked(iterations: Int = 5_000) -> Result {
        measure(name: "h3frames.parse.chunked37", chunkSize: 37, iterations: iterations)
    }

    /// Runs both measurements.
    static func run(iterations: Int = 5_000) -> [Result] {
        [whole(iterations: iterations), chunked(iterations: iterations)]
    }
}
