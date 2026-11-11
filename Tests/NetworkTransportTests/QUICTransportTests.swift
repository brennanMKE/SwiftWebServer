import Foundation
import HTTPCore
import HTTPTestSupport
import Network
@testable import NetworkTransport
import Synchronization
import Testing

/// Network.framework QUIC adapter tests (#0098) that do not apply to the in-memory transport.
/// The shared behaviour is in `MultiplexedTransportConformanceTests`. Loopback, port 0, and a
/// time limit on every test (AGENTS.md); run through `scripts/guarded.sh`.
@Suite struct QUICTransportTests {
    // MARK: Identity (#0072)

    @Test(.timeLimit(.minutes(1)))
    func testIdentityLoadsInMemoryAndMatchesTheCertificateFile() throws {
        let material = try TestIdentity.load()
        let identity = try TLSIdentity(pkcs12: material.pkcs12, password: TestIdentity.password)
        #expect(identity.certificateDER == material.certificateDER)
        #expect(throws: TLSIdentityError.self) {
            _ = try TLSIdentity(pkcs12: material.pkcs12, password: "wrong password")
        }
        #expect(throws: TLSIdentityError.fileUnreadable(path: "/nonexistent/server.p12")) {
            _ = try TLSIdentity(pkcs12Path: "/nonexistent/server.p12", password: TestIdentity.password)
        }
    }

    // MARK: Listener

    @Test(.timeLimit(.minutes(1)))
    func listenerBindsLoopbackPortZeroAndReportsConnectionInfo() async throws {
        let (listener, client, server) = try await makeQUICPair()
        #expect(listener.port != 0)
        #expect(server.info.negotiatedALPN == "h3")
        #expect(server.info.isSecure)
        #expect(client.info.negotiatedALPN == "h3")
        #expect(client.info.remoteAddress == TransportAddress(host: "127.0.0.1", port: listener.port))

        let stream = try await client.openBidirectionalStream()
        try await stream.send(ByteBuffer("x"), endOfStream: true)
        let peer = try await acceptStream(server)
        #expect(peer.info.localAddress == TransportAddress(host: "127.0.0.1", port: listener.port))
        #expect(peer.info.remoteAddress?.host == "127.0.0.1")
        #expect(peer.info.negotiatedALPN == "h3")
        #expect(!peer.isLocallyInitiated && stream.isLocallyInitiated)

        await client.close(applicationError: 0x100)
        await server.close(applicationError: 0x100)
        await listener.close()
        await listener.close()   // idempotent
    }

    @Test(.timeLimit(.minutes(1)))
    func clientWithTheWrongPinnedCertificateFailsToConnect() async throws {
        let listener = try await makeQUICListener()
        // The refused handshake is not reported to the client group (it stays `waiting`), so
        // the connect timeout ends it.
        await #expect(throws: TransportError.timedOut) {
            _ = try await QUICConnection.connect(
                host: "127.0.0.1", port: listener.port,
                configuration: .init(
                    quic: testQUICConfiguration(), peerVerification: .pinnedCertificate([1, 2, 3]),
                    connectTimeout: .seconds(2)))
        }
        #expect(listener.pendingConnectionCount == 0)
        await listener.close()
    }

    // MARK: Against a raw Network.framework client

    @Test(.timeLimit(.minutes(1)))
    func echoUniAndResetAgainstARawNWClient() async throws {
        let listener = try await makeQUICListener()
        let (_, certificate) = try quicTestIdentity()
        let client = RawQUICClient(port: listener.port, certificate: certificate)
        try await client.start()
        let server = try await accept(listener)

        // Bidirectional echo, FIN both ways.
        let stream = try await client.openStream()
        try await RawQUICClient.send(stream, Array("hello ".utf8), final: false)
        let peer = try await acceptStream(server)
        #expect(peer.streamID == RawQUICClient.streamID(stream))
        #expect(peer.isClientInitiated && !peer.isUnidirectional)
        try await RawQUICClient.send(stream, Array("world".utf8), final: true)
        let request = try await receiveAll(peer)
        #expect(request == ByteBuffer("hello world"))
        try await peer.send(request, endOfStream: true)
        let echoed = await RawQUICClient.receiveAll(stream)
        #expect(echoed.bytes == Array("hello world".utf8))
        #expect(echoed.fin && echoed.error == nil)

        // A server-opened unidirectional stream arrives with its data and FIN.
        let uni = try await server.openUnidirectionalStream()
        #expect(uni.isUnidirectional && !uni.isClientInitiated && uni.streamID & 0x3 == 0x3)
        try await uni.send(ByteBuffer("uni"), endOfStream: true)
        #expect(try await eventually { !client.inboundStreams.isEmpty })
        let inboundUni = try #require(client.inboundStreams.first)
        try await client.start(inboundUni)
        #expect(RawQUICClient.streamID(inboundUni) == uni.streamID)
        let uniBytes = await RawQUICClient.receiveAll(inboundUni)
        #expect(uniBytes.bytes == Array("uni".utf8) && uniBytes.fin)

        // Server reset: the raw client's receive fails and its metadata reads the code.
        let victim = try await client.openStream()
        try await RawQUICClient.send(victim, Array("reset".utf8), final: false)
        let victimPeer = try await acceptStream(server)
        var buffer = ByteBuffer()
        _ = try await victimPeer.receive(into: &buffer, maxLength: 64)
        await victimPeer.reset(applicationError: 0x10c)
        #expect(victimPeer.sentResetCode == 0x10c)
        let reset = await RawQUICClient.receiveAll(victim)
        #expect(reset.error != nil)
        #expect(RawQUICClient.streamApplicationErrorCode(victim) == 0x10c)

        // Raw client reset: our receive throws and reads the code.
        let second = try await client.openStream()
        try await RawQUICClient.send(second, Array("x".utf8), final: false)
        let secondPeer = try await acceptStream(server)
        (second.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata)?.streamApplicationErrorCode = 0x10b
        second.cancel()
        await #expect(throws: TransportError.connectionReset) {
            while try await secondPeer.receive(into: &buffer, maxLength: 64) > 0 {}
        }
        #expect(secondPeer.receivedResetCode == 0x10b)

        // Connection close: every stream is cancelled first, then the group (gotcha 6), so
        // the raw client sees its group fail promptly instead of idling out.
        let closing = try await client.openStream()
        try await RawQUICClient.send(closing, Array("bye".utf8), final: false)
        _ = try await acceptStream(server)
        await server.close(applicationError: 0x101)
        #expect(server.closeApplicationError == 0x101)
        let afterClose = await RawQUICClient.receiveAll(closing)
        #expect(afterClose.error != nil || afterClose.fin)
        #expect(try await eventually {
            if case .failed = client.group.state { return true }
            return client.group.state == .cancelled
        })
        #expect(server.liveStreamCount == 0)
        client.cancel()
        await listener.close()
    }

    // MARK: Bounds

    @Test(.timeLimit(.minutes(1)))
    func manyClientStreamsStayWithinTheStreamLimit() async throws {
        // The server grants 10 concurrent bidirectional streams and never accepts any: a
        // client that tries to open 200 cannot make it hold more than the limit (plus the NW
        // client's implicit stream).
        let limit = 10
        let quic = testQUICConfiguration(maxStreamsBidirectional: limit)
        let (listener, client, server) = try await makeQUICPair(quic: quic)
        // Keep the client streams: a dropped stream is cancelled, which legitimately returns
        // its credit.
        let opened = Mutex<[QUICStreamTransport]>([])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    guard let stream = try? await client.openBidirectionalStream() else { return }
                    opened.withLock { $0.append(stream) }
                    try? await stream.send(ByteBuffer(bytes: Array("stream \(i)".utf8)), endOfStream: true)
                }
            }
            #expect(try await eventually(timeout: .seconds(10)) { server.pendingInboundCount >= limit - 1 })
            try await Task.sleep(for: .milliseconds(300))
            #expect(server.pendingInboundCount <= limit + 1)
            #expect(server.liveStreamCount <= limit + 1)
            #expect(server.rejectedStreamCount == 0)
            #expect(server.maxStreamsBidirectional == limit)   // nothing finished, nothing granted
            await client.close(applicationError: 0x100)
            group.cancelAll()
            try await group.waitForAll()
        }
        opened.withLock { $0 = [] }
        await server.close(applicationError: 0x100)
        await listener.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func finishedPeerStreamsRaiseTheCumulativeLimit() async throws {
        let quic = testQUICConfiguration(maxStreamsBidirectional: 3)
        let (listener, client, server) = try await makeQUICPair(quic: quic)
        for i in 0..<10 {
            let stream = try await client.openBidirectionalStream()
            try await stream.send(ByteBuffer(bytes: Array("\(i)".utf8)), endOfStream: true)
            let peer = try await acceptStream(server)
            _ = try await receiveAll(peer)
            try await peer.send(ByteBuffer(), endOfStream: true)
            await peer.close(.normal)
            _ = try await receiveAll(stream)
            await stream.close(.normal)
        }
        #expect(server.maxStreamsBidirectional == 13)
        await client.close(applicationError: 0x100)
        await server.close(applicationError: 0x100)
        await listener.close()
    }

    // MARK: curl

    static let curlPath = "/opt/homebrew/opt/curl/bin/curl"

    @Test(.timeLimit(.minutes(1)), .enabled(if: FileManager.default.isExecutableFile(atPath: curlPath)))
    func curlHTTP3OnlyGetsAHandEncodedResponse() async throws {
        let listener = try await makeQUICListener()
        let port = listener.port
        let output = Mutex<String>("")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let connection = try await accept(listener)
                // Control stream (SETTINGS QPACK_MAX_TABLE_CAPACITY=0, QPACK_BLOCKED_STREAMS=0),
                // then the QPACK encoder and decoder streams, as in the spike.
                let control = try await connection.openUnidirectionalStream()
                try await control.send(ByteBuffer(bytes: [0x00, 0x04, 0x04, 0x01, 0x00, 0x07, 0x00]), endOfStream: false)
                let encoder = try await connection.openUnidirectionalStream()
                try await encoder.send(ByteBuffer(bytes: [0x02]), endOfStream: false)
                let decoder = try await connection.openUnidirectionalStream()
                try await decoder.send(ByteBuffer(bytes: [0x03]), endOfStream: false)
                var critical: [QUICStreamTransport] = []   // curl's control and QPACK streams stay open
                for try await stream in connection.inboundStreams {
                    if stream.isUnidirectional {
                        critical.append(stream)
                        continue
                    }
                    _ = try await receiveAll(stream)
                    let body = Array("hello from QUICConnection\n".utf8)
                    // HEADERS: QPACK prefix 00 00, static :status 200 (25), content-type text/plain (53).
                    var response: [UInt8] = [0x01, 0x04, 0x00, 0x00, 0xC0 | 25, 0xC0 | 53]
                    response += [0x00, UInt8(body.count)] + body
                    try await stream.send(ByteBuffer(bytes: response), endOfStream: true)
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
                await connection.close(applicationError: 0x100)
                _ = critical
            }
            group.addTask {
                output.withLock { $0 = (try? runProcess(Self.curlPath, [
                    "--http3-only", "-k", "-s", "--max-time", "15", "https://127.0.0.1:\(port)/",
                ])) ?? "" }
            }
            try await group.waitForAll()
        }
        #expect(output.withLock { $0 } == "hello from QUICConnection\n")
        await listener.close()
    }

    // MARK: State machines

    @Test func connectionStateGrantsCreditAsPeerStreamsFinish() {
        var state = QUICConnectionState(initialMaxStreamsBidirectional: 2, initialMaxStreamsUnidirectional: 3)
        #expect(state.handle(.inboundStreamReady) == .becomeUsable)
        #expect(state.handle(.groupReady) == .none)
        #expect(state.handle(.peerStreamFinished(unidirectional: false)) == .raiseMaxStreams(bidirectional: 3, unidirectional: 3))
        #expect(state.handle(.peerStreamFinished(unidirectional: true)) == .raiseMaxStreams(bidirectional: 3, unidirectional: 4))
        #expect(state.handle(.closeRequested) == .beginClose)
        #expect(state.handle(.closeRequested) == .none)
        #expect(state.handle(.groupFailed(.connectionReset)) == .none)
        #expect(state.handle(.groupCancelled) == .finish)
        #expect(state.phase == .closed)
    }

    @Test func connectionStateFailureAndLateGroupReady() {
        var state = QUICConnectionState(initialMaxStreamsBidirectional: 1, initialMaxStreamsUnidirectional: 1)
        #expect(state.handle(.peerStreamFinished(unidirectional: false)) == .raiseMaxStreams(bidirectional: 2, unidirectional: 1))
        #expect(state.handle(.inboundStreamReady) == .becomeUsable)
        // Credit set while the group had no metadata is applied when it becomes ready.
        #expect(state.handle(.groupReady) == .raiseMaxStreams(bidirectional: 2, unidirectional: 1))
        #expect(state.handle(.groupFailed(.timedOut)) == .tearDown(.timedOut))
        #expect(state.phase == .failed(.timedOut))
        #expect(state.handle(.closeRequested) == .none)
        #expect(state.handle(.groupCancelled) == .finish)

        var dropped = QUICConnectionState(initialMaxStreamsBidirectional: 1, initialMaxStreamsUnidirectional: 1)
        #expect(dropped.handle(.groupCancelled) == .tearDown(.closed))
    }

    @Test func streamStateMapsReceiveCompletions() {
        var state = QUICStreamState()
        #expect(state.handle(.received(byteCount: 5, isComplete: false, error: nil)) == .deliver)
        #expect(state.handle(.received(byteCount: 0, isComplete: false, error: nil)) == .retry)
        #expect(state.handle(.received(byteCount: 3, isComplete: true, error: nil)) == .deliver)
        #expect(state.inputEnded)

        var reset = QUICStreamState()
        // A peer reset: ECONNRESET with isComplete (spike Q5); bytes first, then the error.
        #expect(reset.handle(.received(byteCount: 2, isComplete: true, error: .connectionReset)) == .deliver)
        #expect(reset.inputError == .connectionReset && !reset.inputEnded)
        #expect(reset.handle(.received(byteCount: 0, isComplete: true, error: .connectionReset)) == .fail(.connectionReset))

        var fin = QUICStreamState()
        #expect(fin.handle(.received(byteCount: 0, isComplete: true, error: nil)) == .endOfStream)
    }
}

/// Runs a short-lived tool to completion and returns its standard output. The tool must
/// enforce its own timeout (curl `--max-time`); the test's time limit backs it up.
private func runProcess(_ path: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
