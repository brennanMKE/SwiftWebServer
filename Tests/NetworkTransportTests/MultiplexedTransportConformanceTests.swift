import Foundation
import HTTPCore
import HTTPTestSupport
import NetworkTransport
import Synchronization
import Testing

// One behavioural suite run against both MultiplexedTransport implementations: the
// Network.framework QUIC adapter (#0098, over 127.0.0.1 port 0) and InMemoryMultiplexedTransport
// (#0099). HTTP/3 code is tested over the in-memory one, so the two must stay equivalent in
// everything this suite covers.
//
// Known, documented differences kept out of this suite:
// - Stream IDs: a Network.framework client uses client bidi stream 0 implicitly (spike gotcha
//   8), so its first request stream is 4; in memory it is 0. Only ID bits are compared.
// - A QUIC peer learns of a stream when the first frame arrives, so every scenario sends
//   before it expects the peer to accept.
// - After a local reset, NW abandons both directions; in memory the receive side stays open.
// - MAX_STREAMS: the QUIC adapter grants credit back itself when a peer stream finishes; the
//   in-memory harness below does it explicitly with `raiseMaxStreams`.

/// The implementations under test.
enum MuxImplementation: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case quic
    case inMemory

    var testDescription: String { rawValue }

    func makePair(maxStreamsBidirectional: Int = 100) async throws -> MuxPair {
        switch self {
        case .quic: try await MuxPair.quic(maxStreamsBidirectional: maxStreamsBidirectional)
        case .inMemory: MuxPair.inMemory(maxStreamsBidirectional: maxStreamsBidirectional)
        }
    }
}

/// A stream of either implementation, with the operations the protocol does not declare.
struct MuxStream: Sendable {
    let transport: any ByteStreamTransport & StreamIdentified
    let resetWith: @Sendable (UInt64) async -> Void
    let receivedResetCode: @Sendable () -> UInt64?
    /// Closes the stream gracefully (and, in memory, grants the peer's credit back).
    let finish: @Sendable () async -> Void

    var streamID: UInt64 { transport.streamID }

    func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        try await transport.receive(into: &buffer, maxLength: maxLength)
    }

    func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws {
        try await transport.send(bytes, endOfStream: endOfStream)
    }
}

/// One side of a connection of either implementation.
struct MuxEndpoint: Sendable {
    let openBidirectional: @Sendable () async throws -> MuxStream
    let openUnidirectional: @Sendable () async throws -> MuxStream
    /// The next peer stream, or `nil` when inbound iteration ended.
    let acceptInbound: @Sendable () async throws -> MuxStream?
    let close: @Sendable (UInt64) async -> Void
}

struct MuxPair: Sendable {
    let client: MuxEndpoint
    let server: MuxEndpoint
    let teardown: @Sendable () async -> Void

    // MARK: QUIC

    static func quic(maxStreamsBidirectional: Int) async throws -> MuxPair {
        let quic = testQUICConfiguration(maxStreamsBidirectional: maxStreamsBidirectional)
        let (listener, client, server) = try await makeQUICPair(quic: quic)
        return MuxPair(
            client: endpoint(client), server: endpoint(server),
            teardown: {
                await client.close(applicationError: 0x100)
                await server.close(applicationError: 0x100)
                await listener.close()
            })
    }

    private static func wrap(_ stream: QUICStreamTransport) -> MuxStream {
        MuxStream(
            transport: stream,
            resetWith: { await stream.reset(applicationError: $0) },
            receivedResetCode: { stream.receivedResetCode },
            finish: { await stream.close(.normal) })
    }

    private static func endpoint(_ connection: QUICConnection) -> MuxEndpoint {
        MuxEndpoint(
            openBidirectional: { wrap(try await connection.openBidirectionalStream()) },
            openUnidirectional: { wrap(try await connection.openUnidirectionalStream()) },
            acceptInbound: {
                var iterator = connection.inboundStreams.makeAsyncIterator()
                return try await iterator.next().map(wrap)
            },
            close: { await connection.close(applicationError: $0) })
    }

