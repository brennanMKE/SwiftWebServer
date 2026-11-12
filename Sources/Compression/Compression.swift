#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
public import HTTPCore

/// Compresses responses for clients that accept it (#0091, legacy `enableCompression`, #0024).
///
/// ```swift
/// let server = Server(listeners: [listener], protocols: [HTTP1()]) {
///     Compression()
///     StaticFiles(root: publicURL)
/// }
/// ```
///
/// After `next` answers, a response is encoded when all of these hold:
/// - its status is `2xx` other than `204` and `206`, or `4xx`/`5xx` (error pages), and the request
///   is not `HEAD`;
/// - it has a body (`.bytes`, `.file` or `.stream`), no `Content-Encoding` yet, and a
///   `Content-Type` in ``CompressionConfiguration/mimeTypes``;
/// - its length is unknown or at least ``CompressionConfiguration/minimumSize``;
/// - its `Vary` does not list `Accept-Encoding` already (the producer negotiated: precompressed
///   static files) and its `Cache-Control` has no `no-transform`;
/// - ``AcceptEncoding`` picks a coding (`br` > `gzip` > `deflate` at equal weight).
///
/// Every response that passes the type and size checks gets `Vary: Accept-Encoding`, encoded
/// or not, so shared caches keep the variants apart. An encoded response loses
/// `Content-Length` and `Accept-Ranges`, gains `Content-Encoding`, and a strong `ETag` gets the
/// coding's suffix (`"abc"` → `"abc-gz"`, ``VariantHeaders``). A `GET` whose `If-None-Match`
/// names that variant tag gets `304` here (the handler only knows its own tag).
///
/// Bodies:
/// - `.bytes` are compressed in one call into a buffer smaller than the input; when the
///   result would not be smaller the body is sent as it was.
/// - `.stream` and `.file` become `.stream(length: nil)`, compressed incrementally in
///   ``CompressionConfiguration/chunkSize`` pieces as the transport accepts them (chunked on
///   HTTP/1.1). Memory per response is the compressor's state plus one piece.
///
/// zlib encoders are pooled (``CompressionConfiguration/pooledEncoders``); Brotli comes from
/// the system `libcompression` at its built-in quality.
public struct Compression: HTTPMiddleware {
    final class Core: Sendable {
        let configuration: CompressionConfiguration
        let available: ContentCodingSet
        let types: CompressibleTypes
        let gzip: EncoderPool
        let deflate: EncoderPool

        init(_ configuration: CompressionConfiguration) {
            precondition((1...9).contains(configuration.level), "compression level must be 1...9")
            precondition(configuration.chunkSize > 0, "chunkSize must be positive")
            self.configuration = configuration
            available = configuration.availableEncodings
            types = CompressibleTypes(configuration.mimeTypes)
            gzip = EncoderPool(coding: .gzip, level: configuration.level, capacity: configuration.pooledEncoders)
            deflate = EncoderPool(coding: .deflate, level: configuration.level, capacity: configuration.pooledEncoders)
        }

        func takeEncoder(_ coding: ContentCoding) -> ContentEncoder? {
            switch coding {
            case .brotli: ContentEncoder(.brotli, level: configuration.level)
            case .gzip: gzip.take()
            case .deflate: deflate.take()
            }
        }

        func recycle(_ encoder: ContentEncoder) {
            switch encoder.coding {
            case .brotli: break
            case .gzip: gzip.recycle(encoder)
            case .deflate: deflate.recycle(encoder)
            }
        }
    }

    let core: Core

    public init(configuration: CompressionConfiguration = CompressionConfiguration()) {
        core = Core(configuration)
    }

    public var configuration: CompressionConfiguration { core.configuration }

