public import HTTPCore
import Synchronization

/// One streaming encoder for a ``ContentCoding``: zlib for `gzip` and `deflate`,
/// `libcompression` for `br`.
///
/// Not safe for concurrent use; ownership moves between tasks, hence `@unchecked Sendable`.
public final class ContentEncoder: @unchecked Sendable {
    enum Backend {
        case deflate(DeflateEncoder)
        case brotli(BrotliStream)
    }

    let backend: Backend
    public let coding: ContentCoding

    /// A fresh encoder, or `nil` when the system library cannot provide one.
    public init?(_ coding: ContentCoding, level: Int) {
        self.coding = coding
        switch coding {
        case .brotli:
            guard let stream = BrotliStream(encoder: true) else { return nil }
            backend = .brotli(stream)
        case .gzip, .deflate:
            guard let encoder = DeflateEncoder(format: coding == .gzip ? .gzip : .zlib, level: level) else { return nil }
            backend = .deflate(encoder)
        }
    }

    /// Compresses from `input` into `output`; with `finish`, ends the stream once the input
    /// is consumed. Call again (with the unconsumed input) while ``CodecProgress/finished`` is
    /// false and the output was filled.
    public func process(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer,
                        finish: Bool) throws -> CodecProgress {
        switch backend {
        case .deflate(let encoder):
            return encoder.process(input, into: output, flush: finish ? .finish : .none)
        case .brotli(let stream):
            return try stream.process(input, into: output, finish: finish)
        }
    }

    /// Compresses the readable bytes of `input` into `output`, growing `output` as needed
    /// (cold paths: precompression and tests).
    public func compressAll(_ input: ByteBuffer, into output: inout ByteBuffer) throws {
        var offset = 0
        let total = input.readableBytes
        while true {
            let progress: CodecProgress = try input.withUnsafeReadableBytes { source in
                let rest = UnsafeRawBufferPointer(rebasing: source[offset...])
                return try output.withUnsafeMutableWritableBytes(minimumWritableBytes: max(4096, total / 4)) { tail in
                    let progress = try process(rest, into: tail, finish: true)
                    return progress
                }
            }
            output.commitWritten(progress.produced)
            offset += progress.consumed
            if progress.finished { return }
        }
    }
}

/// One-shot encoding and decoding of whole bodies (#0091). Decoding is for tests and tools;
/// the server never decodes responses.
public enum ContentCodec {
    /// `bytes` encoded with `coding` as one complete stream, or `nil` when the result is not
    /// smaller than the input or the coding is unavailable.
    public static func encode(_ bytes: ByteBuffer, _ coding: ContentCoding, level: Int = 6) -> ByteBuffer? {
        guard bytes.readableBytes > 0 else { return nil }
        switch coding {
        case .brotli:
            return encodeBrotli(bytes)
        case .gzip, .deflate:
            guard let encoder = DeflateEncoder(format: coding == .gzip ? .gzip : .zlib, level: level) else { return nil }
            return encode(bytes, with: encoder)
        }
    }

    /// One complete stream from a (reset) zlib encoder; `nil` when it is not smaller.
    static func encode(_ bytes: ByteBuffer, with encoder: DeflateEncoder) -> ByteBuffer? {
        let limit = bytes.readableBytes - 1
        guard limit > 0 else { return nil }
        var output = ByteBuffer(capacity: limit)
        let size: Int? = bytes.withUnsafeReadableBytes { source in
            output.withUnsafeMutableWritableBytes { tail in
                encoder.compress(source, into: UnsafeMutableRawBufferPointer(rebasing: tail[..<limit]))
            }
        }
        guard let size else { return nil }
        output.commitWritten(size)
        return output
    }

    static func encodeBrotli(_ bytes: ByteBuffer) -> ByteBuffer? {
        let limit = bytes.readableBytes - 1
        guard limit > 0 else { return nil }
        var output = ByteBuffer(capacity: limit)
        let size: Int? = bytes.withUnsafeReadableBytes { source in
            output.withUnsafeMutableWritableBytes { tail in
                BrotliStream.compress(source, into: UnsafeMutableRawBufferPointer(rebasing: tail[..<limit]))
            }
        }
        guard let size else { return nil }
        output.commitWritten(size)
        return output
    }

    /// `bytes` decoded from `coding`, or `nil` when they are not one valid stream or the
    /// result exceeds `limit` bytes.
    public static func decode(_ bytes: [UInt8], _ coding: ContentCoding, limit: Int = 1 << 30) -> [UInt8]? {
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var offset = 0
        switch coding {
        case .brotli:
            guard let stream = BrotliStream(encoder: false) else { return nil }
            while true {
                let progress: CodecProgress? = bytes.withUnsafeBytes { source in
                    chunk.withUnsafeMutableBytes { out in
                        try? stream.process(UnsafeRawBufferPointer(rebasing: source[offset...]), into: out,
                                            finish: true)
                    }
                }
                guard let progress else { return nil }
                offset += progress.consumed
                result.append(contentsOf: chunk[..<progress.produced])
                if result.count > limit { return nil }
                if progress.finished { return offset == bytes.count ? result : nil }
                if progress.consumed == 0 && progress.produced == 0 { return nil }
            }
        case .gzip, .deflate:
            guard let decoder = DeflateDecoder(format: coding == .gzip ? .gzip : .zlib) else { return nil }
            while true {
                let progress: CodecProgress? = bytes.withUnsafeBytes { source in
                    chunk.withUnsafeMutableBytes { out in
                        try? decoder.process(UnsafeRawBufferPointer(rebasing: source[offset...]), into: out)
                    }
                }
                guard let progress else { return nil }
                offset += progress.consumed
                result.append(contentsOf: chunk[..<progress.produced])
                if result.count > limit { return nil }
                if progress.finished { return offset == bytes.count ? result : nil }
                if progress.consumed == 0 && progress.produced == 0 { return nil }
            }
        }
    }
}

/// Idle zlib encoders for one coding and level, reused across responses (each saves a
/// ~256 KiB allocation and zlib's initialization). Bounded: extras are freed.
final class EncoderPool: Sendable {
    let coding: ContentCoding
    let level: Int
    let capacity: Int
    let idle = Mutex<[ContentEncoder]>([])

    init(coding: ContentCoding, level: Int, capacity: Int) {
        precondition(coding != .brotli, "Brotli streams are not pooled")
        self.coding = coding
        self.level = level
        self.capacity = capacity
    }

    /// A reset encoder, from the pool when one is idle.
    func take() -> ContentEncoder? {
        if let encoder = idle.withLock({ $0.popLast() }) { return encoder }
        return ContentEncoder(coding, level: level)
    }

    /// Returns `encoder` (reset) to the pool, or frees it when the pool is full.
    func recycle(_ encoder: ContentEncoder) {
        guard case .deflate(let deflate) = encoder.backend else { return }
        deflate.reset()
        idle.withLock { idle in
            if idle.count < capacity { idle.append(encoder) }
        }
    }

    var idleCount: Int { idle.withLock { $0.count } }
}