    // MARK: In memory

    static func inMemory(maxStreamsBidirectional: Int) -> MuxPair {
        typealias Mux = InMemoryMultiplexedTransport
        let (client, server) = Mux.makePair(
            server: .init(maxStreamsBidirectional: UInt64(maxStreamsBidirectional)))
        // Mirror the QUIC adapter: each finished peer stream grants one more (MAX_STREAMS).
        let finished = Mutex<[UInt64]>([0, 0])

        @Sendable func wrap(_ stream: Mux.Stream, owner: Mux) -> MuxStream {
            MuxStream(
                transport: stream,
                resetWith: { await stream.reset(applicationError: $0) },
                receivedResetCode: { stream.receivedResetCode },
                finish: {
                    await stream.close(.normal)
                    guard !stream.isLocallyInitiated else { return }
                    let kind = stream.isUnidirectional ? 1 : 0
                    let count = finished.withLock { value in
                        value[kind] += 1
                        return value[kind]
                    }
                    let base = kind == 0 ? owner.maxStreamsBidirectional : owner.maxStreamsUnidirectional
                    let target = max(base, count + (kind == 0 ? UInt64(maxStreamsBidirectional) : 100))
                    if kind == 0 { owner.raiseMaxStreams(bidirectional: target) } else { owner.raiseMaxStreams(unidirectional: target) }
                })
        }

        @Sendable func endpoint(_ transport: Mux) -> MuxEndpoint {
            MuxEndpoint(
                openBidirectional: { wrap(try await transport.openBidirectionalStream(), owner: transport) },
                openUnidirectional: { wrap(try await transport.openUnidirectionalStream(), owner: transport) },
                acceptInbound: {
                    var iterator = transport.inboundStreams.makeAsyncIterator()
                    return try await iterator.next().map { wrap($0, owner: transport) }
                },
                close: { await transport.close(applicationError: $0) })
        }

        return MuxPair(
            client: endpoint(client), server: endpoint(server),
            teardown: { await client.close(applicationError: 0x100) })
    }
}

// MARK: - Helpers

private func receiveAll(_ stream: MuxStream, maxLength: Int = 64 * 1024) async throws -> ByteBuffer {
    try await receiveAll(stream.transport, maxLength: maxLength)
}

private func accept(_ endpoint: MuxEndpoint) async throws -> MuxStream {
    guard let stream = try await endpoint.acceptInbound() else { throw TransportError.closed }
    return stream
}

/// Takes peer streams until inbound iteration ends (`nil`) and returns them; fails the test
/// with ``TransportError/timedOut`` if it has not ended by `deadline`.
private func drainInbound(_ endpoint: MuxEndpoint, deadline: Duration) async throws -> [MuxStream] {
    try await withThrowingTaskGroup(of: [MuxStream]?.self) { group in
        group.addTask {
            var taken: [MuxStream] = []
            while let stream = try await endpoint.acceptInbound() { taken.append(stream) }
            return taken
        }
        group.addTask {
            try await Task.sleep(for: deadline)
            return nil
        }
        defer { group.cancelAll() }
        guard let taken = try await group.next() ?? nil else { throw TransportError.timedOut }
        return taken
    }
}

/// Echoes one stream: sends back what arrives, then FIN after the peer's FIN.
private func echo(_ stream: MuxStream) async throws {
    var buffer = ByteBuffer()
    while true {
        buffer.clear()
        let n = try await stream.receive(into: &buffer, maxLength: 16 * 1024)
        if n == 0 { break }
        try await stream.send(buffer, endOfStream: false)
    }
    try await stream.send(ByteBuffer(), endOfStream: true)
}

