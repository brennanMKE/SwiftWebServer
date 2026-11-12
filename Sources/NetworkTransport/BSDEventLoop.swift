import Darwin
import Foundation
import HTTPCore
import Synchronization

/// Something a kqueue event wakes (a ``BSDSocketTransport`` or ``BSDSocketListener`` core).
///
/// `@unchecked Sendable`: subclasses keep all mutable state in a `Mutex`.
class KQueueTarget: @unchecked Sendable {
    /// Called on the event loop's thread when an armed one-shot wait fires. Must not block.
    func eventFired(filter: Int16) {}
}

/// A kqueue and the thread that waits on it (#0113).
///
/// Waits are **one-shot** (`EV_ONESHOT`): a transport arms one when a non-blocking `read`,
/// `write`, `accept` or `connect` reports `EAGAIN`, and the event resumes the task that is
/// waiting, which then retries the system call. Nothing is read or written on the loop's
/// thread, so the loop never buffers bytes and demand stays with the caller.
///
/// Ownership: arming retains the target and stores it as the event's `udata`. Exactly one of
/// two things releases it: the loop, when the event fires (a fired one-shot event is removed
/// from the kqueue), or ``disarm(fd:filter:target:)``, when `EV_DELETE` removes a wait that has
/// not fired. A target therefore cannot be freed while the kernel can still return it.
///
/// The loop threads live as long as the process, like Network.framework's own threads. This is
/// the one place in the package that creates threads; it needs no `DispatchQueue`.
final class BSDEventLoop: Sendable {
    let kq: Int32

    private init(index: Int) {
        kq = kqueue()
        precondition(kq >= 0, "kqueue() failed: errno \(errno)")
        let kq = self.kq
        let thread = Thread {
            var events = [Darwin.kevent](repeating: Darwin.kevent(), count: 128)
            while true {
                let count = events.withUnsafeMutableBufferPointer { buffer in
                    waitForEvents(kq, buffer.baseAddress, Int32(buffer.count))
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    fatalError("kevent() failed: errno \(errno)")
                }
                for i in 0..<Int(count) {
                    guard let udata = events[i].udata else { continue }
                    let target = Unmanaged<KQueueTarget>.fromOpaque(udata).takeRetainedValue()
                    target.eventFired(filter: events[i].filter)
                }
            }
        }
        thread.name = "sws.bsd.loop.\(index)"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 256 * 1024
        thread.start()
    }

    /// Arms a one-shot wait for `filter` (`EVFILT_READ` or `EVFILT_WRITE`) on `fd`, retaining
    /// `target` until it fires or is disarmed. Returns 0, or the `errno` when arming failed (the
    /// target is then not retained).
    func arm(fd: Int32, filter: Int16, target: KQueueTarget) -> Int32 {
        let udata = Unmanaged.passRetained(target).toOpaque()
        var change = kevent(
            ident: UInt(fd), filter: filter, flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: 0, data: 0, udata: udata)
        while kevent(kq, &change, 1, nil, 0, nil) < 0 {
            let code = errno
            if code == EINTR { continue }
            Unmanaged<KQueueTarget>.fromOpaque(udata).release()
            return code
        }
        return 0
    }

    /// Removes an armed wait that has not fired and releases its target. Returns false when
    /// the wait already fired (the loop releases the target when it delivers the event).
    @discardableResult
    func disarm(fd: Int32, filter: Int16, target: KQueueTarget) -> Bool {
        var change = kevent(ident: UInt(fd), filter: filter, flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: nil)
        while kevent(kq, &change, 1, nil, 0, nil) < 0 {
            if errno == EINTR { continue }
            return false
        }
        Unmanaged.passUnretained(target).release()
        return true
    }

    // MARK: Group

    /// The process-wide loops. Two are plenty: a loop only resumes continuations, and the
    /// system calls run on the tasks that wait for them.
    private static let shared: [BSDEventLoop] = (0..<2).map { BSDEventLoop(index: $0) }
    private static let nextIndex = Atomic<Int>(0)

    /// The next loop, round-robin.
    static func next() -> BSDEventLoop {
        let index = nextIndex.add(1, ordering: .relaxed).oldValue
        return shared[index & 1]
    }
}

/// `kevent(2)` used only to wait (no changes).
private func waitForEvents(_ kq: Int32, _ list: UnsafeMutablePointer<Darwin.kevent>?, _ count: Int32) -> Int32 {
    kevent(kq, nil, 0, list, count, nil)
}

