import HTTPCore

/// ByteBuffer and ASCII microbenchmarks (issue #0073). Not wired into `main` yet; the harness
/// calls `runByteBufferBenchmarks()` and reports the results.
///
/// Each benchmark reuses one buffer the way a connection does, so the steady state measures
/// the hot path without allocations.
func runByteBufferBenchmarks(iterations: Int = 2_000_000) -> [(name: String, nanosecondsPerOp: Double)] {
    [
        ("bytebuffer.append decimal", measureByteBuffer(iterations: iterations, appendDecimal)),
        ("bytebuffer.append+parse decimal", measureByteBuffer(iterations: iterations, appendAndParseDecimal)),
        ("bytebuffer.append+parse hex", measureByteBuffer(iterations: iterations, appendAndParseHex)),
        ("bytebuffer.append static+discard", measureByteBuffer(iterations: iterations, appendStaticAndDiscard)),
        ("ascii.fnv1a header name", measureByteBuffer(iterations: iterations, hashHeaderName)),
    ]
}

/// Runs `body` `iterations` times on one reused buffer and returns nanoseconds per call.
private func measureByteBuffer(iterations: Int, _ body: (inout ByteBuffer, Int) -> UInt64) -> Double {
    var buffer = ByteBuffer(capacity: 4096)
    var sink: UInt64 = 0
    for i in 0..<min(iterations, 10_000) { sink &+= body(&buffer, i) }   // warm up
    let clock = ContinuousClock()
    let start = clock.now
    for i in 0..<iterations { sink &+= body(&buffer, i) }
    let elapsed = start.duration(to: clock.now)
    blackHole(sink)
    let (seconds, attoseconds) = elapsed.components
    let nanoseconds = Double(seconds) * 1e9 + Double(attoseconds) / 1e9
    return nanoseconds / Double(iterations)
}

@inline(never)
private func blackHole(_ value: UInt64) {
    if value == 0x5EED_5EED_5EED_5EED { print("") }
}

/// Integer-to-ASCII alone (a Content-Length value, 1 to 10 digits).
private func appendDecimal(_ buffer: inout ByteBuffer, _ i: Int) -> UInt64 {
    buffer.clear()
    buffer.append(decimal: UInt64(truncatingIfNeeded: i) &* 2_654_435_761 >> UInt64(i & 31))
    return UInt64(buffer.readableBytes)
}

/// Content-Length style: integer to ASCII, then digit-loop parse.
private func appendAndParseDecimal(_ buffer: inout ByteBuffer, _ i: Int) -> UInt64 {
    buffer.clear()
    buffer.append(decimal: UInt64(i) &* 2_654_435_761)
    return buffer.withReadableSpan { ASCII.parseDecimal($0) } ?? 0
}

/// Chunk-size style: hex out and back.
private func appendAndParseHex(_ buffer: inout ByteBuffer, _ i: Int) -> UInt64 {
    buffer.clear()
    buffer.append(hex: UInt64(i) &* 2_654_435_761)
    return buffer.withReadableSpan { ASCII.parseHex($0) } ?? 0
}

/// Serializer style: status line and a header from static strings, then consume and discard.
private func appendStaticAndDiscard(_ buffer: inout ByteBuffer, _ i: Int) -> UInt64 {
    buffer.append("HTTP/1.1 200 OK\r\nContent-Length: ")
    buffer.append(decimal: i & 0xFFFF)
    buffer.append("\r\n\r\n")
    let count = buffer.readableBytes
    buffer.moveReaderIndex(forwardBy: count)
    buffer.discardReadBytes()
    return UInt64(count)
}

/// Header-name lookup style: lowercase FNV-1a over a received name.
private func hashHeaderName(_ buffer: inout ByteBuffer, _ i: Int) -> UInt64 {
    if buffer.isEmpty { buffer.append("Content-Type") }
    return UInt64(buffer.withReadableSpan { ASCII.fnv1aLowercased($0) }) &+ UInt64(i & 1)
}
