import Foundation
import HTTP3
import HTTPCore
import HTTPTestSupport
import NetworkTransport
import Synchronization
import Testing

/// #0107 measurement over Network.framework QUIC (127.0.0.1, port 0, in-memory test identity):
/// how much of RFC 9218 ordering survives to the client when QUIC's packet scheduling belongs
/// to Network.framework. Two streamed downloads, the `u=7` one requested first, with the send
/// budget small (contended) or at its default. Prints completion order and times
/// (docs/benchmarks/M10-priorities.md); asserts only that both complete.
@Suite(.timeLimit(.minutes(1)))
struct H3QUICPriorityTests {
    static let size = 8 << 20
    static let chunk = 64 * 1024

    @Test(arguments: [64 * 1024, 4 * 1024 * 1024])
    func twoDownloadsAtDifferentUrgencies(budget: Int) async throws {
        let handler = ClosureHandler { _ in
            HTTPResponse(body: .stream(length: Self.size) { writer in
                let piece = ByteBuffer(bytes: Array(repeating: 0x61, count: Self.chunk))
                for _ in 0..<(Self.size / Self.chunk) { try await writer.write(piece) }
            })
        }
        let material = try TestIdentity.load()
        let identity = try TLSIdentity(pkcs12: material.pkcs12, password: TestIdentity.password)
        let quic = QUICConfiguration(alpn: HTTP3.alpnTokens, idleTimeoutMilliseconds: 10_000)
        let listener = try QUICListener(configuration: .init(host: "127.0.0.1", port: 0, quic: quic), identity: identity)
        let port = try await listener.start()
        let shutdown = ShutdownSignal()
        let http3 = HTTP3(configuration: H3Configuration(abuseLimits: H3AbuseLimits(maxConnectionSendBuffer: budget)))
        let finished = Mutex<[(String, Double)]>([])
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
            let start = ContinuousClock.now
            try await withThrowingTaskGroup(of: Void.self) { downloads in
                for (path, priority) in [("/low", "u=7"), ("/high", "u=0")] {
                    let stream = try await client.openBidirectionalStream()
                    try await stream.send(
                        ByteBuffer(bytes: H3Wire.headers(H3Wire.request(path: path, extra: [("priority", priority)]))),
                        endOfStream: true)
                    downloads.addTask {
                        var buffer = ByteBuffer()
                        var total = 0
                        while true {
                            buffer.clear()
                            let n = try await stream.receive(into: &buffer, maxLength: 256 * 1024)
                            if n == 0 { break }
                            total += n
                        }
                        let elapsed = ContinuousClock.now - start
                        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
                        #expect(total > Self.size)
                        finished.withLock { $0.append((path, ms)) }
                    }
                }
                try await downloads.waitForAll()
            }
            let result = finished.withLock { $0 }
            print("[M10-priorities h3] budget \(budget >> 10) KiB, 8 MiB each: "
                  + result.map { "\($0.0) done at \(String(format: "%.1f", $0.1)) ms" }.joined(separator: ", "))
            #expect(result.count == 2)

            await client.close(applicationError: HTTP3Error.noError.rawValue)
            shutdown.trigger()
            await listener.close()
            try await group.waitForAll()
        }
    }
}