    public func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                          next: Next) async throws -> HTTPResponse {
        let response = try await next.handle(request, context: context)
        return encode(response, for: request)
    }

    /// `response` as it should be sent to the client that sent `request` (which must still
    /// be valid). Synchronous: streaming bodies are wrapped, not run.
    public func encode(_ response: HTTPResponse, for request: HTTPRequest) -> HTTPResponse {
        switch response.body {
        case .empty, .tunnel: return response
        case .bytes, .file, .stream: break
        }
        let code = response.status.code
        guard code >= 200, code != 204, code != 206, code != 304 else { return response }
        let headers = response.headers
        let core = core
        guard !headers.contains(.contentEncoding),
              let type = headers.firstValue(for: .contentType),
              headers.withSpan(of: type, { core.types.matches($0) })
        else { return response }
        if let length = response.body.knownLength, length < core.configuration.minimumSize { return response }
        if VariantHeaders.negotiated(headers) { return response }

        var result = response
        VariantHeaders.addVary(&result.headers)
        guard request.method != .head,
              !headers.containsListElement("no-transform", in: .cacheControl),
              let coding = AcceptEncoding.negotiate(request.headers, available: core.available)
        else { return result }

        var etag: ByteBuffer?
        if let view = headers.firstValue(for: .etag) {
            etag = headers.withSpan(of: view) { VariantHeaders.variantETag($0, coding) }
        }
        if let etag, request.method == .get, request.headers.contains(.ifNoneMatch),
           etag.withReadableSpan({ VariantHeaders.ifNoneMatchContains(request.headers, etag: $0) }) {
            return Self.notModified(result.headers, etag: etag)
        }

        switch response.body {
        case .bytes(let bytes):
            guard let encoded = encodeBytes(bytes, coding) else { return result }
            result.body = .bytes(encoded)
        case .file(let region):
            result.body = .stream(length: nil, writer: fileWriter(region, coding))
        case .stream(_, let writer):
            result.body = .stream(length: nil, writer: streamWriter(writer, coding))
        case .empty, .tunnel:
            return result
        }
        result.headers.removeAll(.contentLength)
        result.headers.removeAll(.acceptRanges)
        result.headers.append(.contentEncoding, coding.token)
        if let etag {
            result.headers.removeAll(.etag)
            etag.withReadableSpan { result.headers.append(.etag, value: $0) }
        }
        return result
    }

    /// One-shot compression of an in-memory body; `nil` when it does not get smaller.
    func encodeBytes(_ bytes: ByteBuffer, _ coding: ContentCoding) -> ByteBuffer? {
        switch coding {
        case .brotli:
            return ContentCodec.encodeBrotli(bytes)
        case .gzip, .deflate:
            guard let encoder = core.takeEncoder(coding), case .deflate(let deflate) = encoder.backend else { return nil }
            let encoded = ContentCodec.encode(bytes, with: deflate)
            core.recycle(encoder)
            return encoded
        }
    }

    /// A stream closure that runs `writer` through an encoder.
    func streamWriter(_ writer: @escaping @Sendable (any HTTPBodyWriter) async throws -> Void,
                      _ coding: ContentCoding) -> @Sendable (any HTTPBodyWriter) async throws -> Void {
        let core = core
        return { sink in
            guard let encoder = core.takeEncoder(coding) else { throw CompressionError.encoderUnavailable }
            let compressing = CompressingBodyWriter(sink: sink, encoder: encoder, chunkSize: core.configuration.chunkSize)
            try await writer(compressing)
            try await compressing.finish()
            core.recycle(encoder)
        }
    }

    /// A stream closure that reads `region` in pieces with `pread` and compresses them.
    func fileWriter(_ region: FileRegion, _ coding: ContentCoding) -> @Sendable (any HTTPBodyWriter) async throws -> Void {
        let core = core
        return { sink in
            guard let encoder = core.takeEncoder(coding) else { throw CompressionError.encoderUnavailable }
            let chunkSize = core.configuration.chunkSize
            let compressing = CompressingBodyWriter(sink: sink, encoder: encoder, chunkSize: chunkSize)
            var remaining = region.length
            var offset = region.offset
            let fd = region.file.rawValue
            var buffer = ByteBuffer(capacity: Int(min(Int64(chunkSize), max(remaining, 1))))
            while remaining > 0 {
                try Task.checkCancellation()
                let want = Int(min(Int64(chunkSize), remaining))
                buffer.clear()
                let read: Int = buffer.withUnsafeMutableWritableBytes(minimumWritableBytes: want) { tail in
                    while true {
                        let n = pread(fd, tail.baseAddress, want, off_t(offset))
                        if n >= 0 { return n }
                        if errno != EINTR { return -Int(errno) }
                    }
                }
                if read < 0 { throw TransportError.fileReadFailed(errno: Int32(-read)) }
                if read == 0 { throw TransportError.unexpectedEndOfFile }
                buffer.commitWritten(read)
                try await compressing.write(buffer)
                offset += Int64(read)
                remaining -= Int64(read)
            }
            try await compressing.finish()
            core.recycle(encoder)
        }
    }

    /// `304` for a variant: the validators and caching fields the `200` would carry
    /// (RFC 9110 §15.4.5), with the variant's `ETag`.
    static func notModified(_ headers: HTTPFields, etag: ByteBuffer) -> HTTPResponse {
        var fields = HTTPFields(minimumCapacity: 6, arenaCapacity: 128)
        etag.withReadableSpan { fields.append(.etag, value: $0) }
        for name in [HTTPFieldName.vary, .cacheControl, .expires, .contentLocation, .lastModified] {
            var position = 0
            while let i = headers.fieldIndex.firstIndex(of: name, from: position) {
                fields.append(i, of: headers)
                position = i + 1
            }
        }
        return HTTPResponse(status: .notModified, headers: fields)
    }
}

