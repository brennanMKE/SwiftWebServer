@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// #0049: every stream runs its handler in its own child task, and the response becomes
/// HEADERS (+ CONTINUATION) and DATA frames.
@Suite(.timeLimit(.minutes(1)))
struct H2ResponseTests {
    /// Streams run concurrently: a handler that waits does not hold up the next stream.
    @Test func streamsRunConcurrently() async throws {
        let gate = Gate()
        let handler = ClosureHandler { request in
            if request.string(of: request.path) == "/slow" { await gate.wait() }
            return HTTPResponse(body: .bytes(ByteBuffer(bytes: Array(request.string(of: request.path).utf8))))
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/slow")), F.headers(3, block: client.requests.get("/fast")))
            #expect(String(decoding: try await client.response(on: 3).body, as: UTF8.self) == "/fast")
            gate.open()
            #expect(String(decoding: try await client.response(on: 1).body, as: UTF8.self) == "/slow")
        }
    }

    /// 304 and 204 (like HEAD) end the stream on HEADERS: no DATA frame.
    @Test(arguments: [HTTPStatus.notModified, .noContent])
    func bodylessStatusEndsTheStreamOnHeaders(status: HTTPStatus) async throws {
        let handler = ClosureHandler { _ in HTTPResponse(status: status, body: .bytes(ByteBuffer("ignored"))) }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/")))
            let frames = try await client.frames(until: { if case .headers(1, _, _, _) = $0 { return true }; return false })
            guard case .headers(1, let endStream, true, _)? = frames.last else {
                Issue.record("\(frames)")
                return
            }
            #expect(endStream)
            try await client.send(F.ping(1))
            let rest = try await client.frames(until: { $0 == .ping(ack: true, 1) })
            #expect(!rest.contains { if case .data = $0 { return true }; return false }, "\(rest)")
        }
    }

    /// DATA frames follow the peer's SETTINGS_MAX_FRAME_SIZE once it is larger than 16,384.
    @Test func dataFramesUseThePeersMaxFrameSize() async throws {
        let size = 200_000
        let handler = ClosureHandler { _ in HTTPResponse(body: .bytes(ByteBuffer(bytes: Array(repeating: 7, count: size)))) }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake(HTTP2Settings(initialWindowSize: 1 << 20, maxFrameSize: 40_000))
            try await client.send(F.windowUpdate(0, 1 << 20))
            try await client.send(F.headers(1, block: client.requests.get("/")))
            var sizes: [Int] = []
            while let frame = try await client.nextFrame() {
                guard case .data(1, let bytes, let endStream) = frame else { continue }
                sizes.append(bytes.count)
                if endStream { break }
            }
            #expect(sizes.reduce(0, +) == size)
            #expect(sizes.max() == 40_000, "\(sizes)")
        }
    }

    /// A body that fails after HEADERS cannot become a 500: the stream is reset with
    /// INTERNAL_ERROR, and the connection carries on.
    @Test func bodyFailureAfterHeadersIsInternalError() async throws {
        struct Broken: Error {}
        let handler = ClosureHandler { request in
            if request.string(of: request.path) == "/ok" { return HTTPResponse(body: .bytes(ByteBuffer("ok"))) }
            return HTTPResponse(body: .stream(length: nil) { writer in
                try await writer.write(ByteBuffer("partial"))
                throw Broken()
            })
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/broken")))
            let response = try await client.response(on: 1)
            #expect(response.head.first?.1 == "200")
            #expect(response.others.last == .rstStream(stream: 1, .internalError), "\(response.others)")
            try await client.send(F.headers(3, block: client.requests.get("/ok")))
            #expect(String(decoding: try await client.response(on: 3).body, as: UTF8.self) == "ok")
        }
    }

    /// Response fields that are not valid in HTTP/2 are dropped, names are lowercased, and
    /// `content-length` is added for a known length.
    @Test func responseHeadIsMappedToHTTP2() async throws {
        let handler = ClosureHandler { _ in
            var headers = HTTPFields()
            headers.append(name: "Transfer-Encoding", value: "chunked")
            headers.append(name: "Upgrade", value: "h2c")
            headers.append(name: "Keep-Alive", value: "timeout=5")
            headers.append(name: "X-Custom", value: "Value")
            return HTTPResponse(status: .created, headers: headers, body: .bytes(ByteBuffer("abc")))
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/")))
            let response = try await client.response(on: 1)
            #expect(response.head.map(\.0) == [":status", "x-custom", "content-length"])
            #expect(response.head.map(\.1) == ["201", "Value", "3"])
            #expect(response.body == Array("abc".utf8))
        }
    }
}
