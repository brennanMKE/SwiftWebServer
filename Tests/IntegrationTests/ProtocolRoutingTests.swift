import Foundation
import HTTP1
import HTTPCore
import HTTPServer
import HTTPTestSupport
import NetworkTransport
import Testing

/// Protocol selection (#0088): by negotiated ALPN on TLS connections, by sniffing the first
/// bytes on cleartext ones (with the sniff timeout), and `sws-bench serve --tls`.
@Suite struct ProtocolRoutingTests {
    typealias TextHandler = TLSIntegrationTests.TextHandler

    /// A protocol with ALPN token `x-test` and cleartext preface `XTEST`: it answers
    /// `x-test alpn=<token>\n` once and closes.
    struct XTestProtocol: ConnectionProtocol {
        static let preface = Array("XTEST".utf8)
        static var alpnTokens: [String] { ["x-test"] }

        static func matchesCleartextPreface(_ bytes: borrowing ByteBuffer) -> SniffResult {
            let prefix = bytes.withUnsafeReadableBytes { [UInt8]($0.prefix(preface.count)) }
            guard prefix == Array(preface.prefix(prefix.count)) else { return .noMatch }
            return prefix.count == preface.count ? .match : .needMoreBytes
        }

        func run<T: ByteStreamTransport, H: HTTPHandler>(_ t: T, handler: H, context: ConnectionContext) async {
            var input = ByteBuffer()
            // Read the preface (replayed by the registry for cleartext) when it is sent.
            if !context.info.isSecure {
                while input.readableBytes < Self.preface.count {
                    guard (try? await t.receive(into: &input, maxLength: 64)) ?? 0 > 0 else { break }
                }
            }
            let preface = input.withUnsafeReadableBytes { String(decoding: $0, as: UTF8.self) }
            var out = ByteBuffer()
            out.append(contentsOf: Array("x-test alpn=\(context.info.negotiatedALPN ?? "none") preface=\(preface)\n".utf8))
            try? await t.send(out, endOfStream: true)
            await t.close(.normal)
        }
    }

    static func withTLSServer(
        protocols: [any ConnectionProtocol],
        _ body: @Sendable (UInt16, Server<TCPListener, TextHandler>) async throws -> Void
    ) async throws {
        // The listener offers exactly the registered protocols' tokens.
        try await TLSIntegrationTests.withTLSServer(
            protocols: protocols, alpn: ProtocolRegistry(protocols).alpnTokens, body)
    }

    // MARK: Registry routing

