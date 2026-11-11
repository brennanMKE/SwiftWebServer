import HTTP2
import HTTPCore

/// HTTP/2 frame parse cost (RFC 9113 §4, §6) in nanoseconds per frame.
///
/// Not registered yet: a later change adds
/// `H2FrameBench.run().map { ("\($0.name) (per frame)", $0.nanosecondsPerFrame) }` to
/// `registerSelfTimedSuites()`. The input is built once, and each timed pass makes a fresh
/// parser. Whole-buffer parsing reports every payload in place and does not allocate. The
/// chunked pass splits frame headers and HEADERS payloads across inputs; its buffer
/// allocates once per pass, on the first split payload, and keeps its capacity after that.
enum H2FrameBench {
    /// One connection's worth of frames: HEADERS, three DATA frames (one padded), a
    /// WINDOW_UPDATE and a PING, repeated `repeats` times.
    static func connection(repeats: Int = 200) -> (bytes: ByteBuffer, frames: Int) {
        let fragment = [UInt8](repeating: 0x82, count: 48)
        let body = [UInt8](repeating: 0x61, count: 256)
        var buffer = ByteBuffer()
        var frames = 0
        for index in 0..<repeats {
            let stream = HTTP2StreamID(UInt32(index * 2 + 1))
            fragment.withUnsafeBytes { HTTP2FrameEncoder.encodeHeaders(streamID: stream, fragment: $0, into: &buffer) }
            body.withUnsafeBytes { payload in
                HTTP2FrameEncoder.encodeData(streamID: stream, data: payload, into: &buffer)
                HTTP2FrameEncoder.encodeData(streamID: stream, data: payload, padding: 8, into: &buffer)
                HTTP2FrameEncoder.encodeData(streamID: stream, data: payload, endStream: true, into: &buffer)
            }
            HTTP2FrameEncoder.encodeWindowUpdate(streamID: .connection, increment: 768, into: &buffer)
            HTTP2FrameEncoder.encodePing(opaqueData: UInt64(index), into: &buffer)
            frames += 6
        }
        return (buffer, frames)
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

    /// Parses `input` in `chunkSize` pieces (or whole when `nil`) and folds the events.
    @inline(__always)
    static func parsePass(_ input: UnsafeRawBufferPointer, chunkSize: Int?) -> UInt64 {
        var parser = HTTP2FrameParser()
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
                    case .dataHeader(let frame): checksum = checksum &* 31 &+ UInt64(frame.flowControlledLength)
                    case .data(let range): checksum = checksum &+ UInt64(range.count)
                    case .headers(_, _, _, _, let fragment): checksum = checksum &* 31 &+ UInt64(fragment.count)
                    case .windowUpdate(_, let increment): checksum = checksum &+ UInt64(increment)
                    case .ping(_, let data): checksum = checksum ^ data
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
        let (bytes, frames) = connection()
        var checksum: UInt64 = 0
        let clock = ContinuousClock()
        let start = clock.now
        bytes.withUnsafeReadableBytes { input in
            for _ in 0..<iterations {
                checksum = checksum &* 31 &+ parsePass(input, chunkSize: chunkSize)
            }
        }
        let elapsed = clock.now - start
        return Result(
            name: name, frames: frames, bytes: bytes.readableBytes, iterations: iterations,
            elapsed: elapsed, checksum: checksum)
    }

    /// Whole-buffer parse: every frame header and payload is in one contiguous input.
    static func whole(iterations: Int = 5_000) -> Result {
        measure(name: "h2frames.parse.whole", chunkSize: nil, iterations: iterations)
    }

    /// 37-byte chunks, so frame headers and HEADERS payloads straddle chunk boundaries.
    static func chunked(iterations: Int = 5_000) -> Result {
        measure(name: "h2frames.parse.chunked37", chunkSize: 37, iterations: iterations)
    }

    /// Runs both measurements.
    static func run(iterations: Int = 5_000) -> [Result] {
        [whole(iterations: iterations), chunked(iterations: iterations)]
    }
}
