import Testing
import Foundation
import HTTPCore
@testable import Proxy

/// Blocking one-shot Unix-socket upstream on a background thread.
private func startUnixUpstream(path: String) throws -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
    guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw UpstreamError.connectFailed("bind") }
    Thread.detachNewThread {
        let c = accept(fd, nil, nil)
        guard c >= 0 else { return }
        var received: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 1024)
        while UpstreamResponseParser.findHeadEnd(received) == nil {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            received += buf[0..<n]
        }
        let response = Array("HTTP/1.1 200 OK\r\ncontent-length: 4\r\nconnection: close\r\n\r\nunix".utf8)
        _ = response.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
        close(c)
    }
    return fd
}

@Suite struct UpstreamUnixSocketTests {
    @Test(.timeLimit(.minutes(1))) func getOverUnixSocket() async throws {
        let path = NSTemporaryDirectory() + "sws-up-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        let listenFD = try startUnixUpstream(path: path)
        defer { close(listenFD); unlink(path) }
        let client = UpstreamHTTP1Client()
        let target = UpstreamTarget(address: .unix(path: path))
        let request = UpstreamRequest(method: .get, target: "/", host: "localhost", headers: HTTPFields())
        let response = try await client.send(request, body: .empty, to: target)
        #expect(response.status.code == 200)
        #expect(try await collect(response.body) == "unix")
        // Connection: close means it is not pooled.
        #expect(client.idleCount(for: target.address) == 0)
        await client.shutdown()
    }
}
