#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import HTTPCore

/// One file version with its `200` response rendered once: headers (`Content-Type`, strong
/// `ETag`, `Last-Modified`, `Accept-Ranges`, optional `Cache-Control`) and the body, either
/// the bytes in memory (small files) or a ``FileRegion`` over a descriptor kept open (large
/// files). Returning ``response`` copies a struct and retains its buffers: no allocation.
final class CachedFile: Sendable {
    enum Content: Sendable {
        case memory(ByteBuffer)
        case file(OwnedFileDescriptor)
    }

    /// The raw request path this entry answers.
    let key: [UInt8]
    let identity: FileIdentity
    let content: Content
    let response: HTTPResponse
    /// The rendered `ETag` value, quotes included, for `If-Range`.
    let etag: [UInt8]
    /// The rendered `Last-Modified` value, for `If-Range`.
    let lastModified: [UInt8]

    var size: Int64 { identity.size }

    enum OpenError: Error {
        case notFound
        case forbidden
    }

    /// Opens the canonical `path` and renders the response. Identity comes from `fstat` on
    /// the open descriptor, so headers always describe the bytes served.
    init(key: [UInt8], path: [UInt8], contentType: Span<UInt8>, cacheControl: [UInt8]?,
         smallFileLimit: Int) throws(OpenError) {
        // O_NONBLOCK: a FIFO swapped in after the stat must not block the open.
        let fd = PathResolver.withCString(path) { open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) }
        guard fd >= 0 else { throw errno == EACCES ? .forbidden : .notFound }
        let file = OwnedFileDescriptor(takingOwnershipOf: fd)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .notFound }
        var identity = FileIdentity(info)

        if identity.size <= Int64(smallFileLimit) {
            var buffer = ByteBuffer(capacity: Int(identity.size))
            let read = Self.readAll(fd, size: Int(identity.size), into: &buffer)
            guard read >= 0 else { throw .notFound }
            identity.size = Int64(read)          // a file that shrank between fstat and read
            content = .memory(buffer)
        } else {
            content = .file(file)
        }
        self.key = key
        self.identity = identity

        // ETag: "<size-hex>-<mtime-ns-hex>-<inode-hex>", strong, from metadata only (#0025).
        var tag = ByteBuffer(capacity: 64)
        tag.append(UInt8(ascii: "\""))
        tag.append(hex: UInt64(identity.size))
        tag.append(UInt8(ascii: "-"))
        tag.append(hex: identity.mtimeTotalNanoseconds)
        tag.append(UInt8(ascii: "-"))
        tag.append(hex: identity.inode)
        tag.append(UInt8(ascii: "\""))
        etag = tag.withUnsafeReadableBytes { Array($0) }
        // Last-Modified: mtime truncated to whole seconds.
        var date = ByteBuffer(capacity: IMFFixdate.length)
        IMFFixdate.append(secondsSinceEpoch: identity.mtimeSeconds, to: &date)
        lastModified = date.withUnsafeReadableBytes { Array($0) }

        var headers = HTTPFields(minimumCapacity: 6, arenaCapacity: 160 + contentType.count)
        headers.append(.contentType, value: contentType)
        etag.withUnsafeBufferPointer { headers.append(.etag, value: $0.span) }
        lastModified.withUnsafeBufferPointer { headers.append(.lastModified, value: $0.span) }
        headers.append(.acceptRanges, "bytes")
        if let cacheControl {
            cacheControl.withUnsafeBufferPointer { headers.append(.cacheControl, value: $0.span) }
        }
        switch content {
        case .memory(let bytes):
            response = HTTPResponse(status: .ok, headers: headers, body: .bytes(bytes))
        case .file(let descriptor):
            response = HTTPResponse(status: .ok, headers: headers,
                                    body: .file(FileRegion(file: descriptor, offset: 0, length: identity.size)))
        }
    }

    /// `206` for `offset ..< offset + length`, which lies inside the file. Allocates (a header
    /// copy, and for small files the slice); ranges are not the hot path.
    func partial(offset: Int64, length: Int64) -> HTTPResponse {
        var headers = response.headers
        var value = ByteBuffer(capacity: 64)
        value.append("bytes ")
        value.append(decimal: offset)
        value.append(UInt8(ascii: "-"))
        value.append(decimal: offset + length - 1)
        value.append(UInt8(ascii: "/"))
        value.append(decimal: size)
        value.withReadableSpan { headers.append(.contentRange, value: $0) }
        switch content {
        case .memory(let bytes):
            var slice = ByteBuffer(capacity: Int(length))
            slice.append(ByteView(offset: bytes.readerIndex + Int(offset), length: Int(length)), from: bytes)
            return HTTPResponse(status: .partialContent, headers: headers, body: .bytes(slice))
        case .file(let descriptor):
            return HTTPResponse(status: .partialContent, headers: headers,
                                body: .file(FileRegion(file: descriptor, offset: offset, length: length)))
        }
    }

    /// `416` with `Content-Range: bytes */<size>`.
    func unsatisfiable() -> HTTPResponse {
        var headers = HTTPFields(minimumCapacity: 1, arenaCapacity: 32)
        var value = ByteBuffer(capacity: 32)
        value.append("bytes */")
        value.append(decimal: size)
        value.withReadableSpan { headers.append(.contentRange, value: $0) }
        return HTTPResponse(status: .rangeNotSatisfiable, headers: headers)
    }

    /// True when an `If-Range` value names this version: the exact strong ETag, or the exact
    /// `Last-Modified` date (RFC 9110 §13.1.5).
    func matchesIfRange(_ value: Span<UInt8>) -> Bool {
        func equals(_ bytes: [UInt8]) -> Bool {
            guard value.count == bytes.count else { return false }
            for i in 0..<bytes.count where value[i] != bytes[i] { return false }
            return true
        }
        return equals(etag) || equals(lastModified)
    }

    /// Reads up to `size` bytes from the start of `fd` with `pread`; returns the count read,
    /// or -1 on error.
    static func readAll(_ fd: Int32, size: Int, into buffer: inout ByteBuffer) -> Int {
        guard size > 0 else { return 0 }
        var total = 0
        while total < size {
            let n: Int = buffer.withUnsafeMutableWritableBytes(minimumWritableBytes: size - total) { tail in
                while true {
                    let r = pread(fd, tail.baseAddress, size - total, off_t(total))
                    if r >= 0 || errno != EINTR { return r }
                }
            }
            if n < 0 { return -1 }
            if n == 0 { break }
            buffer.commitWritten(n)
            total += n
        }
        return total
    }

    /// True when `key` (a raw request path) is this entry's key.
    func hasKey(_ raw: Span<UInt8>) -> Bool {
        guard raw.count == key.count else { return false }
        for i in 0..<key.count where raw[i] != key[i] { return false }
        return true
    }
}
