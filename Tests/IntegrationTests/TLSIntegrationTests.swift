import Foundation
import HTTP1
import HTTPCore
import HTTPServer
import HTTPTestSupport
import NetworkTransport
import Security
import Testing

/// HTTPS on a `Server` (#0087). Loopback, port 0, the in-memory test identity; clients accept the test certificate
/// in-process (curl `-k`, a pinning `URLSession` delegate, a pinning NW client). Nothing
/// touches the keychain or trust settings (AGENTS.md).
@Suite struct TLSIntegrationTests {
    struct TextHandler: HTTPHandler {
        func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
            var body = ByteBuffer()
            body.append(contentsOf: Array("path=\(request.string(of: request.path))\n".utf8))
            return HTTPResponse(body: .bytes(body))
        }
    }

    static func identity() throws -> (TLSIdentity, [UInt8]) {
        let material = try TestIdentity.load()
        return (try TLSIdentity(pkcs12: material.pkcs12, password: TestIdentity.password), material.certificateDER)
    }

    /// Runs an HTTP/1.1 server with a TLS listener (ALPN `http/1.1`), calls `body` with the
    /// port, then drains it.
    static func withTLSServer(
        protocols: [any ConnectionProtocol] = [HTTP1()],
        alpn: [String] = ["http/1.1"],
        _ body: @Sendable (UInt16, Server<TCPListener, TextHandler>) async throws -> Void
    ) async throws {
        let (identity, _) = try identity()
        let tls = TLSConfiguration(identity: identity, alpn: alpn)
        let listener = try TCPListener(configuration: .init(
            host: "127.0.0.1", port: 0, tcp: TCPConfiguration(allowLocalEndpointReuse: false)), tls: tls)
        let server = Server(configuration: ServerConfiguration(drainTimeout: .milliseconds(200)),
                            listeners: [listener], protocols: protocols, handler: TextHandler())
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            defer { server.requestShutdown() }
            guard let port = try await server.waitUntilRunning().first?.port else {
                Issue.record("no address"); return
            }
            try await body(port, server)
            server.requestShutdown()
            try await group.waitForAll()
        }
    }

    // MARK: curl

    @Test(.timeLimit(.minutes(1)))
    func curlGets200OverHTTPS() async throws {
        try await Self.withTLSServer { port, _ in
            let (status, output) = try await runCurl(["-sk", "--max-time", "10", "-w", "\n%{http_code} %{http_version}",
                                                      "https://127.0.0.1:\(port)/index.html"])
            #expect(status == 0, "\(output)")
            #expect(output.contains("path=/index.html"), "\(output)")
            #expect(output.hasSuffix("200 1.1"), "\(output)")
        }
    }

    /// `curl -v --http1.1 -k` shows the server accepted `http/1.1` by ALPN, and the second URL
    /// reuses the TLS connection (keep-alive over TLS).
    @Test(.timeLimit(.minutes(1)))
    func curlNegotiatesHTTP11AndKeepsAlive() async throws {
        try await Self.withTLSServer { port, server in
            let base = "https://127.0.0.1:\(port)"
            let (status, output) = try await runCurl(["-sv", "--http1.1", "-k", "--max-time", "10",
                                                      "\(base)/a", "\(base)/b", "\(base)/c"])
            #expect(status == 0, "\(output)")
            #expect(output.contains("ALPN: server accepted http/1.1")
                    || output.contains("ALPN, server accepted to use http/1.1"), "\(output)")
            #expect(output.contains("path=/a") && output.contains("path=/b") && output.contains("path=/c"))
            #expect(output.contains("Re-using existing connection") || output.contains("Reusing existing"),
                    "curl did not reuse the connection:\n\(output)")
            #expect(server.acceptedConnectionCount == 1)
        }
    }

    // MARK: URLSession

    final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
        let certificate: [UInt8]

        init(certificate: [UInt8]) {
            self.certificate = certificate
        }

        /// Trusts exactly the test certificate, for this session only. No keychain or trust
        /// settings are read or changed.
        func urlSession(
            _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust
            else { return (.performDefaultHandling, nil) }
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
            guard let leaf = chain?.first, [UInt8](SecCertificateCopyData(leaf) as Data) == certificate else {
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func urlSessionFetchesOverTLS() async throws {
        let (_, certificate) = try Self.identity()
        try await Self.withTLSServer { port, _ in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: configuration,
                                     delegate: PinningDelegate(certificate: certificate), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            for path in ["/one", "/two"] {
                let (data, response) = try await session.data(from: URL(string: "https://127.0.0.1:\(port)\(path)")!)
                let http = try #require(response as? HTTPURLResponse)
                #expect(http.statusCode == 200)
                #expect(String(decoding: data, as: UTF8.self) == "path=\(path)\n")
            }
        }
    }

    // MARK: Helpers

    /// Reads until end of stream (or an error) and returns the text.
    func readAll(_ transport: some ByteStreamTransport) async -> String {
        var buffer = ByteBuffer()
        while (try? await transport.receive(into: &buffer, maxLength: 4096)) ?? 0 > 0 {}
        return buffer.withUnsafeReadableBytes { String(decoding: $0, as: UTF8.self) }
    }

    /// Runs `/usr/bin/curl` with a deadline and returns its status and combined output. A
    /// timeout or a cancellation SIGKILLs curl (#0114).
    func runCurl(_ arguments: [String]) async throws -> (Int32, String) {
        let output = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"), arguments,
                                                timeout: .seconds(30), mergeStandardError: true)
        return (output.status, output.stdout)
    }
}
