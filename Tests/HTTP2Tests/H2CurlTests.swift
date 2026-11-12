import Foundation
import Synchronization
import HTTP1
import HTTP2
import HTTPCore
import HTTPServer
import HTTPTestSupport
import NetworkTransport
import Testing

/// #0042–#0044 end to end: `HTTP2` registered before `HTTP1` on a real `Server`, loopback,
/// port 0, driven by the system curl (nghttp2). TLS uses the gitignored test identity imported
/// in memory only (AGENTS.md); curl accepts it with `-k`.
@Suite(.timeLimit(.minutes(1)))
struct H2CurlTests {
    static let protocols: [any ConnectionProtocol] = [HTTP2(), HTTP1()]

    /// Runs a server with one listener, calls `body` with its port and the server, then drains it.
    static func withServer(
        tls: Bool, _ body: @Sendable (UInt16, Server<TCPListener, HelloHandler>) async throws -> Void
    ) async throws {
        try await withServer(tls: tls, handler: HelloHandler(), body)
    }

    static func withServer<H: HTTPHandler>(
        tls: Bool, handler: H, http2: HTTP2Configuration = HTTP2Configuration(), drainTimeout: Duration = .seconds(2),
        _ body: @Sendable (UInt16, Server<TCPListener, H>) async throws -> Void
    ) async throws {
        var tlsConfiguration: TLSConfiguration?
        if tls {
            let material = try TestIdentity.load()
            let identity = try TLSIdentity(pkcs12: material.pkcs12, password: TestIdentity.password)
            tlsConfiguration = TLSConfiguration(identity: identity, alpn: ProtocolRegistry(protocols).alpnTokens)
        }
        let listener = try TCPListener(
            configuration: .init(host: "127.0.0.1", port: 0, tcp: TCPConfiguration(allowLocalEndpointReuse: false)),
            tls: tlsConfiguration)
        let server = Server(configuration: ServerConfiguration(drainTimeout: drainTimeout),
                            listeners: [listener], protocols: [HTTP2(configuration: http2), HTTP1()], handler: handler)
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            defer { server.requestShutdown() }
            guard let port = try await server.waitUntilRunning().first?.port else {
                Issue.record("no address")
                return
            }
            try await body(port, server)
            server.requestShutdown()
            try await group.waitForAll()
        }
    }

    static func curl(_ arguments: [String]) async throws -> (Int32, String) {
        let output = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"), arguments,
                                                timeout: .seconds(30), mergeStandardError: true)
        return (output.status, output.stdout)
    }

    @Test func curlWithPriorKnowledgeGets200() async throws {
        try await Self.withServer(tls: false) { port, server in
            let (status, output) = try await Self.curl([
                "-sS", "--http2-prior-knowledge", "--max-time", "10", "-w", "\n%{http_code} %{http_version}",
                "http://127.0.0.1:\(port)/hello"])
            #expect(status == 0, "\(output)")
            #expect(output == "hello /hello\n200 2", "\(output)")
            // HTTP/1.1 still works on the same listener.
            let (status1, output1) = try await Self.curl([
                "-sS", "--http1.1", "--max-time", "10", "-w", "\n%{http_code} %{http_version}",
                "http://127.0.0.1:\(port)/one"])
            #expect(status1 == 0, "\(output1)")
            #expect(output1 == "hello /one\n200 1.1", "\(output1)")
            #expect(server.acceptedConnectionCount == 2)
        }
    }

    @Test func curlOverTLSNegotiatesH2() async throws {
        try await Self.withServer(tls: true) { port, _ in
            let (status, output) = try await Self.curl([
                "-sS", "-v", "--http2", "-k", "--max-time", "10", "-w", "\n%{http_code} %{http_version}",
                "https://127.0.0.1:\(port)/secure"])
            #expect(status == 0, "\(output)")
            #expect(output.contains("hello /secure\n200 2"), "\(output)")
            #expect(output.contains("ALPN: server accepted h2") || output.contains("ALPN, server accepted to use h2"),
                    "\(output)")
        }
    }

    /// Several requests on one connection, some concurrently.
    @Test func curlMultiplexesOneConnection() async throws {
        try await Self.withServer(tls: false) { port, server in
            var arguments = ["-sS", "--http2-prior-knowledge", "--max-time", "20", "--parallel", "--parallel-max", "10",
                             "-w", "%{http_code} %{http_version}\\n"]
            for i in 0..<10 { arguments += ["-o", "/dev/null", "http://127.0.0.1:\(port)/f\(i)"] }
            let (status, output) = try await Self.curl(arguments)
            #expect(status == 0, "\(output)")
            let lines = output.split(separator: "\n")
            #expect(lines.count == 10, "\(output)")
            #expect(lines.allSatisfy { $0 == "200 2" }, "\(output)")
            #expect(server.acceptedConnectionCount == 1)
        }
    }
    // MARK: Request bodies (#0048)

    /// Answers a POST with its body's length and byte sum, read as the client sends it.
    struct BodySumHandler: HTTPHandler {
        func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
            var count = 0
            var sum: UInt64 = 0
            for try await chunk in request.body {
                count += chunk.readableBytes
                chunk.withUnsafeReadableBytes { for byte in $0 { sum &+= UInt64(byte) } }
            }
            return HTTPResponse(body: .bytes(ByteBuffer(bytes: Array("\(count) \(sum)".utf8))))
        }
    }

    /// `curl --data-binary @file` with a body many times the stream window: it arrives whole,
    /// paced by the WINDOW_UPDATEs the handler's reads return.
    @Test func curlPostsALargeBody() async throws {
        let size = 3 * 1024 * 1024 + 17
        var bytes = [UInt8](repeating: 0, count: size)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in 0..<size {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[i] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        let sum = bytes.reduce(UInt64(0)) { $0 &+ UInt64($1) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sws-h2-body-\(UUID().uuidString).bin")
        try Data(bytes).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await Self.withServer(tls: false, handler: BodySumHandler()) { port, _ in
            let (status, output) = try await Self.curl([
                "-sS", "--http2-prior-knowledge", "--max-time", "20", "--data-binary", "@\(file.path)",
                "-w", "\n%{http_code} %{http_version}", "http://127.0.0.1:\(port)/upload"])
            #expect(status == 0, "\(output)")
            #expect(output == "\(size) \(sum)\n200 2", "\(output)")
        }
    }
    // MARK: Responses (#0049)

    /// Serves files from `Root/Public` (`/` is `index.html`), with a short pause first so that
    /// parallel requests overlap; records how many handlers ran at once.
    final class PublicFilesHandler: HTTPHandler {
        let inFlight = Mutex((now: 0, peak: 0))

        func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
            inFlight.withLock {
                $0.now += 1
                $0.peak = Swift.max($0.peak, $0.now)
            }
            defer { inFlight.withLock { $0.now -= 1 } }
            try await Task.sleep(for: .milliseconds(20))
            var path = request.string(of: request.path)
            if path == "/" { path = "/index.html" }
            guard !path.contains("..") else { return HTTPResponse(status: .notFound) }
            do {
                let file = try OwnedFileDescriptor.openForReading(path: TestIdentity.repositoryRoot + "/Root/Public" + path)
                return HTTPResponse(body: .file(try FileRegion.entireFile(file)))
            } catch {
                return HTTPResponse(status: .notFound)
            }
        }
    }

    @Test func curlGetsTheIndexPage() async throws {
        let index = try String(contentsOfFile: TestIdentity.repositoryRoot + "/Root/Public/index.html", encoding: .utf8)
        try await Self.withServer(tls: false, handler: PublicFilesHandler()) { port, _ in
            let (status, output) = try await Self.curl([
                "-sS", "--http2-prior-knowledge", "--max-time", "10", "-w", "\n%{http_code} %{http_version}",
                "http://localhost:\(port)/"])
            #expect(status == 0, "\(output)")
            #expect(output == index + "\n200 2")
        }
    }

    /// 50 transfers with `--parallel` (`-Z`) share one connection as concurrent streams:
    /// curl's verbose log shows one connection and multiplexing, and the handlers overlap.
    @Test func curlFetchesFiftyURLsOverOneConnection() async throws {
        let handler = PublicFilesHandler()
        let files = ["/", "/index.html", "/favicon.ico", "/swift.png"]
        try await Self.withServer(tls: false, handler: handler) { port, server in
            var arguments = ["-sS", "-v", "--http2-prior-knowledge", "--max-time", "20", "-Z", "--parallel-max", "50",
                             "-w", "%{http_code} %{http_version} %{num_connects}\\n"]
            for i in 0..<50 { arguments += ["-o", "/dev/null", "http://127.0.0.1:\(port)\(files[i % files.count])"] }
            let (status, output) = try await Self.curl(arguments)
            #expect(status == 0, "\(output)")
            let results = output.split(separator: "\n").filter { $0.hasPrefix("200 ") }
            #expect(results.count == 50, "\(output)")
            #expect(results.allSatisfy { $0.hasPrefix("200 2 ") }, "\(output)")
            // Only one transfer had to connect; the rest multiplexed onto it.
            #expect(results.filter { $0 == "200 2 1" }.count == 1, "\(output)")
            #expect(output.lowercased().contains("multiplex"), "\(output)")
            #expect(server.acceptedConnectionCount == 1)
            #expect(handler.inFlight.withLock { $0.peak } > 1)
        }
    }
}
