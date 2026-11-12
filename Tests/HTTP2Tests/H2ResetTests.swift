import Foundation
@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0051: RST_STREAM in both directions and task cancellation.
@Suite(.timeLimit(.minutes(1)))
struct H2ResetTests {
    static func rst(_ stream: UInt32, _ code: HTTP2ErrorCode = .cancel) -> ByteBuffer {
        let value = code.rawValue
        return F.raw(type: .rstStream, streamID: stream,
                     payload: [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    /// Waits until `condition` holds, polling; fails the test after `timeout`.
    static func eventually(timeout: Duration = .seconds(5), _ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Every stream ended and left nothing behind in the shared state.
    static func expectNoStreamState<H: HTTPHandler>(_ driver: HTTP2ConnectionDriver<InMemoryTransport, H>) async throws {
        try await eventually("stream tasks to end") { driver.liveStreamTasks == 0 }
        let leftovers = driver.state.withLock { ($0.tasks.count, $0.bodies.count, $0.activeStreams) }
        #expect(leftovers == (0, 0, 0))
    }

    /// Waits on a long sleep, recording how it ended.
    final class SleepingHandler: HTTPHandler {
        let outcome = Mutex<String?>(nil)

        func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
            if request.string(of: request.path) == "/quick" { return HTTPResponse(body: .bytes(ByteBuffer("quick"))) }
            do {
                try await Task.sleep(for: .seconds(60))
                outcome.withLock { $0 = "slept" }
            } catch {
                outcome.withLock { $0 = error is CancellationError ? "cancelled" : "\(error)" }
                throw error
            }
            return HTTPResponse(status: .ok)
        }
    }

    // MARK: Peer resets

    @Test func peerResetCancelsTheHandler() async throws {
        let handler = SleepingHandler()
        try await withH2Driver(handler: handler) { client, driver in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/sleep")))
            try await Self.eventually("the handler to start") { driver.liveStreamTasks == 1 }
            try await client.send(Self.rst(1))
            try await Self.eventually("the handler to be cancelled") { handler.outcome.withLock { $0 } != nil }
            #expect(handler.outcome.withLock { $0 } == "cancelled")
            try await Self.expectNoStreamState(driver)
            // The connection keeps serving, and nothing was sent on the reset stream.
            try await client.send(F.headers(3, block: client.requests.get("/quick")))
            let response = try await client.response(on: 3)
            #expect(String(decoding: response.body, as: UTF8.self) == "quick")
            #expect(!client.reader.frames.contains { frame in
                switch frame {
                case .headers(1, _, _, _), .data(1, _, _), .rstStream(1, _): true
                default: false
                }
            }, "\(client.reader.frames)")
        }
    }

    /// A download stalled on flow control is reset: the handler task ends, the file's
    /// descriptor closes, and the connection serves the next stream.
    @Test func resetMidDownloadClosesTheFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sws-h2-reset-\(UUID().uuidString).bin")
        try Data(repeating: 0x5a, count: 1 << 20).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let opened = Mutex<(fd: Int32, inode: UInt64)?>(nil)
        let handler = ClosureHandler { request in
            if request.string(of: request.path) == "/quick" { return HTTPResponse(body: .bytes(ByteBuffer("quick"))) }
            let file = try OwnedFileDescriptor.openForReading(path: url.path)
            var info = stat()
            fstat(file.rawValue, &info)
            opened.withLock { $0 = (file.rawValue, UInt64(info.st_ino)) }
            return HTTPResponse(body: .file(try FileRegion.entireFile(file)))
        }
        try await withH2Driver(handler: handler) { client, driver in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/big")))
            // Read until the initial stream window (65,535 bytes) is used up.
            var received = 0
            var seen: [H2Frame] = []
            while received < 65_535, let frame = try await client.nextFrame(timeout: .seconds(2)) {
                seen.append(frame)
                if case .data(1, let bytes, _) = frame { received += bytes.count }
            }
            #expect(received == 65_535, "\(seen)")
            try await client.send(Self.rst(1))
            try await Self.expectNoStreamState(driver)
            let (fd, inode) = try #require(opened.withLock { $0 })
            var info = stat()
            // Closed: fstat fails, or the number was reused for another file.
            #expect(fstat(fd, &info) != 0 || UInt64(info.st_ino) != inode)
            // The download used up the connection send window: grant more for the next response.
            try await client.send(F.windowUpdate(0, 1 << 20), F.headers(3, block: client.requests.get("/quick")))
            #expect(String(decoding: try await client.response(on: 3).body, as: UTF8.self) == "quick")
        }
    }

