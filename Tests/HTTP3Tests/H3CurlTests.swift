import Foundation
import HTTP3
import HTTPCore
import HTTPTestSupport
import NetworkTransport
import Testing

/// #0100/#0101 end to end: `HTTP3` over a real `QUICListener` on 127.0.0.1 port 0, driven by
/// Homebrew curl with HTTP/3 (the system curl has none). The identity is the gitignored test
/// identity imported in memory only (AGENTS.md).
@Suite(.timeLimit(.minutes(1)), .enabled(if: FileManager.default.isExecutableFile(atPath: h3CurlPath)))
struct H3CurlTests {
    @Test func curlHTTP3OnlyGets200WithTheBody() async throws {
        let output = try await withQUICServer(handler: PathHandler()) { port in
            try await runCurl(["--http3-only", "-k", "-s", "-S", "--max-time", "15",
                         "-w", "\\n%{http_code} %{http_version}", "https://127.0.0.1:\(port)/hello?q=1"])
        }
        #expect(output == "hello /hello?q=1\n200 3")
    }

    @Test func curlEchoesARequestBody() async throws {
        let output = try await withQUICServer(handler: EchoHandler()) { port in
            try await runCurl(["--http3-only", "-k", "-s", "-S", "--max-time", "15",
                         "--data-binary", "body over h3", "https://127.0.0.1:\(port)/echo"])
        }
        #expect(output == "body over h3")
    }

    @Test func twentyParallelCurlRequestsSucceed() async throws {
        let output = try await withQUICServer(handler: PathHandler()) { port in
            var arguments = ["--http3-only", "-k", "-s", "-S", "--max-time", "30",
                             "--parallel", "--parallel-max", "20", "-w", "%{http_code} %{size_download}\\n"]
            for i in 0..<20 {
                arguments += ["-o", "/dev/null", "https://127.0.0.1:\(port)/f\(i)"]
            }
            return try await runCurl(arguments)
        }
        let lines = output.split(separator: "\n")
        #expect(lines.count == 20)
        #expect(lines.allSatisfy { $0.hasPrefix("200 ") })
    }

    /// #0106: with a QPACK dynamic table advertised, curl's encoder (nghttp3) inserts the
    /// repeated request fields and references them; every request still gets the right answer.
    @Test func curlUsesTheQPACKDynamicTable() async throws {
        let tracker = H3ConnectionTracker()
        let http3 = HTTP3(
            configuration: H3Configuration(qpackMaxTableCapacity: 4096, qpackBlockedStreams: 16), tracker: tracker)
        let handler = ClosureHandler { request in
            var body = ByteBuffer(bytes: Array(request.string(of: request.path).utf8))
            body.append(contentsOf: Array(" ".utf8))
            let fields = request.headers.snapshot()
            let value = fields.firstIndex(named: "x-dynamic").map { fields.valueString(at: $0) } ?? "-"
            body.append(contentsOf: Array(value.utf8))
            return HTTPResponse(status: .ok, body: .bytes(body))
        }
        let output = try await withQUICServer(handler: handler, http3: http3) { port in
            var arguments = ["--http3-only", "-k", "-s", "-S", "--max-time", "30",
                             "-H", "x-dynamic: a value worth indexing", "-w", " %{http_code}\\n"]
            for i in 0..<10 {
                arguments += ["https://127.0.0.1:\(port)/r\(i)"]
            }
            return try await runCurl(arguments)
        }
        let lines = output.split(separator: "\n")
        #expect(lines.count == 10)
        for (i, line) in lines.enumerated() {
            #expect(line == "/r\(i) a value worth indexing 200")
        }
        #expect(tracker.qpackDynamicInserts > 0)
        #expect(tracker.qpackDynamicSections > 0)
    }

