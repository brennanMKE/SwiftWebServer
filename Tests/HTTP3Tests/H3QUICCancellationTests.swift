import Foundation
import HTTP3
import HTTPCore
import HTTPTestSupport
import NetworkTransport
import Synchronization
import Testing

/// #0104 over Network.framework QUIC (127.0.0.1, port 0, in-memory test identity): a client that
/// abandons its stream while the handler is still computing (the request already ended, so
/// nothing is being read or written) cancels the handler, through `PeerAbortObserving` on
/// `QUICStreamTransport`.
@Suite(.timeLimit(.minutes(1)))
struct H3QUICCancellationTests {
    @Test(arguments: [false, true])
    func clientAbortCancelsAComputingHandler(forceCancel: Bool) async throws {
        let started = Flag()
        let cancelled = Flag()
        let handler = ClosureHandler { request in
            guard request.string(of: request.path) == "/slow" else {
                return HTTPResponse(status: .ok, body: .bytes(ByteBuffer("next")))
            }
            started.set()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled.set()
                throw error
            }
            return HTTPResponse(status: .ok)
        }
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
            let stream = try await client.openBidirectionalStream()
            try await stream.send(ByteBuffer(bytes: H3Wire.headers(H3Wire.request(path: "/slow"))), endOfStream: true)
            await started.wait()
            if forceCancel {
                await stream.close(.abort)
            } else {
                await stream.reset(applicationError: HTTP3Error.requestCancelled.rawValue)
            }
            await cancelled.wait()
            try await waitUntil { http3.tracker.liveRequestStreams == 0 && http3.tracker.liveHandlers == 0 }

            // The connection still serves.
            let next = try await client.openBidirectionalStream()
            try await next.send(ByteBuffer(bytes: H3Wire.headers(H3Wire.request(path: "/next"))), endOfStream: true)
            var buffer = ByteBuffer()
            while try await next.receive(into: &buffer, maxLength: 64 * 1024) > 0 {}
            let body = buffer.withUnsafeReadableBytes { String(decoding: $0, as: UTF8.self) }
            #expect(body.hasSuffix("next"))

            await client.close(applicationError: HTTP3Error.noError.rawValue)
            shutdown.trigger()
            await listener.close()
            try await group.waitForAll()
        }
        #expect(http3.tracker.liveConnections == 0)
    }
}
