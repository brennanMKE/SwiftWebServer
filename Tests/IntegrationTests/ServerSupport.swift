import HTTPCore
import HTTPServer
import Synchronization
import Testing

/// Counters and a gate shared between a test and ``TestEchoProtocol`` connections.
final class Probe: Sendable {
    struct Counts: Sendable {
        var started = 0
        var requests = 0
        var finished = 0
        var cancelled = 0
        var sawShutdown = 0
    }

    let counts = Mutex(Counts())
    /// Each request waits for the gate before it is answered. Open by default.
    let gate = ShutdownSignal()

    init(gateOpen: Bool = true) {
        if gateOpen { gate.trigger() }
    }

    var snapshot: Counts { counts.withLock { $0 } }
}

/// The trivial protocol for server tests (HTTP/1.1 lands with #0080): echoes each received
/// chunk after the probe's gate opens, and returns after an answer once the server drains.
struct TestEchoProtocol: ConnectionProtocol {
    let probe: Probe

    static var alpnTokens: [String] { ["echo"] }
    static func matchesCleartextPreface(_ bytes: borrowing ByteBuffer) -> SniffResult { .match }

    func run<T: ByteStreamTransport, H: HTTPHandler>(_ t: T, handler: H, context: ConnectionContext) async {
        probe.counts.withLock { $0.started += 1 }
        defer { probe.counts.withLock { $0.finished += 1 } }
        var buffer = ByteBuffer(capacity: 4096)
        do {
            while true {
                buffer.clear()
                let count = try await t.receive(into: &buffer, maxLength: 4096)
                if count == 0 { break }
                probe.counts.withLock { $0.requests += 1 }
                await probe.gate.wait()
                try Task.checkCancellation()
                try await t.send(buffer, endOfStream: false)
                if context.shutdown.isTriggered {
                    probe.counts.withLock { $0.sawShutdown += 1 }
                    break
                }
            }
        } catch is CancellationError {
            probe.counts.withLock { $0.cancelled += 1 }
        } catch {
            if Task.isCancelled { probe.counts.withLock { $0.cancelled += 1 } }
        }
        await t.close(.normal)
    }
}

struct NoContentHandler: HTTPHandler {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        HTTPResponse(status: .noContent)
    }
}

/// Polls `condition` every 5 ms until it holds; fails the test after `timeout`.
func eventually(
    timeout: Duration = .seconds(5),
    _ message: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            Issue.record(message ?? "condition not met within \(timeout)", sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Sends `text` and reads until that many bytes come back, or end of stream / an error.
/// Returns what was received.
func roundTrip(_ transport: some ByteStreamTransport, _ text: String) async -> String {
    var out = ByteBuffer()
    out.append(contentsOf: Array(text.utf8))
    do {
        try await transport.send(out, endOfStream: false)
        var received = ByteBuffer()
        while received.readableBytes < out.readableBytes {
            if try await transport.receive(into: &received, maxLength: 4096) == 0 { break }
        }
        return received.withReadableSpan { span in
            String(decoding: (0..<span.count).map { span[$0] }, as: UTF8.self)
        }
    } catch {
        return "<\(error)>"
    }
}

/// True when the peer closed: a receive returns 0 or fails.
func peerClosed(_ transport: some ByteStreamTransport) async -> Bool {
    var buffer = ByteBuffer()
    do {
        return try await transport.receive(into: &buffer, maxLength: 1) == 0
    } catch {
        return true
    }
}
