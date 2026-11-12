public import HTTPCore
import Darwin

extension BSDSocketTransport {
    /// Opens a stream connection to the Unix-domain socket at `path` on the shared kqueue
    /// event loop. A missing or refusing socket throws. Cancelling the calling task cancels
    /// the attempt.
    public static func connect(unixPath path: String) async throws -> BSDSocketTransport {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !pathBytes.isEmpty, pathBytes.count < capacity else { throw TransportError.failed(code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(truncatingIfNeeded: length)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError(errno: errno) }
        if BSDSocket.setNonBlocking(fd) != 0 {
            let code = errno
            Darwin.close(fd)
            throw TransportError(errno: code)
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let core = SocketCore(fd: fd, loop: BSDEventLoop.next(), closesOnCancel: true)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        if result != 0 {
            let code = errno
            guard code == EINPROGRESS || code == EINTR else {
                core.requestClose(abortive: false)
                throw TransportError(errno: code)
            }
            switch await core.wait(.write) {
            case .ready: break
            case .cancelled: throw CancellationError()
            case .closed: throw TransportError.closed
            }
            var error: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &errorLength)
            if error != 0 {
                core.requestClose(abortive: false)
                throw TransportError(errno: error)
            }
        }
        return BSDSocketTransport(core: core, info: ConnectionInfo(localAddress: nil, remoteAddress: nil))
    }
}