    /// An NW TLS client offering `x-test` reaches the fake protocol; one offering `http/1.1`
    /// and one offering no ALPN reach HTTP/1.1.
    @Test(.timeLimit(.minutes(1)))
    func alpnRoutesToTheRegisteredProtocol() async throws {
        let (_, certificate) = try TLSIntegrationTests.identity()
        try await Self.withTLSServer(protocols: [XTestProtocol(), HTTP1()]) { port, _ in
            let xtest = try await TCPTransport.connect(
                host: "127.0.0.1", port: port,
                tls: TLSClientConfiguration(alpn: ["x-test"], pinnedCertificate: certificate))
            #expect(xtest.info.negotiatedALPN == "x-test")
            #expect(await readAll(xtest) == "x-test alpn=x-test preface=\n")
            await xtest.close(.normal)

            for alpn in [["http/1.1"], []] {
                let client = try await TCPTransport.connect(
                    host: "127.0.0.1", port: port,
                    tls: TLSClientConfiguration(alpn: alpn, pinnedCertificate: certificate))
                #expect(client.info.negotiatedALPN == alpn.first)
                var request = ByteBuffer()
                request.append(contentsOf: Array("GET /h1 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8))
                try await client.send(request, endOfStream: false)
                let response = await readAll(client)
                #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"), "ALPN \(alpn): \(response)")
                #expect(response.hasSuffix("path=/h1\n"), "ALPN \(alpn): \(response)")
                await client.close(.normal)
            }
        }
    }

    /// Cleartext: the fake preface split over two sends is sniffed and replayed to the fake
    /// protocol; a request line goes to HTTP/1.1.
    @Test(.timeLimit(.minutes(1)))
    func cleartextSniffRoutesSplitPreface() async throws {
        try await Self.withCleartextServer(sniffTimeout: .seconds(10)) { port in
            let client = try await TCPTransport.connect(host: "127.0.0.1", port: port)
            var first = ByteBuffer()
            first.append(contentsOf: Array("XT".utf8))
            try await client.send(first, endOfStream: false)
            try await Task.sleep(for: .milliseconds(50))
            var second = ByteBuffer()
            second.append(contentsOf: Array("EST".utf8))
            try await client.send(second, endOfStream: false)
            #expect(await readAll(client) == "x-test alpn=none preface=XTEST\n")
            await client.close(.normal)

            let h1 = try await TCPTransport.connect(host: "127.0.0.1", port: port)
            var request = ByteBuffer()
            request.append(contentsOf: Array("GET /plain HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8))
            try await h1.send(request, endOfStream: false)
            let response = await readAll(h1)
            #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(response)")
            #expect(response.hasSuffix("path=/plain\n"), "\(response)")
            await h1.close(.normal)
        }
    }

    /// Cleartext: a client that sends nothing while the registry sniffs is closed after the
    /// sniff timeout (the gap the #0082 report flagged), and so is one that stalls mid-preface.
    @Test(.timeLimit(.minutes(1)))
    func sniffTimeoutClosesSilentClients() async throws {
        try await Self.withCleartextServer(sniffTimeout: .milliseconds(400)) { port in
            for partial in ["", "XT"] {
                let client = try await TCPTransport.connect(host: "127.0.0.1", port: port)
                if !partial.isEmpty {
                    var bytes = ByteBuffer()
                    bytes.append(contentsOf: Array(partial.utf8))
                    try await client.send(bytes, endOfStream: false)
                }
                let start = ContinuousClock.now
                let closed = await peerClosed(client)
                let elapsed = ContinuousClock.now - start
                #expect(closed)
                #expect(elapsed >= .milliseconds(300) && elapsed < .seconds(5), "\(partial): closed after \(elapsed)")
                await client.close(.normal)
            }
        }
    }

    static func withCleartextServer(
        sniffTimeout: Duration, _ body: @Sendable (UInt16) async throws -> Void
    ) async throws {
        let listener = try BSDSocketListener(configuration: .init(host: "127.0.0.1", port: 0))
        let server = Server(
            configuration: ServerConfiguration(drainTimeout: .milliseconds(200), sniffTimeout: sniffTimeout),
            listeners: [listener], protocols: [XTestProtocol(), HTTP1()], handler: TextHandler())
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            defer { server.requestShutdown() }
            guard let port = try await server.waitUntilRunning().first?.port else {
                Issue.record("no address"); return
            }
            try await body(port)
            server.requestShutdown()
            try await group.waitForAll()
        }
    }

    // MARK: sws-bench serve --tls

    @Test(.timeLimit(.minutes(1)))
    func serveTLSAnswersCurl() async throws {
        let material = try TestIdentity.load()
        let serve = try ChildProcess.launch(["serve", "--tls", "--identity", material.directory + "/server.p12",
                                             "--port", "0", "--drain-timeout", "0.5"])
        defer { serve.kill() }
        let port = try await serve.listeningPort()
        let (status, output) = try await runCurl(["-sv", "-k", "--max-time", "10", "https://127.0.0.1:\(port)/"])
        #expect(status == 0, "\(output)")
        #expect(output.contains("ALPN: server accepted http/1.1")
                || output.contains("ALPN, server accepted to use http/1.1"), "\(output)")
        #expect(output.contains("< HTTP/1.1 200 OK"), "\(output)")
        #expect(output.contains("Hello, World!"), "\(output)")
        serve.signal(SIGTERM)
        #expect(try await serve.waitForExit(timeout: .seconds(5)) == 0, "stderr: \(serve.stderr)")
    }

    @Test(.timeLimit(.minutes(1)))
    func serveTLSWithWrongPasswordExits1NamingTheFile() async throws {
        let material = try TestIdentity.load()
        let path = material.directory + "/server.p12"
        let serve = try ChildProcess.launch(["serve", "--tls", "--identity", path, "--password", "wrong", "--port", "0"])
        defer { serve.kill() }
        #expect(try await serve.waitForExit(timeout: .seconds(10)) == 1)
        #expect(serve.stderr.contains(path), "stderr: \(serve.stderr)")
    }

    // MARK: Helpers

    func readAll(_ transport: some ByteStreamTransport) async -> String {
        await TLSIntegrationTests().readAll(transport)
    }

    func runCurl(_ arguments: [String]) async throws -> (Int32, String) {
        try await TLSIntegrationTests().runCurl(arguments)
    }
}
