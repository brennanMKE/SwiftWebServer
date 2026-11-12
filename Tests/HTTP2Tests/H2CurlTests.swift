import Foundation
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
        var tlsConfiguration: TLSConfiguration?
        if tls {
            let material = try TestIdentity.load()
            let identity = try TLSIdentity(pkcs12: material.pkcs12, password: TestIdentity.password)
            tlsConfiguration = TLSConfiguration(identity: identity, alpn: ProtocolRegistry(protocols).alpnTokens)
        }
        let listener = try TCPListener(
            configuration: .init(host: "127.0.0.1", port: 0, tcp: TCPConfiguration(allowLocalEndpointReuse: false)),
            tls: tlsConfiguration)
        let server = Server(configuration: ServerConfiguration(drainTimeout: .seconds(2)),
                            listeners: [listener], protocols: protocols, handler: HelloHandler())
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
}
