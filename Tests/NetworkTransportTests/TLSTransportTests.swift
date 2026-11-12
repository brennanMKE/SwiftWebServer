import Foundation
import HTTPCore
import HTTPTestSupport
import Network
import NetworkTransport
import Security
import Synchronization
import Testing

/// The TLS listener (#0087) and ALPN in `ConnectionInfo` (#0088). Every test binds 127.0.0.1
/// port 0 and uses the in-memory test identity; clients pin the test certificate in-process,
/// so nothing touches the keychain or trust settings (AGENTS.md).
@Suite struct TLSTransportTests {
    static func tlsConfiguration(
        alpn: [String] = ["http/1.1"], handshakeTimeout: Duration = .seconds(10)
    ) throws -> TLSConfiguration {
        let (identity, _) = try quicTestIdentity()
        return TLSConfiguration(identity: identity, alpn: alpn, handshakeTimeout: handshakeTimeout)
    }

    static func client(alpn: [String] = ["http/1.1"], maximumVersion: TLSVersion? = nil) throws -> TLSClientConfiguration {
        let (_, certificate) = try quicTestIdentity()
        return TLSClientConfiguration(alpn: alpn, pinnedCertificate: certificate, maximumVersion: maximumVersion)
    }

    static func makeListener(_ tls: TLSConfiguration) async throws -> TCPListener {
        let listener = try TCPListener(configuration: .init(host: "127.0.0.1", port: 0), tls: tls)
        try await listener.start()
        return listener
    }

    static func accept(_ listener: TCPListener) async throws -> TCPTransport {
        var iterator = listener.connections.makeAsyncIterator()
        guard let transport = try await iterator.next() else { throw TransportError.closed }
        return transport
    }

    @Test(.timeLimit(.minutes(1)))
    func identityLoadsFromConfiguration() throws {
        let material = try TestIdentity.load()
        let path = material.directory + "/server.p12"
        let tls = try TLSConfiguration(pkcs12Path: path, password: TestIdentity.password)
        #expect(tls.identity.certificateDER == material.certificateDER)
        #expect(tls.minimumVersion == .v1_2)
        #expect(tls.alpn == ["http/1.1"])
        #expect(tls.clientAuthentication == nil)
        #expect(throws: TLSIdentityError.importFailed(status: errSecAuthFailed)) {
            _ = try TLSConfiguration(pkcs12Path: path, password: "wrong password")
        }
        #expect(throws: TLSIdentityError.fileUnreadable(path: "/nonexistent/server.p12")) {
            _ = try TLSConfiguration(pkcs12Path: "/nonexistent/server.p12", password: "x")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func echoOverTLSReportsALPNAndVersion() async throws {
        let listener = try await Self.makeListener(try Self.tlsConfiguration(alpn: ["x-test", "http/1.1"]))
        defer { Task { await listener.close() } }
        async let accepted = Self.accept(listener)
        let client = try await TCPTransport.connect(
            host: "127.0.0.1", port: listener.port, tls: try Self.client(alpn: ["x-test"]))
        let server = try await accepted

        #expect(server.info.isSecure)
        #expect(server.info.negotiatedALPN == "x-test")
        #expect(server.info.tlsVersion == .v1_3)
        #expect(client.info.isSecure)
        #expect(client.info.negotiatedALPN == "x-test")
        #expect(server.info.remoteAddress?.host == "127.0.0.1")

        var out = ByteBuffer()
        out.append(contentsOf: Array("hello over tls".utf8))
        try await client.send(out, endOfStream: false)
        let received = try await receive(server, exactly: out.readableBytes)
        #expect(received.bytes == Array("hello over tls".utf8))
        try await server.send(received, endOfStream: true)
        let echoed = try await receive(client, exactly: out.readableBytes)
        #expect(echoed.bytes == Array("hello over tls".utf8))

        await client.close(.normal)
        await server.close(.normal)
    }

    @Test(.timeLimit(.minutes(1)))
    func tls12IsAcceptedAndNoALPNIsReportedAsNil() async throws {
        let listener = try await Self.makeListener(try Self.tlsConfiguration())
        defer { Task { await listener.close() } }
        async let accepted = Self.accept(listener)
        let client = try await TCPTransport.connect(
            host: "127.0.0.1", port: listener.port, tls: try Self.client(alpn: [], maximumVersion: .v1_2))
        let server = try await accepted
        #expect(server.info.isSecure)
        #expect(server.info.tlsVersion == .v1_2)
        #expect(server.info.negotiatedALPN == nil)
        await client.close(.normal)
        await server.close(.normal)
    }

