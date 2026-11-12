#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Compression
import HTTPCore

/// How a ``CachedFile`` builds encoded variants (#0091): ``StaticFilesConfiguration/compression``
/// compiled once.
struct Precompression: Sendable {
    let configuration: CompressionConfiguration
    let types: CompressibleTypes
    let codings: [ContentCoding]
    let sidecars: Bool

    init(_ configuration: CompressionConfiguration, sidecars: Bool) {
        self.configuration = configuration
        types = CompressibleTypes(configuration.mimeTypes)
        codings = configuration.availableEncodings.members
        self.sidecars = sidecars
    }
}

/// One file version with its `200` response rendered once: headers (`Content-Type`, strong
/// `ETag`, `Last-Modified`, `Accept-Ranges`, optional `Cache-Control`) and the body, either
/// the bytes in memory (small files) or a ``FileRegion`` over a descriptor kept open (large
/// files). Returning ``response`` copies a struct and retains its buffers: no allocation.
///
/// With ``Precompression``, encoded ``Variant``s are rendered once too (#0091).
final class CachedFile: Sendable {
    enum Content: Sendable {
        case memory(ByteBuffer)
        case file(OwnedFileDescriptor)
    }

    /// An encoded variant: its own `200` and `304` and its suffixed strong `ETag`.
    struct Variant: Sendable {
        let coding: ContentCoding
        let etag: [UInt8]
        let response: HTTPResponse
        let notModified: HTTPResponse
    }

    /// The raw request path this entry answers.
    let key: [UInt8]
    let identity: FileIdentity
    let content: Content
    let response: HTTPResponse
    /// Encoded variants, in ``ContentCoding`` preference order; empty without precompression.
    let variants: [Variant]
    /// The codings in ``variants``.
    let variantCodings: ContentCodingSet
    /// The `304` for this version: `ETag`, `Last-Modified` and `Cache-Control` (the fields a
    /// `200` would carry that RFC 9110 §15.4.5 requires), no body and no `Content-Length`.
    /// The connection adds `Date`.
    let notModified: HTTPResponse
    /// The rendered `ETag` value, quotes included.
    let etag: [UInt8]
    /// The rendered `Last-Modified` value.
    let lastModified: [UInt8]
    /// The modification time in whole seconds, the instant `Last-Modified` names (#0017).
    var lastModifiedSeconds: Int64 { IMFFixdate.clamp(identity.mtimeSeconds) }

    var size: Int64 { identity.size }

    enum OpenError: Error {
        case notFound
        case forbidden
    }

    /// Opens the canonical `path` and renders the response. Identity comes from `fstat` on
    /// the open descriptor, so headers always describe the bytes served.
    init(key: [UInt8], path: [UInt8], contentType: Span<UInt8>, cacheControl: [UInt8]?,
         smallFileLimit: Int, precompression: Precompression? = nil) throws(OpenError) {
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

        // Encoded variants (#0091), and whether the representation varies on Accept-Encoding.
        var variants: [Variant] = []
        var varies = false
        if let precompression, precompression.types.matches(contentType) {
            let base = Self.Rendering(contentType: contentType.withUnsafeBufferPointer { Array($0) }, lastModified: lastModified,
                                      cacheControl: cacheControl, varies: true)
            for coding in precompression.codings {
                guard let body = Self.variantBody(coding, path: path, identity: identity, content: content,
                                                  precompression: precompression, smallFileLimit: smallFileLimit),
                      let tag = etag.withUnsafeBufferPointer({ VariantHeaders.variantETag($0.span, coding) })
                else { continue }
                let variantTag = tag.withUnsafeReadableBytes { Array($0) }
                let rendered = base.render(etag: variantTag, coding: coding, body: body)
                variants.append(Variant(coding: coding, etag: variantTag, response: rendered.response,
                                        notModified: rendered.notModified))
            }
            // A small file that no coding shrinks still varies: it was negotiated here, so
            // the Compression middleware must not try again on every request.
            if case .memory = content, identity.size >= Int64(precompression.configuration.minimumSize) { varies = true }
            if !variants.isEmpty { varies = true }
        }
        self.variants = variants
        variantCodings = ContentCodingSet(variants.map(\.coding))

        let body: HTTPResponseBody
        switch content {
        case .memory(let bytes):
            body = .bytes(bytes)
        case .file(let descriptor):
            body = .file(FileRegion(file: descriptor, offset: 0, length: identity.size))
        }
        let rendered = Self.Rendering(contentType: contentType.withUnsafeBufferPointer { Array($0) }, lastModified: lastModified,
                                      cacheControl: cacheControl, varies: varies)
            .render(etag: etag, coding: nil, body: body)
        response = rendered.response
        notModified = rendered.notModified
    }