    /// #0102: a shutdown while curl waits on a slow handler sends GOAWAY, lets the request
    /// finish, then closes the connection, and the whole server (accept loop and connection
    /// tasks) returns well before QUIC's 10 s idle timeout could have ended it.
    @Test func shutdownDuringASlowRequestLetsCurlFinishAndTheServerExits() async throws {
        let started = Flag()
        let handler = ClosureHandler { _ in
            started.set()
            try await Task.sleep(for: .milliseconds(1500))
            return HTTPResponse(status: .ok, body: .bytes(ByteBuffer("slow done")))
        }
        let material = try TestIdentity.load()
        let identity = try TLSIdentity(pkcs12: material.pkcs12, password: TestIdentity.password)
        let listener = try QUICListener(
            configuration: .init(host: "127.0.0.1", port: 0, quic: QUICConfiguration(alpn: HTTP3.alpnTokens, idleTimeoutMilliseconds: 10_000)),
            identity: identity)
        let port = try await listener.start()
        let shutdown = ShutdownSignal()
        let clock = ContinuousClock()
        let start = clock.now
        let output = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                await withDiscardingTaskGroup { connections in
                    do {
                        for try await connection in listener.connections {
                            connections.addTask {
                                await HTTP3().run(connection, handler: handler,
                                                  context: ConnectionContext(info: connection.info, shutdown: shutdown))
                            }
                        }
                    } catch {}
                }
                return nil
            }
            group.addTask {
                try await runCurl(["--http3-only", "-k", "-s", "-S", "--max-time", "15",
                                   "-w", "\\n%{http_code} %{http_version}", "https://127.0.0.1:\(port)/slow"])
            }
            defer { group.cancelAll() }
            await started.wait()
            // What `Server` does when draining: stop accepting, then signal every connection.
            await listener.close()
            shutdown.trigger()
            var output: String?
            for try await result in group {
                if let result { output = result }
            }
            return output
        }
        #expect(output == "slow done\n200 3")
        #expect(start.duration(to: clock.now) < .seconds(8))
    }
}

/// Homebrew curl, built with HTTP/3 (ngtcp2).
let h3CurlPath = "/opt/homebrew/opt/curl/bin/curl"

/// Serves `handler` with `HTTP3` on a QUIC listener (127.0.0.1, port 0) while `body` runs,
/// then closes the listener and every connection.
func withQUICServer<H: HTTPHandler, R: Sendable>(
    handler: H, http3: HTTP3 = HTTP3(), _ body: @Sendable (UInt16) async throws -> R
) async throws -> R {
    let material = try TestIdentity.load()
    let identity = try TLSIdentity(pkcs12: material.pkcs12, password: TestIdentity.password)
    let listener = try QUICListener(
        configuration: .init(host: "127.0.0.1", port: 0, quic: QUICConfiguration(alpn: HTTP3.alpnTokens, idleTimeoutMilliseconds: 10_000)),
        identity: identity)
    let port = try await listener.start()
    let shutdown = ShutdownSignal()
    return try await withThrowingTaskGroup(of: R?.self) { group in
        group.addTask {
            await withDiscardingTaskGroup { connections in
                do {
                    for try await connection in listener.connections {
                        connections.addTask {
                            await http3.run(connection, handler: handler,
                                            context: ConnectionContext(info: connection.info, shutdown: shutdown))
                        }
                    }
                } catch {}
                shutdown.trigger()
            }
            return nil
        }
        defer { group.cancelAll() }
        let result: R
        do {
            result = try await body(port)
        } catch {
            shutdown.trigger()
            await listener.close()
            throw error
        }
        shutdown.trigger()
        await listener.close()
        try await group.waitForAll()
        return result
    }
}

/// Runs curl and returns its stdout. curl enforces its own `--max-time`; a hard deadline and
/// the test's time limit (cancellation) SIGKILL it otherwise (#0114).
func runCurl(_ arguments: [String]) async throws -> String {
    try await ChildProcess.run(URL(fileURLWithPath: h3CurlPath), arguments, timeout: .seconds(40)).stdout
}