    /// A cleartext client on the TLS port: the handshake fails, the connection is closed and
    /// never handed over, and the listener keeps serving.
    @Test(.timeLimit(.minutes(1)))
    func garbageHandshakeIsClosedAndListenerSurvives() async throws {
        let listener = try await Self.makeListener(try Self.tlsConfiguration())
        defer { Task { await listener.close() } }

        let raw = RawClient(port: listener.port)
        try await raw.start()
        try await raw.send(Array("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8) + [UInt8](repeating: 0x16, count: 64))
        // The server answers with a TLS alert at most, then closes.
        var ended = false
        for _ in 0..<8 {
            let (_, isComplete, error) = await raw.receive()
            if isComplete || error != nil { ended = true; break }
        }
        #expect(ended)
        raw.cancel()
        try await waitFor { listener.failedHandshakeCount == 1 }
        #expect(listener.pendingConnectionCount == 0)

        try await expectGoodHandshake(listener)
    }

    /// A client offering only an ALPN token the server does not accept: Network.framework
    /// ends the handshake with a `no_application_protocol` alert (RFC 7301 §3.2). The server
    /// counts the failure, hands nothing over, and serves the next client.
    @Test(.timeLimit(.minutes(1)))
    func wrongALPNSurvives() async throws {
        let listener = try await Self.makeListener(try Self.tlsConfiguration())
        defer { Task { await listener.close() } }

        await #expect(throws: (any Error).self) {
            _ = try await TCPTransport.connect(
                host: "127.0.0.1", port: listener.port, tls: try Self.client(alpn: ["x-unknown"]))
        }
        try await waitFor { listener.failedHandshakeCount == 1 }
        #expect(listener.pendingConnectionCount == 0)
        try await expectGoodHandshake(listener)
    }

    /// A client that connects and sends nothing is reset after the handshake timeout and does
    /// not hold a pending slot.
    @Test(.timeLimit(.minutes(1)))
    func silentClientHitsHandshakeTimeout() async throws {
        let listener = try await Self.makeListener(
            try Self.tlsConfiguration(handshakeTimeout: .milliseconds(300)))
        defer { Task { await listener.close() } }

        let raw = RawClient(port: listener.port)
        try await raw.start()
        let start = ContinuousClock.now
        let (_, isComplete, error) = await raw.receive()
        let elapsed = ContinuousClock.now - start
        #expect(isComplete || error != nil)
        #expect(elapsed >= .milliseconds(250) && elapsed < .seconds(5), "closed after \(elapsed)")
        raw.cancel()
        try await waitFor { listener.failedHandshakeCount == 1 }
        #expect(listener.pendingConnectionCount == 0)
        try await expectGoodHandshake(listener)
    }

    /// A client whose verify block rejects the server: the server sees a failed handshake.
    @Test(.timeLimit(.minutes(1)))
    func rejectedCertificateFailsOnBothSides() async throws {
        let listener = try await Self.makeListener(try Self.tlsConfiguration())
        defer { Task { await listener.close() } }
        let wrongPin = TLSClientConfiguration(pinnedCertificate: [0x30, 0x00])
        await #expect(throws: (any Error).self) {
            _ = try await TCPTransport.connect(host: "127.0.0.1", port: listener.port, tls: wrongPin)
        }
        try await waitFor { listener.failedHandshakeCount == 1 }
        try await expectGoodHandshake(listener)
    }

    @Test(.timeLimit(.minutes(1)))
    func clientAuthenticationHookRuns() async throws {
        let (identity, _) = try quicTestIdentity()
        let seen = Mutex<Int>(0)
        let tls = TLSConfiguration(
            identity: identity,
            clientAuthentication: .init(required: true) { _ in
                seen.withLock { $0 += 1 }
                return true
            })
        let listener = try await Self.makeListener(tls)
        defer { Task { await listener.close() } }
        // A client without a certificate is refused when one is required.
        var refused = false
        do {
            let client = try await TCPTransport.connect(host: "127.0.0.1", port: listener.port, tls: try Self.client())
            // In TLS 1.3 the client is ready before the server checks its (missing)
            // certificate, so the refusal shows up as the connection ending.
            var buffer = ByteBuffer()
            refused = try await client.receive(into: &buffer, maxLength: 1) == 0
            await client.close(.normal)
        } catch {
            refused = true
        }
        #expect(refused)
        try await waitFor { listener.failedHandshakeCount == 1 }
        #expect(seen.withLock { $0 } == 0)
    }

    // MARK: Helpers

    /// A well-behaved client still completes a handshake and exchanges bytes.
    func expectGoodHandshake(_ listener: TCPListener) async throws {
        async let accepted = Self.accept(listener)
        let client = try await TCPTransport.connect(host: "127.0.0.1", port: listener.port, tls: try Self.client())
        let server = try await accepted
        #expect(server.info.negotiatedALPN == "http/1.1")
        var out = ByteBuffer()
        out.append(contentsOf: [1, 2, 3])
        try await client.send(out, endOfStream: false)
        #expect(try await receive(server, exactly: 3).bytes == [1, 2, 3])
        await client.close(.normal)
        await server.close(.normal)
    }

    func waitFor(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("condition not met within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