    /// A `.stream` body writer waiting for window is cancelled by the reset: its write throws.
    @Test func resetMidStreamingBodyStopsTheWriter() async throws {
        let ended = Mutex<String?>(nil)
        let handler = ClosureHandler { _ in
            HTTPResponse(body: .stream(length: nil) { writer in
                do {
                    while true { try await writer.write(ByteBuffer(bytes: Array(repeating: 1, count: 16_384))) }
                } catch {
                    ended.withLock { $0 = "\(type(of: error))" }
                    throw error
                }
            })
        }
        try await withH2Driver(handler: handler) { client, driver in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/stream")))
            var received = 0
            while received < 65_535, let frame = try await client.nextFrame() {
                if case .data(1, let bytes, _) = frame { received += bytes.count }
            }
            try await client.send(Self.rst(1))
            try await Self.expectNoStreamState(driver)
            #expect(ended.withLock { $0 } != nil)
        }
    }

    /// DATA buffered for a handler that does not read is dropped on reset, and its connection
    /// credit returned.
    @Test func resetReturnsTheCreditOfBufferedData() async throws {
        let config = HTTP2Configuration(connectionWindowSize: 65_535)
        try await withH2Driver(configuration: config, handler: SleepingHandler()) { client, driver in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/sleep", method: "POST"), endStream: false),
                                  F.data(1, Array(repeating: 1, count: 16_000), endStream: false),
                                  F.data(1, Array(repeating: 1, count: 16_000), endStream: false),
                                  F.data(1, Array(repeating: 1, count: 16_000), endStream: false))
            try await Self.eventually("the body to be buffered") {
                driver.state.withLock { $0.bodies[1]?.bufferedBytes } == 48_000
            }
            try await client.send(Self.rst(1))
            let frames = try await client.frames(until: { if case .windowUpdate(0, _) = $0 { return true }; return false })
            #expect(frames.last == .windowUpdate(stream: 0, 48_000), "\(frames)")
            try await Self.expectNoStreamState(driver)
        }
    }

    @Test func resetOnAnIdleStreamIsAConnectionProtocolError() async throws {
        try await withH2Connection { client in
            try await client.handshake()
            try await client.send(Self.rst(5))
            let frames = try await client.framesUntilClosed()
            #expect(frames.last == .goaway(last: 0, .protocolError, debug: "PROTOCOL_ERROR"), "\(frames)")
        }
    }

    // MARK: Local resets

    /// A handler that throws `CancellationError` resets its stream with CANCEL.
    @Test func handlerCancellationSendsCancel() async throws {
        let handler = ClosureHandler { _ in throw CancellationError() }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/")))
            let frames = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(frames.last == .rstStream(stream: 1, .cancel), "\(frames)")
        }
    }

    /// A stream the server resets (a body longer than `content-length`) cancels its handler.
    @Test func serverResetCancelsTheHandler() async throws {
        let handler = SleepingHandler()
        try await withH2Driver(handler: handler) { client, driver in
            try await client.handshake()
            let block = client.requests.get("/sleep", method: "POST", extra: [("content-length", "1")])
            try await client.send(F.headers(1, block: block, endStream: false), F.data(1, [1, 2], endStream: false))
            let frames = try await client.frames(until: { if case .rstStream = $0 { return true }; return $0.isGoaway })
            #expect(frames.last == .rstStream(stream: 1, .protocolError), "\(frames)")
            try await Self.expectNoStreamState(driver)
            #expect(handler.outcome.withLock { $0 } == "cancelled")
        }
    }

    // MARK: Leaks

    /// 1,000 streams opened and reset by the client leave no task, body or count behind.
    @Test func thousandResetsLeakNothing() async throws {
        let handler = SleepingHandler()
        try await withH2Driver(handler: handler) { client, driver in
            try await client.handshake()
            var stream: UInt32 = 1
            for _ in 0..<20 {
                var frames: [ByteBuffer] = []
                for _ in 0..<50 {
                    let endStream = stream % 4 == 1  // Half with a request body, half without.
                    frames.append(F.headers(stream, block: client.requests.get("/sleep", method: "POST"), endStream: endStream))
                    if !endStream { frames.append(F.data(stream, [1, 2, 3], endStream: false)) }
                    frames.append(Self.rst(stream))
                    stream += 2
                }
                try await client.transport.send(F.join(frames), endOfStream: false)
            }
            // The PING ACK means the reader handled every frame before it.
            try await client.send(F.ping(99))
            var frames = try await client.frames(until: { $0 == .ping(ack: true, 99) })
            try await Self.expectNoStreamState(driver)
            #expect(driver.state.withLock { $0.machine.streams.activeCount } == 0)
            try await client.send(F.ping(100))
            frames += try await client.frames(until: { $0 == .ping(ack: true, 100) })
            // Streams the peer reset get no RST_STREAM back.
            #expect(!frames.contains { if case .rstStream = $0 { return true }; return $0.isGoaway }, "\(frames.count) frames")
            // Still serving.
            try await client.send(F.headers(stream, block: client.requests.get("/quick")))
            #expect(String(decoding: try await client.response(on: stream).body, as: UTF8.self) == "quick")
        }
    }
}
