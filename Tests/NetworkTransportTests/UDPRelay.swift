import Darwin
import Synchronization

/// A loopback UDP relay for observing a QUIC connection from outside (#0104, spike Q6): the
/// client sends to ``port`` and the relay forwards to the server's port, and back. It keeps
/// every datagram in both directions with its time, so a test can see (and decrypt) what each
/// side sent around a close.
///
/// 127.0.0.1 only (AGENTS.md). ``run()`` polls with a short timeout until its task is cancelled.
final class UDPRelay: Sendable {
    struct Datagram: Sendable {
        let at: ContinuousClock.Instant
        let size: Int
        let firstByte: UInt8
        let bytes: [UInt8]
        /// True for server to client.
        let fromServer: Bool
    }

    let port: UInt16
    private let front: Int32
    private let back: Int32
    private let serverPort: UInt16
    private let log = Mutex<[Datagram]>([])

    init(serverPort: UInt16) throws {
        self.serverPort = serverPort
        front = try Self.bindLoopback()
        back = try Self.bindLoopback()
        port = Self.localPort(front)
    }

    deinit {
        close(front)
        close(back)
    }

    /// Server-to-client datagrams so far.
    var serverDatagrams: [Datagram] { log.withLock { $0.filter(\.fromServer) } }
    /// Datagrams in both directions so far, in order.
    var datagrams: [Datagram] { log.withLock { $0 } }

    func run() async {
        var client = sockaddr_in()
        var haveClient = false
        var server = Self.loopback(port: serverPort)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var fds = [pollfd(fd: front, events: Int16(POLLIN), revents: 0), pollfd(fd: back, events: Int16(POLLIN), revents: 0)]
        while !Task.isCancelled {
            guard poll(&fds, 2, 20) > 0 else {
                await Task.yield()
                continue
            }
            if fds[0].revents & Int16(POLLIN) != 0 {
                var from = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = buffer.withUnsafeMutableBytes { raw in
                    withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(front, raw.baseAddress, raw.count, 0, $0, &length) }
                    }
                }
                if n > 0 {
                    let datagram = Datagram(at: .now, size: n, firstByte: buffer[0], bytes: Array(buffer[0..<n]), fromServer: false)
                    log.withLock { $0.append(datagram) }
                    client = from
                    haveClient = true
                    _ = buffer.withUnsafeBytes { raw in
                        withUnsafePointer(to: &server) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(back, raw.baseAddress, n, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
            }
            if fds[1].revents & Int16(POLLIN) != 0 {
                let n = buffer.withUnsafeMutableBytes { recv(back, $0.baseAddress, $0.count, 0) }
                if n > 0 {
                    let datagram = Datagram(at: .now, size: n, firstByte: buffer[0], bytes: Array(buffer[0..<n]), fromServer: true)
                    log.withLock { $0.append(datagram) }
                    if haveClient {
                        _ = buffer.withUnsafeBytes { raw in
                            withUnsafePointer(to: &client) {
                                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                    sendto(front, raw.baseAddress, n, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                                }
                            }
                        }
                    }
                }
            }
            fds[0].revents = 0
            fds[1].revents = 0
        }
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        return address
    }

    private static func bindLoopback() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw RelayError.socket(errno) }
        var address = loopback(port: 0)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            close(fd)
            throw RelayError.socket(errno)
        }
        return fd
    }

    private static func localPort(_ fd: Int32) -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    enum RelayError: Error {
        case socket(Int32)
    }
}
