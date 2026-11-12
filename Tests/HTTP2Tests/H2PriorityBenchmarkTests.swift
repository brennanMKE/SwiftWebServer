@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Testing

#if canImport(Darwin)
import Darwin
#endif

/// #0065 benchmark (docs/benchmarks/M10-priorities.md): two concurrent downloads on one
/// in-memory HTTP/2 connection, the low-priority one requested first. The client reads like
/// a browser, returning connection window every 32 KB it consumes, so the connection window is
/// the contended resource. Reports completion order and times. `SWS_PRIORITY_BENCH_MB` sets the
/// size of each download (default 2 MB, so the suite stays fast).
@Suite(.timeLimit(.minutes(1)))
struct H2PriorityBenchmarkTests {
    struct Result: CustomStringConvertible {
        var scenario: String
        var finished: [(stream: UInt32, ms: Double)]
        /// Bytes of the other download received when the first one finished.
        var otherBytesAtFirst = 0
        var description: String {
            "\(scenario): " + finished.map { "stream \($0.stream) done at \(String(format: "%.1f", $0.ms)) ms" }
                .joined(separator: ", ") + "; other stream had \(otherBytesAtFirst >> 10) KB when the first finished"
        }
    }

    static var size: Int {
        let mb = ProcessInfoLite.env("SWS_PRIORITY_BENCH_MB").flatMap(Int.init) ?? 2
        return mb << 20
    }

    /// Downloads `/low` on stream 1 and `/high` on stream 3 with the given `priority` fields.
    static func download(scenario: String, low: String?, high: String?) async throws -> Result {
        let body = ByteBuffer(bytes: Array(repeating: 0x61, count: size))
        let handler = ClosureHandler { _ in HTTPResponse(body: .bytes(body)) }
        var result = Result(scenario: scenario, finished: [])
        try await withH2Connection(handler: handler) { client in
            try await client.handshake(HTTP2Settings(initialWindowSize: 1 << 30))
            let start = ContinuousClock.now
            try await client.send(
                F.headers(1, block: client.requests.get("/low", extra: low.map { [("priority", $0)] } ?? [])),
                F.headers(3, block: client.requests.get("/high", extra: high.map { [("priority", $0)] } ?? [])))
            var unacknowledged = 0
            var received: [UInt32: Int] = [:]
            while result.finished.count < 2, let frame = try await client.nextFrame(timeout: .seconds(30)) {
                guard case .data(let stream, let bytes, let endStream) = frame else { continue }
                unacknowledged += bytes.count
                received[stream, default: 0] += bytes.count
                if endStream && result.finished.isEmpty { result.otherBytesAtFirst = received[stream == 1 ? 3 : 1] ?? 0 }
                if unacknowledged >= 32_768 {
                    try await client.send(F.windowUpdate(0, UInt32(unacknowledged)))
                    unacknowledged = 0
                }
                if endStream {
                    let elapsed = ContinuousClock.now - start
                    let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
                    result.finished.append((stream, ms))
                }
            }
        }
        print("[M10-priorities] \(size >> 20) MB each: \(result)")
        return result
    }

    @Test func urgentDownloadFinishesFirst() async throws {
        let signalled = try await Self.download(scenario: "low u=7, high u=0", low: "u=7", high: "u=0")
        #expect(signalled.finished.map(\.stream) == [3, 1])
        let unsignalled = try await Self.download(scenario: "no priority field", low: nil, high: nil)
        #expect(unsignalled.finished.map(\.stream) == [1, 3])
        let incremental = try await Self.download(scenario: "both u=3, i", low: "i", high: "i")
        #expect(incremental.finished.count == 2)
    }
}

/// `getenv` without Foundation.
enum ProcessInfoLite {
    static func env(_ name: String) -> String? {
        guard let value = getenv(name) else { return nil }
        return String(cString: value)
    }
}
