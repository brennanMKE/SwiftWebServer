@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0048: request bodies from DATA frames, over in-memory connections.
@Suite(.timeLimit(.minutes(1)))
struct H2RequestBodyTests {
    /// Echoes the body's length and a checksum, reading slowly when `slow`; then the trailers.
    static func echo(slow: Bool = false) -> ClosureHandler {
        ClosureHandler { request in
            var count = 0
            var sum: UInt64 = 0
            var chunks = 0
            for try await chunk in request.body {
                chunks += 1
                count += chunk.readableBytes
                chunk.withUnsafeReadableBytes { for byte in $0 { sum &+= UInt64(byte) } }
                if slow { try await Task.sleep(for: .milliseconds(2)) }
            }
            var text = "\(count) \(sum)"
            if let trailers = request.body.trailers {
                for i in 0..<trailers.count {
                    text += " \(trailers.nameString(at: i))=\(trailers.valueString(at: i))"
                }
            }
            return HTTPResponse(body: .bytes(ByteBuffer(bytes: Array(text.utf8))))
        }
    }

    static func pattern(_ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7) } }

    static func checksum(_ bytes: [UInt8]) -> UInt64 { bytes.reduce(0) { $0 &+ UInt64($1) } }

    @Test func multiFrameBodyReachesASlowReader() async throws {
        let body = Self.pattern(300_000)
        try await withH2Connection(handler: Self.echo(slow: true)) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/up", method: "POST"), endStream: false))
            let others = try await client.sendBody(body, on: 1)
            // The server granted stream credit as the handler consumed bytes.
            #expect(others.contains { if case .windowUpdate(1, _) = $0 { return true }; return false }, "\(others)")
            let response = try await client.response(on: 1)
            #expect(String(decoding: response.body, as: UTF8.self) == "300000 \(Self.checksum(body))")
        }
    }

    @Test func contentLengthMatchingTheBodyIsAccepted() async throws {
        let body = Self.pattern(1_000)
        try await withH2Connection(handler: Self.echo()) { client in
            try await client.handshake()
            let block = client.requests.get("/", method: "POST", extra: [("content-length", "1000")])
            try await client.send(F.headers(1, block: block, endStream: false))
            _ = try await client.sendBody(body, on: 1, frameSize: 300)
            #expect(String(decoding: try await client.response(on: 1).body, as: UTF8.self) == "1000 \(Self.checksum(body))")
        }
    }

    @Test(arguments: [(10, 11), (10, 9), (0, 1)])
    func contentLengthMismatchIsAStreamProtocolError(declared: Int, sent: Int) async throws {
        let seen = Mutex<(any Error)?>(nil)
        let handler = ClosureHandler { request in
            do {
                for try await _ in request.body {}
            } catch {
                seen.withLock { $0 = error }
                throw error
            }
            return HTTPResponse(status: .ok)
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            let block = client.requests.get("/", method: "POST", extra: [("content-length", "\(declared)")])
            try await client.send(F.headers(1, block: block, endStream: false), F.data(1, Self.pattern(sent), endStream: true))
            let frames = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(frames.last == .rstStream(stream: 1, .protocolError), "\(frames)")
            // The connection carries on.
            try await client.send(F.headers(3, block: client.requests.get("/next")))
            _ = try await client.response(on: 3)
        }
        #expect(seen.withLock { $0 as? HTTPRequestBodyError } == .malformed)
    }

    @Test func trailersFollowTheBody() async throws {
        try await withH2Connection(handler: Self.echo()) { client in
            try await client.handshake()
            try await client.send(
                F.headers(1, block: client.requests.get("/", method: "POST"), endStream: false),
                F.data(1, [1, 2, 3], endStream: false),
                F.headers(1, block: client.requests.block([("x-checksum", "6")]), endStream: true))
            #expect(String(decoding: try await client.response(on: 1).body, as: UTF8.self) == "3 6 x-checksum=6")
        }
    }

    @Test func invalidTrailersAreAStreamProtocolError() async throws {
        try await withH2Connection(handler: Self.echo()) { client in
            try await client.handshake()
            try await client.send(
                F.headers(1, block: client.requests.get("/", method: "POST"), endStream: false),
                F.data(1, [1], endStream: false),
                F.headers(1, block: client.requests.block([(":path", "/x")]), endStream: true))
            let frames = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(frames.last == .rstStream(stream: 1, .protocolError), "\(frames)")
        }
    }

    /// Padding counts toward flow control (it is credited) but is not part of the body.
    @Test func paddingIsNotDelivered() async throws {
        let config = HTTP2Configuration(connectionWindowSize: 65_535)
        try await withH2Connection(configuration: config, handler: Self.echo()) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/", method: "POST"), endStream: false))
            // 1 pad-length octet + 4 data + 40,000 padding: half the connection window.
            let payload = [UInt8(200)] + [9, 9, 9, 9] + Array(repeating: 0, count: 200)
            var frames: [ByteBuffer] = []
            for _ in 0..<160 { frames.append(F.raw(type: .data, flags: .padded, streamID: 1, payload: payload)) }
            frames.append(F.data(1, [], endStream: true))
            try await client.transport.send(F.join(frames), endOfStream: false)
            let response = try await client.response(on: 1)
            #expect(String(decoding: response.body, as: UTF8.self) == "640 5760")
            // 160 × 201 padding bytes and the consumed data went back as connection credit.
            #expect(response.others.contains { if case .windowUpdate(0, _) = $0 { return true }; return false },
                    "\(response.others)")
        }
    }

    @Test func dataAfterEndStreamIsStreamClosed() async throws {
        let gate = Gate()
        let handler = ClosureHandler { _ in
            await gate.wait()
            return HTTPResponse(status: .ok)
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/")), F.data(1, [1]))
            let frames = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(frames.last == .rstStream(stream: 1, .streamClosed), "\(frames)")
            gate.open()
        }
    }

    /// A peer that ignores the stream window: the body stays bounded and the stream is reset.
    @Test func dataBeyondTheStreamWindowIsAFlowControlError() async throws {
        let gate = Gate()
        let handler = ClosureHandler { _ in
            await gate.wait()
            return HTTPResponse(status: .ok)
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            var frames = [F.headers(1, block: client.requests.get("/", method: "POST"), endStream: false)]
            for _ in 0..<4 { frames.append(F.data(1, Array(repeating: 1, count: 16_384), endStream: false)) }
            try await client.transport.send(F.join(frames), endOfStream: false)
            let seen = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(seen.last == .rstStream(stream: 1, .flowControlError), "\(seen)")
            gate.open()
        }
    }

    /// A handler that stops reading: no stream credit comes back beyond what it consumed.
    @Test func unreadBodyGetsNoStreamCredit() async throws {
        let gate = Gate()
        let handler = ClosureHandler { _ in
            await gate.wait()
            return HTTPResponse(status: .ok)
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            var frames = [F.headers(1, block: client.requests.get("/", method: "POST"), endStream: false)]
            for _ in 0..<3 { frames.append(F.data(1, Array(repeating: 1, count: 16_000), endStream: false)) }
            try await client.transport.send(F.join(frames), endOfStream: false)
            try await client.send(F.ping(7))
            let seen = try await client.frames(until: { $0 == .ping(ack: true, 7) })
            #expect(!seen.contains { if case .windowUpdate(1, _) = $0 { return true }; return false }, "\(seen)")
            gate.open()
            let response = try await client.response(on: 1)
            #expect(response.head.first?.1 == "200")
        }
    }

    /// The consuming task is cancelled while it waits for DATA: it sees `CancellationError` and
    /// the stream still answers.
    @Test func cancelledReadThrowsCancellationError() async throws {
        let handler = ClosureHandler { request in
            let body = request.body
            let outcome = await withTaskGroup(of: String.self) { group in
                group.addTask {
                    do {
                        for try await _ in body {}
                        return "ended"
                    } catch is CancellationError {
                        return "cancelled"
                    } catch {
                        return "\(error)"
                    }
                }
                try? await Task.sleep(for: .milliseconds(30))
                group.cancelAll()
                return await group.next() ?? "none"
            }
            return HTTPResponse(body: .bytes(ByteBuffer(bytes: Array(outcome.utf8))))
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/", method: "POST"), endStream: false))
            #expect(String(decoding: try await client.response(on: 1).body, as: UTF8.self) == "cancelled")
        }
    }

    @Test func bodyExpiresWhenTheHandlerReturns() async throws {
        let kept = Mutex<HTTPRequestBody?>(nil)
        let handler = ClosureHandler { request in
            kept.withLock { $0 = request.body }
            return HTTPResponse(status: .ok)
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/", method: "POST"), endStream: false))
            _ = try await client.response(on: 1)
            let body = try #require(kept.withLock { $0 })
            await #expect(throws: HTTPRequestBodyError.expired) { for try await _ in body {} }
        }
    }
}

extension H2Client {
    /// Sends `body` as DATA frames of at most `frameSize` bytes on `stream`, within the
    /// server's connection and stream windows, ending the stream. Returns the frames read
    /// while waiting for window.
    mutating func sendBody(
        _ body: [UInt8], on stream: UInt32, frameSize: Int = 16_384, initialWindow: Int = 65_535
    ) async throws -> [H2Frame] {
        var connectionWindow = 65_535
        var streamWindow = initialWindow
        var offset = 0
        var others: [H2Frame] = []
        while offset < body.count {
            let size = Swift.min(frameSize, body.count - offset, connectionWindow, streamWindow)
            if size > 0 {
                let end = offset + size
                try await send(F.data(stream, Array(body[offset..<end]), endStream: end == body.count))
                connectionWindow -= size
                streamWindow -= size
                offset = end
                continue
            }
            guard let frame = try await nextFrame() else { throw TimedOut() }
            switch frame {
            case .windowUpdate(0, let increment): connectionWindow += Int(increment)
            case .windowUpdate(stream, let increment): streamWindow += Int(increment)
            default: break
            }
            others.append(frame)
        }
        if body.isEmpty { try await send(F.data(stream, [], endStream: true)) }
        return others
    }
}