// MARK: - Socket helpers

enum BSDSocket {
    /// Sets a socket option, returning `errno` on failure.
    @discardableResult
    static func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) -> Int32 {
        var value = value
        return setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 ? 0 : errno
    }

    static func setNonBlocking(_ fd: Int32) -> Int32 {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return errno }
        if flags & O_NONBLOCK != 0 { return 0 }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 ? 0 : errno
    }

    /// Per-connection options: no `SIGPIPE`, `TCP_NODELAY` and keep-alive per `configuration`.
    static func configureConnection(_ fd: Int32, _ configuration: TCPConfiguration) {
        setOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
        if configuration.noDelay { setOption(fd, Int32(IPPROTO_TCP), TCP_NODELAY, 1) }
        if let keepAlive = configuration.keepAlive {
            setOption(fd, SOL_SOCKET, SO_KEEPALIVE, 1)
            setOption(fd, Int32(IPPROTO_TCP), TCP_KEEPALIVE, Int32(keepAlive.idle))
            setOption(fd, Int32(IPPROTO_TCP), TCP_KEEPINTVL, Int32(keepAlive.interval))
            setOption(fd, Int32(IPPROTO_TCP), TCP_KEEPCNT, Int32(keepAlive.count))
        }
    }

    /// A numeric IPv4 or IPv6 socket address, or `nil` when `host` is not numeric. This
    /// transport does not resolve names.
    static func address(host: String, port: UInt16) -> sockaddr_storage? {
        var storage = sockaddr_storage()
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            withUnsafeMutableBytes(of: &storage) { raw in
                let sin = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self)
                sin.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                sin.pointee.sin_family = sa_family_t(AF_INET)
                sin.pointee.sin_port = port.bigEndian
                sin.pointee.sin_addr = v4
            }
            return storage
        }
        var v6 = in6_addr()
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        if inet_pton(AF_INET6, bare, &v6) == 1 {
            withUnsafeMutableBytes(of: &storage) { raw in
                let sin6 = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self)
                sin6.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                sin6.pointee.sin6_family = sa_family_t(AF_INET6)
                sin6.pointee.sin6_port = port.bigEndian
                sin6.pointee.sin6_addr = v6
            }
            return storage
        }
        return nil
    }

    static func length(of storage: sockaddr_storage) -> socklen_t {
        socklen_t(storage.ss_family == sa_family_t(AF_INET6)
                  ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
    }

    /// The numeric host and port of an IPv4 or IPv6 socket address. IPv4 hosts fit in a small
    /// (inline) `String`, so this does not allocate for them.
    static func transportAddress(_ storage: sockaddr_storage) -> TransportAddress? {
        withUnsafeBytes(of: storage) { raw -> TransportAddress? in
            var text = (Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0))
            return withUnsafeMutableBytes(of: &text) { out -> TransportAddress? in
                let chars = out.baseAddress!.assumingMemoryBound(to: CChar.self)
                switch Int32(storage.ss_family) {
                case AF_INET:
                    let sin = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self)
                    var address = sin.pointee.sin_addr
                    guard inet_ntop(AF_INET, &address, chars, socklen_t(out.count)) != nil else { return nil }
                    return TransportAddress(host: String(cString: chars), port: UInt16(bigEndian: sin.pointee.sin_port))
                case AF_INET6:
                    let sin6 = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self)
                    var address = sin6.pointee.sin6_addr
                    guard inet_ntop(AF_INET6, &address, chars, socklen_t(out.count)) != nil else { return nil }
                    return TransportAddress(host: String(cString: chars), port: UInt16(bigEndian: sin6.pointee.sin6_port))
                default:
                    return nil
                }
            }
        }
    }

    static func localAddress(_ fd: Int32) -> TransportAddress? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return result == 0 ? transportAddress(storage) : nil
    }
}

extension TransportError {
    /// Maps a socket `errno` to the transport vocabulary (the same mapping as for NW's POSIX
    /// errors).
    init(errno code: Int32) {
        switch code {
        case ECONNRESET, EPIPE, ECONNABORTED, ENOTCONN, ENETRESET:
            self = .connectionReset
        case ETIMEDOUT:
            self = .timedOut
        case ECANCELED, EBADF:
            self = .closed
        default:
            self = .failed(code: code)
        }
    }
}