/// Errors from compressed bodies.
public enum CompressionError: Error, Sendable, Hashable {
    /// The system library could not allocate an encoder.
    case encoderUnavailable
}

/// Compresses what a body writes and forwards it to the connection's writer in
/// ``CompressionConfiguration/chunkSize`` pieces. Every forward awaits the transport, so the
/// producer is slowed to the client's pace (backpressure) and at most one piece is buffered.
///
/// Writes must not overlap (the connection's writers already require it); the state is used
/// by one task at a time, hence `@unchecked Sendable`.
final class CompressingBodyWriter: HTTPBodyWriter, @unchecked Sendable {
    let sink: any HTTPBodyWriter
    let encoder: ContentEncoder
    let chunkSize: Int
    var output: ByteBuffer
    /// Compressed bytes handed to the sink.
    private(set) var written = 0

    init(sink: any HTTPBodyWriter, encoder: ContentEncoder, chunkSize: Int) {
        self.sink = sink
        self.encoder = encoder
        self.chunkSize = chunkSize
        output = ByteBuffer(capacity: chunkSize)
    }

    func write(_ bytes: ByteBuffer) async throws {
        var offset = 0
        let total = bytes.readableBytes
        while offset < total {
            let progress = try step(bytes, from: offset, finish: false)
            offset += progress.consumed
            if output.readableBytes >= chunkSize || progress.consumed == 0 { try await flush() }
        }
    }

    /// Ends the compressed stream and sends what is left.
    func finish() async throws {
        let empty = ByteBuffer()
        while true {
            let progress = try step(empty, from: 0, finish: true)
            if progress.finished { break }
            if output.readableBytes >= chunkSize || progress.produced == 0 { try await flush() }
        }
        if !output.isEmpty { try await flush() }
    }

    func step(_ input: ByteBuffer, from offset: Int, finish: Bool) throws -> CodecProgress {
        let room = max(chunkSize - output.readableBytes, 1)
        let encoder = encoder
        let progress = try input.withUnsafeReadableBytes { source in
            try output.withUnsafeMutableWritableBytes(minimumWritableBytes: room) { tail in
                try encoder.process(UnsafeRawBufferPointer(rebasing: source[offset...]),
                                    into: UnsafeMutableRawBufferPointer(rebasing: tail[..<room]), finish: finish)
            }
        }
        output.commitWritten(progress.produced)
        return progress
    }

    func flush() async throws {
        guard !output.isEmpty else { return }
        written += output.readableBytes
        try await sink.write(output)
        output.clear()
    }
}