private func pattern(_ count: Int, seed: UInt8) -> ByteBuffer {
    ByteBuffer(bytes: (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

/// Runs `body` with a fresh pair and always tears it down.
private func withPair(
    _ implementation: MuxImplementation, maxStreamsBidirectional: Int = 100,
    _ body: (MuxPair) async throws -> Void
) async throws {
    let pair = try await implementation.makePair(maxStreamsBidirectional: maxStreamsBidirectional)
    do {
        try await body(pair)
    } catch {
        await pair.teardown()
        throw error
    }
    await pair.teardown()
}

// MARK: - Suite

@Suite struct MultiplexedTransportConformanceTests {
    @Test(.timeLimit(.minutes(1)), arguments: MuxImplementation.allCases)
    func bidirectionalEchoWithFINBothWays(_ implementation: MuxImplementation) async throws {
        try await withPair(implementation) { pair in
            let stream = try await pair.client.openBidirectional()
            #expect(!stream.transport.isUnidirectional && stream.transport.isClientInitiated)
            try await stream.send(ByteBuffer("hello "), endOfStream: false)
            let peer = try await accept(pair.server)
            #expect(peer.streamID == stream.streamID)
            #expect(!peer.transport.isUnidirectional && peer.transport.isClientInitiated)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await echo(peer) }
                try await stream.send(ByteBuffer("world"), endOfStream: true)
                // FIN closes only the sending direction.
                await #expect(throws: TransportError.outputShutdown) {
                    try await stream.send(ByteBuffer("late"), endOfStream: false)
                }
                #expect(try await receiveAll(stream) == ByteBuffer("hello world"))
                var empty = ByteBuffer()
                #expect(try await stream.receive(into: &empty, maxLength: 8) == 0)   // FIN is sticky
                try await group.waitForAll()
            }
            await stream.finish()
            await peer.finish()
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: MuxImplementation.allCases)
    func serverOpenedUnidirectionalStream(_ implementation: MuxImplementation) async throws {
        try await withPair(implementation) { pair in
            let uni = try await pair.server.openUnidirectional()
            #expect(uni.transport.isUnidirectional && !uni.transport.isClientInitiated)
            var buffer = ByteBuffer()
            #expect(try await uni.receive(into: &buffer, maxLength: 8) == 0)   // send-only end
            try await uni.send(ByteBuffer("\u{0}control"), endOfStream: false)
            try await uni.send(ByteBuffer(" uni"), endOfStream: true)

            let peer = try await accept(pair.client)
            #expect(peer.streamID == uni.streamID)
            #expect(peer.transport.isUnidirectional && !peer.transport.isClientInitiated)
            #expect(try await receiveAll(peer) == ByteBuffer("\u{0}control uni"))
            await #expect(throws: TransportError.outputShutdown) {   // receive-only end
                try await peer.send(ByteBuffer("x"), endOfStream: false)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: MuxImplementation.allCases)
    func finFromServerFirstThenClient(_ implementation: MuxImplementation) async throws {
        try await withPair(implementation) { pair in
            let stream = try await pair.client.openBidirectional()
            try await stream.send(ByteBuffer("request"), endOfStream: false)
            let peer = try await accept(pair.server)
            var buffer = ByteBuffer()
            #expect(try await peer.receive(into: &buffer, maxLength: 64) == 7)
            // The server finishes first; the client can still send afterwards.
            try await peer.send(ByteBuffer("early response"), endOfStream: true)
            #expect(try await receiveAll(stream) == ByteBuffer("early response"))
            try await stream.send(ByteBuffer(" body"), endOfStream: true)
            buffer.clear()
            #expect(try await receiveAll(peer) == ByteBuffer(" body"))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: MuxImplementation.allCases)
    func clientResetCarriesItsCodeToTheServer(_ implementation: MuxImplementation) async throws {
        try await withPair(implementation) { pair in
            let stream = try await pair.client.openBidirectional()
            try await stream.send(ByteBuffer("abc"), endOfStream: false)
            let peer = try await accept(pair.server)
            var buffer = ByteBuffer()
            #expect(try await peer.receive(into: &buffer, maxLength: 64) == 3)
            await stream.resetWith(0x10c)
            await #expect(throws: TransportError.connectionReset) {
                while try await peer.receive(into: &buffer, maxLength: 64) > 0 {}
            }
            #expect(peer.receivedResetCode() == 0x10c)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: MuxImplementation.allCases)
    func serverResetFailsAPendingClientReceiveWithItsCode(_ implementation: MuxImplementation) async throws {
        try await withPair(implementation) { pair in
            let stream = try await pair.client.openBidirectional()
            try await stream.send(ByteBuffer("reset me"), endOfStream: false)
            let peer = try await accept(pair.server)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var buffer = ByteBuffer()
                    await #expect(throws: TransportError.connectionReset) {
                        while try await stream.receive(into: &buffer, maxLength: 64) > 0 {}
                    }
                }
                try await Task.sleep(for: .milliseconds(20))
                await peer.resetWith(0x10b)
                try await group.waitForAll()
            }
            #expect(stream.receivedResetCode() == 0x10b)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: MuxImplementation.allCases)
    func concurrentStreamsWithInterleavedData(_ implementation: MuxImplementation) async throws {
        try await withPair(implementation) { pair in
            let count = 8
            let rounds = 20
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withThrowingTaskGroup(of: Void.self) { handlers in
                        for _ in 0..<count {
                            let stream = try await accept(pair.server)
                            handlers.addTask { try await echo(stream); await stream.finish() }
                        }
                        try await handlers.waitForAll()
                    }
                }
                var streams: [MuxStream] = []
                for _ in 0..<count { streams.append(try await pair.client.openBidirectional()) }
                #expect(Set(streams.map(\.streamID)).count == count)
                for round in 0..<rounds {
                    for (i, stream) in streams.enumerated() {
                        try await stream.send(pattern(700, seed: UInt8(i * rounds + round)), endOfStream: round == rounds - 1)
                    }
                }
                try await withThrowingTaskGroup(of: (Int, ByteBuffer).self) { readers in
                    for (i, stream) in streams.enumerated() {
                        readers.addTask { (i, try await receiveAll(stream)) }
                    }
                    for try await (i, echoed) in readers {
                        var expected = ByteBuffer()
                        for round in 0..<rounds { expected.append(pattern(700, seed: UInt8(i * rounds + round))) }
                        #expect(echoed == expected, "stream \(streams[i].streamID)")
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: MuxImplementation.allCases)
    func largeTransferAppliesBackpressureThenDeliversEverything(_ implementation: MuxImplementation) async throws {
        try await withPair(implementation) { pair in
            let total = 32 << 20
            let chunk = 64 << 10
            let accepted = Mutex(0)
            let stream = try await pair.client.openBidirectional()
            try await stream.send(pattern(1, seed: 0), endOfStream: false)
            let peer = try await accept(pair.server)
            var first = ByteBuffer()
            #expect(try await peer.receive(into: &first, maxLength: 1) == 1)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var sent = 0
                    while sent < total {
                        try await stream.send(pattern(chunk, seed: UInt8(truncatingIfNeeded: sent / chunk)), endOfStream: sent + chunk >= total)
                        sent += chunk
                        accepted.withLock { $0 = sent }
                    }
                }
                // The server does not read: the sender must stall well short of the total.
                var last = -1
                var stableFor = 0
                while stableFor < 5 {
                    try await Task.sleep(for: .milliseconds(100))
                    let now = accepted.withLock { $0 }
                    stableFor = now == last ? stableFor + 1 : 0
                    last = now
                }
                #expect(last < 24 << 20, "accepted \(last) bytes without a reader")
                #expect(last < total)

                // Drain everything and check it.
                var received = 0
                var mismatch = false
                var buffer = ByteBuffer()
                while true {
                    buffer.clear()
                    let n = try await peer.receive(into: &buffer, maxLength: 256 << 10)
                    if n == 0 { break }
                    buffer.withUnsafeReadableBytes { bytes in
                        for (offset, byte) in bytes.enumerated() {
                            let position = received + offset
                            let expected = UInt8(truncatingIfNeeded: (position % chunk) &* 31 &+ (position / chunk))
                            if byte != expected { mismatch = true }
                        }
                    }
                    received += n
                }
                #expect(received == total)
                #expect(!mismatch)
                try await group.waitForAll()
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: MuxImplementation.allCases)
    func connectionCloseFailsStreamsAndEndsInboundOnBothSides(_ implementation: MuxImplementation) async throws {
        try await withPair(implementation) { pair in
            let stream = try await pair.client.openBidirectional()
            try await stream.send(ByteBuffer("open"), endOfStream: false)
            let peer = try await accept(pair.server)
            var buffer = ByteBuffer()
            #expect(try await peer.receive(into: &buffer, maxLength: 64) == 4)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    // The peer of the closing side: its streams fail with a reset.
                    var buffer = ByteBuffer()
                    await #expect(throws: TransportError.connectionReset) {
                        while try await stream.receive(into: &buffer, maxLength: 64) > 0 {}
                    }
                }
                group.addTask {
                    // The closing side's own pending receive reports `.closed`.
                    var buffer = ByteBuffer()
                    await #expect(throws: TransportError.closed) {
                        while try await peer.receive(into: &buffer, maxLength: 64) > 0 {}
                    }
                }
                group.addTask {
                    // Waiting for the next peer stream ends quietly.
                    let next = try await pair.server.acceptInbound()
                    #expect(next == nil)
                }
                try await Task.sleep(for: .milliseconds(50))
                await pair.server.close(0x101)
                try await group.waitForAll()
            }
            // The closing side's peer: inbound iteration ends once it learns of the close.
            // Network.framework's close also emits STOP_SENDING and a FIN on server-initiated
            // bidirectional stream 1, which the server never opened (nw-transport.md
            // observations 3 and 7). An NW client usually fails its group first, but under load
            // that stream can become ready, and be handed over, before (#0115). It is a stream
            // the peer created on the wire, so the transport surfaces it; allow exactly that
            // one, dead, and still require iteration to end within the deadline.
            let extra = try await drainInbound(pair.client, deadline: .seconds(10))
            switch implementation {
            case .inMemory:
                #expect(extra.isEmpty)
            case .quic:
                #expect(extra.count <= 1)
                for phantom in extra {
                    #expect(phantom.streamID == 1)
                    var buffer = ByteBuffer()
                    do {
                        #expect(try await phantom.receive(into: &buffer, maxLength: 64) == 0)   // its FIN, no data
                    } catch {
                        #expect(error as? TransportError == .connectionReset)
                    }
                }
            }
            await #expect(throws: TransportError.closed) { _ = try await pair.server.openUnidirectional() }
            await #expect(throws: TransportError.connectionReset) { _ = try await pair.client.openBidirectional() }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: MuxImplementation.allCases)
    func streamCreditIsReplenishedAsStreamsFinish(_ implementation: MuxImplementation) async throws {
        // Far more streams than the initial limit, a few at a time, each finished by both
        // sides: the opener never runs out of credit for good.
        let limit = 4
        let total = 40
        try await withPair(implementation, maxStreamsBidirectional: limit) { pair in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for _ in 0..<total {
                        let stream = try await accept(pair.server)
                        let request = try await receiveAll(stream)
                        try await stream.send(request, endOfStream: true)
                        await stream.finish()
                    }
                }
                for batch in 0..<(total / 2) {
                    try await withThrowingTaskGroup(of: Void.self) { clients in
                        for i in 0..<2 {
                            clients.addTask {
                                let stream = try await pair.client.openBidirectional()
                                let message = ByteBuffer(bytes: Array("request \(batch * 2 + i)".utf8))
                                try await stream.send(message, endOfStream: true)
                                #expect(try await receiveAll(stream) == message)
                                await stream.finish()
                            }
                        }
                        try await clients.waitForAll()
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}
