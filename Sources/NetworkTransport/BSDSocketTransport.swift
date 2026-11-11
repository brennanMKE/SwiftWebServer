public import HTTPCore
import Darwin
import Synchronization

/// A ``ByteStreamTransport`` over a non-blocking POSIX TCP socket and kqueue (#0113).
///
/// An optional alternative to ``TCPTransport`` for **cleartext TCP only**; TLS and QUIC stay on
/// Network.framework. It exists because accepting through `NWListener` costs hundreds of
/// microseconds of CPU per connection on one process-wide serial queue (see
/// `docs/benchmarks/M3-accept.md`).
///
/// ## Demand
///
/// Each ``receive(into:maxLength:)`` makes one `read(2)` of at most `maxLength` bytes straight
/// into the caller's buffer tail. Only when the socket has nothing to read does it arm a
/// one-shot kqueue wait and suspend; the event resumes the task, which reads again. Nothing is
/// read ahead and no bytes are buffered outside the kernel, so a connection that stops
/// receiving applies TCP flow control to the peer.
///
/// ## Sending
///
/// ``send(_:endOfStream:)`` writes until the kernel has accepted every byte, waiting for
/// writability when the socket buffer is full, so a slow reader slows the writer.
/// `endOfStream` then shuts down the write side (`shutdown(SHUT_WR)`, a FIN); receiving
/// continues.
///
/// ## Cancellation and close
///
/// As in ``TCPTransport``: cancelling a task waiting in `receive` or `send` throws
/// `CancellationError` at once and closes the connection; later calls throw
/// ``TransportError/closed``. ``close(_:)`` closes the socket (gracefully, or with a reset for
/// ``CloseReason/abort``) and fails a receive or send in progress with
/// ``TransportError/closed``.
public final class BSDSocketTransport: ByteStreamTransport {
    let core: SocketCore
    public let info: ConnectionInfo
    /// `CLOCK_UPTIME_RAW` nanoseconds when `accept(2)` returned this connection (0 for
    /// outbound connections). An accepted socket is ready at once.
    let acceptedAt: UInt64

    init(core: SocketCore, info: ConnectionInfo, acceptedAt: UInt64 = 0) {
        self.core = core
        self.info = info
        self.acceptedAt = acceptedAt
    }

    deinit {
        core.requestClose(abortive: false)
    }

    /// When the listener accepted this connection and when it became ready (the same instant
    /// for a socket), in `CLOCK_UPTIME_RAW` nanoseconds. For `sws-bench accept`.
    @_spi(Benchmark) public var acceptTimestamps: (handedOver: UInt64, ready: UInt64) {
        (acceptedAt, acceptedAt)
    }

    // MARK: Client

    /// Opens a TCP connection to the numeric address `host:port` and returns once it is
    /// established. A refused or unreachable connection throws. Cancelling the calling task
    /// cancels the attempt.
    public static func connect(
        host: String,
        port: UInt16,
        configuration: TCPConfiguration = TCPConfiguration()
    ) async throws -> BSDSocketTransport {
        guard port != 0, let address = BSDSocket.address(host: host, port: port) else {
            throw TransportError.failed(code: EINVAL)
        }
        let fd = socket(Int32(address.ss_family), SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError(errno: errno) }
        if BSDSocket.setNonBlocking(fd) != 0 {
            let code = errno
            Darwin.close(fd)
            throw TransportError(errno: code)
        }
        BSDSocket.configureConnection(fd, configuration)
        let core = SocketCore(fd: fd, loop: BSDEventLoop.next(), closesOnCancel: true)
        var storage = address
        let result = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, BSDSocket.length(of: address)) }
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
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            if error != 0 {
                core.requestClose(abortive: false)
                throw TransportError(errno: error)
            }
        }
        var peer = sockaddr_storage()
        var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &peerLength) }
        }
        let info = ConnectionInfo(localAddress: BSDSocket.localAddress(fd), remoteAddress: BSDSocket.transportAddress(peer))
        return BSDSocketTransport(core: core, info: info)
    }

    // MARK: ByteStreamTransport

    public func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        precondition(maxLength > 0, "maxLength must be positive")
        let start = try core.state.withLock { state throws(TransportError) -> Bool in
            if state.closedLocally { throw .closed }
            if state.receiving { throw .receiveAlreadyPending }
            if let error = state.inputError { throw error }
            if state.inputEnded { return false }
            state.receiving = true
            return true
        }
        guard start else { return 0 }
        defer { core.state.withLock { $0.receiving = false } }

        while true {
            guard let fd = core.acquire() else { throw TransportError.closed }
            let result: Int = buffer.withUnsafeMutableWritableBytes(minimumWritableBytes: maxLength) { tail in
                let n = read(fd, tail.baseAddress, maxLength)
                return n >= 0 ? n : -Int(errno)
            }
            core.release()
            if result > 0 {
                buffer.commitWritten(result)
                return result
            }
            if result == 0 {
                core.state.withLock { $0.inputEnded = true }
                return 0
            }
            let code = Int32(-result)
            if code == EINTR { continue }
            if code == EAGAIN {
                switch await core.wait(.read) {
                case .ready: continue
                case .cancelled: throw CancellationError()
                case .closed: throw TransportError.closed
                }
            }
            let error = core.state.withLock { state -> TransportError in
                let error = state.closedLocally ? TransportError.closed : TransportError(errno: code)
                state.inputError = error
                return error
            }
            throw error
        }
    }

    public func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws {
        try core.state.withLock { state throws(TransportError) in
            if state.closedLocally { throw .closed }
            if state.outputShutdown { throw .outputShutdown }
            precondition(!state.sending, "BSDSocketTransport: concurrent send calls")
            state.sending = true
            if endOfStream { state.outputShutdown = true }
        }
        defer { core.state.withLock { $0.sending = false } }

        let total = bytes.readableBytes
        var offset = 0
        while offset < total {
            guard let fd = core.acquire() else { throw TransportError.closed }
            let result: Int = bytes.withUnsafeReadableBytes { raw in
                let n = write(fd, raw.baseAddress! + offset, total - offset)
                return n >= 0 ? n : -Int(errno)
            }
            core.release()
            if result >= 0 {
                offset += result
                continue
            }
            let code = Int32(-result)
            if code == EINTR { continue }
            if code == EAGAIN {
                switch await core.wait(.write) {
                case .ready: continue
                case .cancelled: throw CancellationError()
                case .closed: throw TransportError.closed
                }
            }
            throw core.state.withLock { $0.closedLocally } ? TransportError.closed : TransportError(errno: code)
        }
        if endOfStream {
            guard let fd = core.acquire() else { throw TransportError.closed }
            let result = shutdown(fd, SHUT_WR)
            let code = errno
            core.release()
            if result != 0 && code != ENOTCONN { throw TransportError(errno: code) }
        }
    }

    public func close(_ reason: CloseReason) async {
        let first = core.state.withLock { state -> Bool in
            defer { state.closeCalled = true; state.closedLocally = true }
            return !state.closeCalled
        }
        guard first else { return }
        core.requestClose(abortive: reason.isAbortive)
    }
}