    /// The header fields every response of one file version carries.
    struct Rendering {
        let contentType: [UInt8]
        let lastModified: [UInt8]
        let cacheControl: [UInt8]?
        let varies: Bool

        /// The `200` (with `Accept-Ranges` for the unencoded representation, `Content-Encoding`
        /// for a variant) and its `304`.
        func render(etag: [UInt8], coding: ContentCoding?, body: HTTPResponseBody)
            -> (response: HTTPResponse, notModified: HTTPResponse) {
            var headers = HTTPFields(minimumCapacity: 7, arenaCapacity: 192 + contentType.count)
            contentType.withUnsafeBufferPointer { headers.append(.contentType, value: $0.span) }
            etag.withUnsafeBufferPointer { headers.append(.etag, value: $0.span) }
            lastModified.withUnsafeBufferPointer { headers.append(.lastModified, value: $0.span) }
            if let coding {
                headers.append(.contentEncoding, coding.token)
            } else {
                headers.append(.acceptRanges, "bytes")
            }
            if varies { headers.append(.vary, "Accept-Encoding") }
            if let cacheControl {
                cacheControl.withUnsafeBufferPointer { headers.append(.cacheControl, value: $0.span) }
            }
            var validators = HTTPFields(minimumCapacity: 4, arenaCapacity: 160 + (cacheControl?.count ?? 0))
            etag.withUnsafeBufferPointer { validators.append(.etag, value: $0.span) }
            lastModified.withUnsafeBufferPointer { validators.append(.lastModified, value: $0.span) }
            if varies { validators.append(.vary, "Accept-Encoding") }
            if let cacheControl {
                cacheControl.withUnsafeBufferPointer { validators.append(.cacheControl, value: $0.span) }
            }
            return (HTTPResponse(status: .ok, headers: headers, body: body),
                    HTTPResponse(status: .notModified, headers: validators))
        }
    }

    /// The body of `coding`'s variant: the sidecar when there is a usable one, else the
    /// in-memory content compressed once when it is large enough and gets smaller; else `nil`.
    static func variantBody(_ coding: ContentCoding, path: [UInt8], identity: FileIdentity, content: Content,
                            precompression: Precompression, smallFileLimit: Int) -> HTTPResponseBody? {
        if precompression.sidecars, let ext = coding.sidecarExtension,
           let sidecar = openSidecar(path + Array(ext.utf8), notOlderThan: identity) {
            if sidecar.size <= Int64(smallFileLimit) {
                var buffer = ByteBuffer(capacity: Int(sidecar.size))
                let read = readAll(sidecar.file.rawValue, size: Int(sidecar.size), into: &buffer)
                if read == Int(sidecar.size) { return .bytes(buffer) }
            } else {
                return .file(FileRegion(file: sidecar.file, offset: 0, length: sidecar.size))
            }
        }
        guard case .memory(let bytes) = content,
              bytes.readableBytes >= precompression.configuration.minimumSize,
              let encoded = ContentCodec.encode(bytes, coding, level: precompression.configuration.precompressionLevel)
        else { return nil }
        return .bytes(encoded)
    }

    /// Opens `path` if it is a regular file (links are refused) modified no earlier than the
    /// file `identity` describes.
    static func openSidecar(_ path: [UInt8], notOlderThan identity: FileIdentity)
        -> (file: OwnedFileDescriptor, size: Int64)? {
        let fd = PathResolver.withCString(path) { open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW) }
        guard fd >= 0 else { return nil }
        let file = OwnedFileDescriptor(takingOwnershipOf: fd)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let sidecar = FileIdentity(info)
        guard sidecar.mtimeTotalNanoseconds >= identity.mtimeTotalNanoseconds, sidecar.size > 0 else { return nil }
        return (file, sidecar.size)
    }

    /// The variant for `coding`, which is in ``variantCodings``.
    @inline(__always)
    func variant(_ coding: ContentCoding) -> Variant? {
        for variant in variants where variant.coding == coding { return variant }
        return nil
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
