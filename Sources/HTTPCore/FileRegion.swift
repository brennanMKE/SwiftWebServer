#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An open file descriptor that is closed when the last reference goes away.
///
/// A ``FileRegion`` keeps its file alive until the response that carries it has been sent, so
/// a region can outlive the handler that opened it without leaking or double-closing the
/// descriptor. Reads use `pread`, which takes an explicit offset and never moves the shared file
/// position, so one descriptor can serve concurrent regions.
public final class OwnedFileDescriptor: Sendable {
    /// The POSIX file descriptor. Do not close it; the object does.
    public let rawValue: Int32

    /// Takes ownership of `rawValue`, which is closed on deinit.
    public init(takingOwnershipOf rawValue: Int32) {
        precondition(rawValue >= 0, "invalid file descriptor \(rawValue)")
        self.rawValue = rawValue
    }

    /// Opens `path` read-only (with `O_CLOEXEC`).
    public static func openForReading(path: String) throws(TransportError) -> OwnedFileDescriptor {
        let fd = path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
        guard fd >= 0 else { throw .fileOpenFailed(errno: errno) }
        return OwnedFileDescriptor(takingOwnershipOf: fd)
    }

    /// The file's current size in bytes (`fstat`).
    public func size() throws(TransportError) -> Int64 {
        var info = stat()
        guard fstat(rawValue, &info) == 0 else { throw .fileOpenFailed(errno: errno) }
        return Int64(info.st_size)
    }

    deinit {
        _ = close(rawValue)
    }
}

/// A byte range of an open file, sent with ``ByteStreamTransport/sendFile(_:)``
/// (docs/ROADMAP.md §5.2; `HTTPResponseBody.file`).
public struct FileRegion: Sendable {
    /// The file; kept open while the region exists.
    public let file: OwnedFileDescriptor
    /// Offset of the first byte to send.
    public let offset: Int64
    /// Number of bytes to send.
    public let length: Int64

    /// Default read size for the chunked `pread` fallback: large enough to amortise a send per
    /// chunk, small enough that a large file never occupies more than one chunk of memory.
    public static let defaultChunkSize = 64 * 1024

    public init(file: OwnedFileDescriptor, offset: Int64 = 0, length: Int64) {
        precondition(offset >= 0 && length >= 0, "FileRegion offset and length must not be negative")
        self.file = file
        self.offset = offset
        self.length = length
    }

    /// The whole file, sized with `fstat`.
    public static func entireFile(_ file: OwnedFileDescriptor) throws(TransportError) -> FileRegion {
        FileRegion(file: file, offset: 0, length: try file.size())
    }
}

extension ByteStreamTransport {
    /// Default ``ByteStreamTransport/sendFile(_:)``: ``sendFileByReading(_:chunkSize:)`` with
    /// ``FileRegion/defaultChunkSize``.
    public func sendFile(_ region: FileRegion) async throws {
        try await sendFileByReading(region, chunkSize: FileRegion.defaultChunkSize)
    }

    /// Sends `region` by reading at most `chunkSize` bytes at a time with `pread` into one
    /// reusable buffer and sending each chunk with `send(_:endOfStream: false)`.
    ///
    /// Memory stays bounded by `chunkSize` regardless of the region's length, and each `send`
    /// applies the transport's backpressure. Checks for cancellation between chunks.
    ///
    /// - Throws: ``TransportError/fileReadFailed(errno:)`` if `pread` fails,
    ///   ``TransportError/unexpectedEndOfFile`` if the file is shorter than the region, any error
    ///   from `send`, or `CancellationError`.
    public func sendFileByReading(_ region: FileRegion, chunkSize: Int) async throws {
        precondition(chunkSize > 0, "chunkSize must be positive")
        var remaining = region.length
        guard remaining > 0 else { return }
        var offset = region.offset
        let fd = region.file.rawValue
        var buffer = ByteBuffer(capacity: Int(min(Int64(chunkSize), remaining)))
        while remaining > 0 {
            try Task.checkCancellation()
            let want = Int(min(Int64(chunkSize), remaining))
            buffer.clear()
            let result: Int = buffer.withUnsafeMutableWritableBytes(minimumWritableBytes: want) { tail in
                while true {
                    let n = pread(fd, tail.baseAddress, want, off_t(offset))
                    if n >= 0 { return n }
                    if errno != EINTR { return -Int(errno) }
                }
            }
            if result < 0 { throw TransportError.fileReadFailed(errno: Int32(-result)) }
            if result == 0 { throw TransportError.unexpectedEndOfFile }
            buffer.commitWritten(result)
            try await send(buffer, endOfStream: false)
            offset += Int64(result)
            remaining -= Int64(result)
        }
    }
}
