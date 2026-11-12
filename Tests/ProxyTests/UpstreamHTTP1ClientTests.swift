import Testing
import Synchronization
import HTTPCore
import NetworkTransport
@testable import Proxy

/// A request body made of fixed chunks.
final class FixedBodySource: HTTPRequestBodySource, @unchecked Sendable {
    private let chunks = Mutex<[ByteBuffer]>([])
    init(_ parts: [String]) { chunks.withLock { $0 = parts.map { ByteBuffer(bytes: Array($0.utf8)) } } }
    func nextChunk(request: UInt64) async throws -> ByteBuffer? {
        chunks.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
    func trailers(request: UInt64) -> HTTPFields? { nil }
}

/// Minimal keep-alive HTTP/1.1 upstream on 127.0.0.1:0.
final class TinyUpstream: Sendable {
    let listener: BSDSocketListener
    let port: UInt16
    let task: Task<Void, Never>

    init() async throws {
        listener = try BSDSocketListener()
        port = try await listener.start()
        let l = listener
        task = Task {
            await withTaskGroup(of: Void.self) { group in
                do {
                    for try await conn in l.connections {
                        group.addTask { await TinyUpstream.serve(conn) }
                    }
                } catch {}
                group.cancelAll()
            }
        }
    }

    func stop() async {
        await listener.close()
        task.cancel()
        await task.value
    }

    static func read(_ conn: BSDSocketTransport, into pending: inout [UInt8]) async -> Bool {
        var b = ByteBuffer(capacity: 4096)
        guard let n = try? await conn.receive(into: &b, maxLength: 4096), n > 0 else { return false }
        b.withUnsafeReadableBytes { pending.append(contentsOf: $0) }
        return true
    }

    static func serve(_ conn: BSDSocketTransport) async {
        var pending: [UInt8] = []
        defer { Task { await conn.close(.normal) } }
        while true {
            while UpstreamResponseParser.findHeadEnd(pending) == nil {
                guard await read(conn, into: &pending) else { return }
            }
            let end = UpstreamResponseParser.findHeadEnd(pending)!
            let head = String(decoding: pending[0..<end], as: UTF8.self)
            pending.removeFirst(end)
            let lines = head.split(separator: "\r\n")
            let path = lines[0].split(separator: " ")[1]
            var body: [UInt8] = []
            if let cl = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }) {
                let n = Int(cl.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))!
                while pending.count < n { guard await read(conn, into: &pending) else { return } }
                body = Array(pending[0..<n]); pending.removeFirst(n)
            } else if lines.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") }) {
                // Decode a simple chunked body.
                while true {
                    while !pending.contains(10) { guard await read(conn, into: &pending) else { return } }
                    let nl = pending.firstIndex(of: 10)!
                    let size = Int(String(decoding: pending[0..<(nl - 1)], as: UTF8.self), radix: 16)!
                    pending.removeFirst(nl + 1)
                    while pending.count < size + 2 { guard await read(conn, into: &pending) else { return } }
                    if size == 0 { pending.removeFirst(2); break }
                    body += pending[0..<size]; pending.removeFirst(size + 2)
                }
            }
            let response: String
            switch path {
            case "/chunked":
                response = "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n2\r\nab\r\n3\r\ncde\r\n0\r\n\r\n"
            case "/close":
                _ = try? await conn.send(ByteBuffer(bytes: Array("HTTP/1.1 200 OK\r\n\r\nuntil-eof".utf8)), endOfStream: true)
                return
            case "/truncated":
                _ = try? await conn.send(ByteBuffer(bytes: Array("HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\nabc".utf8)), endOfStream: true)
                return
            case "/bad":
                _ = try? await conn.send(ByteBuffer(bytes: Array("HTTP/1.1 2 OK\r\n\r\n".utf8)), endOfStream: true)
                return
            case "/echo":
                response = "HTTP/1.1 200 OK\r\ncontent-length: \(body.count)\r\n\r\n" + String(decoding: body, as: UTF8.self)
            default:
                response = "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 5\r\n\r\nhello"
            }
            do { try await conn.send(ByteBuffer(bytes: Array(response.utf8)), endOfStream: false) } catch { return }
        }
    }
}

extension String {
    func trimmingCharacters(in _: Whitespace) -> String {
        String(drop(while: { $0 == " " }).reversed().drop(while: { $0 == " " }).reversed())
    }
    enum Whitespace { case whitespaces }
}

func collect(_ body: UpstreamResponseBody) async throws -> String {
    var out: [UInt8] = []
    while let chunk = try await body.next() {
        chunk.withUnsafeReadableBytes { out.append(contentsOf: $0) }
    }
    return String(decoding: out, as: UTF8.self)
}

@Suite struct UpstreamResponseParserTests {
    @Test func parsesHeadSplitInvariant() throws {
        let raw = Array("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-A: b\r\n\r\nhello".utf8)
        let parser = UpstreamResponseParser()
        for split in 0..<raw.count {
            let partial = Array(raw[0..<split])
            if let (head, used) = try parser.parseHead(partial) {
                #expect(used == raw.count - 5)
                #expect(head.framing == .length(5))
            }
        }
        let (head, used) = try #require(try parser.parseHead(raw))
        #expect(used == raw.count - 5)
        #expect(head.status.code == 200)
        #expect(head.framing == .length(5))
        #expect(head.closeAfter == false)
        #expect(head.headers.count == 2)
    }

