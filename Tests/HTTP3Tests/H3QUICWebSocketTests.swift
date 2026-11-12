import Foundation
import HTTP3
import HTTPCore
import HTTPTestSupport
import NetworkTransport
import Testing
import WebSockets

extension QUICStreamTransport: ResetCodeReporting {}

/// #0111 over Network.framework QUIC (127.0.0.1, port 0, in-memory test identity): an
/// extended CONNECT WebSocket echo and close handshake through `HTTP3` and `WebSocketUpgrade`,
/// with the in-repo h3 WebSocket client. No RFC 9220 client exists on this machine (curl 8.7.1
/// has neither HTTP/3 nor WebSockets, and `URLSessionWebSocketTask` speaks HTTP/1.1), so this
/// is the end-to-end check.
@Suite(.timeLimit(.minutes(1)))
struct H3QUICWebSocketTests {
    @Test func extendedConnectEchoOverQUIC() async throws {
        let record = H3WSRecord()
        let handler = echoChain(record)
        let material = try TestIdentity.load()
        let identity = try TLSIdentity(pkcs12: material.pkcs12, password: TestIdentity.password)
        let quic = QUICConfiguration(alpn: HTTP3.alpnTokens, idleTimeoutMilliseconds: 10_000)
        let listener = try QUICListener(configuration: .init(host: "127.0.0.1", port: 0, quic: quic), identity: identity)
        let port = try await listener.start()
        let shutdown = ShutdownSignal()
        let http3 = HTTP3()
        try await withThrowingTaskGroup(of: Void.self) { group in
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
                }
            }
            let client = try await QUICConnection.connect(
                host: "127.0.0.1", port: port,
                configuration: .init(quic: quic, peerVerification: .pinnedCertificate(material.certificateDER),
                                     connectTimeout: .seconds(10)))
            let ws = try await H3WebSocketStreamClient.start(on: try await client.openBidirectionalStream())
            await ws.readHeaders()
            #expect(ws.status == "200")

            try await ws.send(wsFrame(.text, Array("over QUIC".utf8)))
            #expect(await ws.next()?.payload == Array("over QUIC".utf8))
            let big = (0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
            try await ws.send(wsFrame(.binary, big))
            #expect(await ws.next()?.payload == big)

            try await ws.send(wsClose(1000))
            #expect(await ws.next()?.closeCode == 1000)
            try await ws.send([], fin: true)
            #expect(await ws.readsFIN())
            await record.ended.wait()
            #expect(record.snapshot.closeCodes == [.normalClosure])
            try await waitUntil { http3.tracker.liveRequestStreams == 0 && http3.tracker.liveHandlers == 0 }

            await client.close(applicationError: HTTP3Error.noError.rawValue)
            shutdown.trigger()
            await listener.close()
            try await group.waitForAll()
        }
        #expect(http3.tracker.liveConnections == 0)
    }
}