    @Test func framingRules() throws {
        let p = UpstreamResponseParser()
        func framing(_ s: String, method: HTTPMethod? = nil) throws -> UpstreamResponseHead {
            try #require(try p.parseHead(Array(s.utf8), requestMethod: method)).0
        }
        #expect(try framing("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n").framing == .chunked)
        #expect(try framing("HTTP/1.1 200 OK\r\n\r\n").framing == .close)
        #expect(try framing("HTTP/1.1 204 No Content\r\n\r\n").framing == .none)
        #expect(try framing("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n", method: .head).framing == .none)
        #expect(try framing("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 1\r\n\r\n").closeAfter)
        #expect(try framing("HTTP/1.0 200 OK\r\nContent-Length: 1\r\n\r\n").closeAfter)
    }

    @Test func rejectsMalformed() {
        let p = UpstreamResponseParser()
        for bad in ["HTTP/2 200 OK\r\n\r\n", "HTTP/1.1 2x0 OK\r\n\r\n", "HTTP/1.1 200 OK\r\nBad Name: x\r\n\r\n",
                    "HTTP/1.1 200 OK\r\nContent-Length: 1, 2\r\n\r\n", "HTTP/1.1 200 OK\nA: b\r\n\r\n"] {
            #expect(throws: UpstreamError.self) { _ = try p.parseHead(Array(bad.utf8)) }
        }
        let big = UpstreamResponseParser(limits: .init(maxHeadBytes: 32))
        #expect(throws: UpstreamError.self) { _ = try big.parseHead(Array(("HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: 64)).utf8)) }
    }
}

@Suite(.serialized) struct UpstreamHTTP1ClientTests {
    func request(_ method: HTTPMethod, _ path: String, port: UInt16) -> UpstreamRequest {
        UpstreamRequest(method: method, target: path, host: "127.0.0.1:\(port)", headers: HTTPFields())
    }

    @Test(.timeLimit(.minutes(1))) func getContentLengthAndKeepAlive() async throws {
        let upstream = try await TinyUpstream()
        let client = UpstreamHTTP1Client()
        let target = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: upstream.port))
        let r1 = try await client.send(request(.get, "/cl", port: upstream.port), body: .empty, to: target)
        #expect(r1.status.code == 200)
        #expect(r1.body.knownLength == 5)
        #expect(try await collect(r1.body) == "hello")
        let r2 = try await client.send(request(.get, "/cl", port: upstream.port), body: .empty, to: target)
        #expect(try await collect(r2.body) == "hello")
        #expect(client.connectionsOpened == 1)
        #expect(client.idleCount(for: target.address) == 1)
        await client.shutdown()
        await upstream.stop()
    }

    @Test(.timeLimit(.minutes(1))) func chunkedResponse() async throws {
        let upstream = try await TinyUpstream()
        let client = UpstreamHTTP1Client()
        let target = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: upstream.port))
        let r = try await client.send(request(.get, "/chunked", port: upstream.port), body: .empty, to: target)
        #expect(r.body.knownLength == nil)
        #expect(try await collect(r.body) == "abcde")
        #expect(client.idleCount(for: target.address) == 1)
        await client.shutdown()
        await upstream.stop()
    }

    @Test(.timeLimit(.minutes(1))) func postEchoesBody() async throws {
        let upstream = try await TinyUpstream()
        let client = UpstreamHTTP1Client()
        let target = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: upstream.port))
        // Unknown length: sent chunked.
        let body = HTTPRequestBody(source: FixedBodySource(["hel", "lo ", "world"]), request: 1, length: nil)
        let r = try await client.send(request(.post, "/echo", port: upstream.port), body: body, to: target)
        #expect(try await collect(r.body) == "hello world")
        // Known length: sent with content-length, on the reused connection.
        let body2 = HTTPRequestBody(source: FixedBodySource(["abc", "de"]), request: 2, length: 5)
        let r2 = try await client.send(request(.post, "/echo", port: upstream.port), body: body2, to: target)
        #expect(try await collect(r2.body) == "abcde")
        #expect(client.connectionsOpened == 1)
        await client.shutdown()
        await upstream.stop()
    }
}

@Suite(.serialized) struct UpstreamHTTP1ClientFailureTests {
    @Test(.timeLimit(.minutes(1))) func closeDelimitedTruncatedAndMalformed() async throws {
        let upstream = try await TinyUpstream()
        let client = UpstreamHTTP1Client()
        let target = UpstreamTarget(address: .tcp(host: "127.0.0.1", port: upstream.port))
        func req(_ p: String) -> UpstreamRequest {
            UpstreamRequest(method: .get, target: p, host: "127.0.0.1", headers: HTTPFields())
        }
        let r = try await client.send(req("/close"), body: .empty, to: target)
        #expect(try await collect(r.body) == "until-eof")
        #expect(client.idleCount(for: target.address) == 0)

        let t = try await client.send(req("/truncated"), body: .empty, to: target)
        await #expect(throws: UpstreamError.closedEarly) { _ = try await collect(t.body) }
        #expect(client.idleCount(for: target.address) == 0)

        await #expect(throws: UpstreamError.self) { _ = try await client.send(req("/bad"), body: .empty, to: target) }
        #expect(client.idleCount(for: target.address) == 0)
        await client.shutdown()
        await upstream.stop()
    }
}
