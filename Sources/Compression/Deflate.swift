import zlib

/// The framing around a deflate stream (RFC 1951).
public enum DeflateFormat: Sendable, Hashable {
    /// Bare deflate blocks, as permessage-deflate (RFC 7692, #0110) sends them.
    case raw
    /// The zlib format (RFC 1950): the `deflate` content coding.
    case zlib
    /// The gzip format (RFC 1952): the `gzip` content coding. zlib writes the header and the
    /// CRC-32 and size trailer.
    case gzip

    /// zlib's `windowBits` for this framing with a window of `2^bits` bytes.
    func windowBits(_ bits: Int32) -> Int32 {
        switch self {
        case .raw: -bits
        case .zlib: bits
        case .gzip: bits + 16
        }
    }
}

/// How much of the stream a ``DeflateEncoder/process(_:into:flush:)`` call completes.
public enum DeflateFlush: Sendable, Hashable {
    /// Compress what fits; output may lag behind input.
    case none
    /// Emit everything so far, ending on a byte boundary with an empty stored block
    /// (`Z_SYNC_FLUSH`): what permessage-deflate needs at the end of each message.
    case sync
    /// End the stream (and write the gzip or zlib trailer).
    case finish
}

/// Progress of one ``DeflateEncoder/process(_:into:flush:)`` or ``DeflateDecoder/process(_:into:)``
/// step.
public struct CodecProgress: Sendable, Hashable {
    /// Input bytes consumed.
    public var consumed: Int
    /// Output bytes written.
    public var produced: Int
    /// True when the stream is complete (after a `finish` flush, or at the end of the
    /// compressed data when decoding).
    public var finished: Bool
}

/// A deflate encoder from the system `libz` (zero package dependencies).
///
/// The `z_stream` lives at a stable heap address (zlib keeps a pointer back to it). One
/// encoder serves one stream at a time; ``reset()`` starts the next one without freeing
/// zlib's state (about 256 KiB at the default window and memory level), which is why
/// ``Compression`` keeps a small pool of them. Also the primitive for permessage-deflate
/// (#0110): use ``DeflateFormat/raw`` with ``DeflateFlush/sync`` at message ends.
///
/// Not safe for concurrent use; ownership moves between tasks, hence `@unchecked Sendable`.
public final class DeflateEncoder: @unchecked Sendable {
    let stream: UnsafeMutablePointer<z_stream>
    public let format: DeflateFormat
    public let level: Int

    /// - Parameters:
    ///   - level: 1 (fastest) to 9 (smallest).
    ///   - windowBits: 9...15; the LZ77 window is `2^windowBits` bytes.
    ///   - memoryLevel: 1...9; zlib's internal state size.
    /// - Returns: `nil` when zlib cannot allocate its state or rejects the arguments.
    public init?(format: DeflateFormat, level: Int = 6, windowBits: Int = 15, memoryLevel: Int = 8) {
        precondition((1...9).contains(level), "deflate level must be 1...9")
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        self.format = format
        self.level = level
        // windowBits 8 is not valid for raw deflate in zlib; 9 is the smallest.
        let bits = format.windowBits(Int32(max(9, min(15, windowBits))))
        let status = deflateInit2_(stream, Int32(level), Z_DEFLATED, bits, Int32(memoryLevel),
                                   Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            stream.deallocate()
            return nil
        }
    }

    deinit {
        deflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    /// Starts a new stream with the same settings, keeping the allocated state.
    public func reset() {
        deflateReset(stream)
    }

    /// Compresses from `input` into `output` until the input is consumed and, for `sync` and
    /// `finish`, the flush is complete, or `output` is full. Call again with the unconsumed
    /// input (and the same flush) after making room.
    public func process(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer,
                        flush: DeflateFlush) -> CodecProgress {
        let z = stream
        z.pointee.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: UInt8.self))
        z.pointee.avail_in = UInt32(clamping: input.count)
        z.pointee.next_out = output.baseAddress?.assumingMemoryBound(to: UInt8.self)
        z.pointee.avail_out = UInt32(clamping: output.count)
        let inBefore = z.pointee.avail_in
        let outBefore = z.pointee.avail_out
        let mode: Int32 = switch flush {
        case .none: Z_NO_FLUSH
        case .sync: Z_SYNC_FLUSH
        case .finish: Z_FINISH
        }
        var finished = false
        if outBefore > 0 {
            let status = deflate(z, mode)
            finished = status == Z_STREAM_END
        }
        let consumed = Int(inBefore - z.pointee.avail_in)
        let produced = Int(outBefore - z.pointee.avail_out)
        z.pointee.next_in = nil
        z.pointee.next_out = nil
        return CodecProgress(consumed: consumed, produced: produced, finished: finished)
    }

    /// Compresses all of `input` as one complete stream into `output`, which has room for at
    /// most `limit` bytes. Returns the compressed size, or `nil` when it would not fit (the
    /// encoder is reset either way).
    public func compress(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) -> Int? {
        reset()
        defer { reset() }
        let progress = process(input, into: output, flush: .finish)
        return progress.finished ? progress.produced : nil
    }

    /// An upper bound on the compressed size of `count` input bytes (zlib's `deflateBound`).
    public func bound(_ count: Int) -> Int {
        Int(deflateBound(stream, UInt(count)))
    }
}

/// A deflate decoder from the system `libz`, for tests, request bodies and permessage-deflate.
public final class DeflateDecoder: @unchecked Sendable {
    let stream: UnsafeMutablePointer<z_stream>
    public let format: DeflateFormat

    /// - Returns: `nil` when zlib cannot allocate its state.
    public init?(format: DeflateFormat, windowBits: Int = 15) {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        self.format = format
        let bits = format.windowBits(Int32(max(8, min(15, windowBits))))
        guard inflateInit2_(stream, bits, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            stream.deallocate()
            return nil
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    public func reset() {
        inflateReset(stream)
    }

    /// Error from ``process(_:into:)``: the input is not valid compressed data.
    public struct DataError: Error, Sendable {}

    /// Decompresses from `input` into `output` until the input is consumed, `output` is full or
    /// the stream ends.
    public func process(_ input: UnsafeRawBufferPointer,
                        into output: UnsafeMutableRawBufferPointer) throws(DataError) -> CodecProgress {
        let z = stream
        z.pointee.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: UInt8.self))
        z.pointee.avail_in = UInt32(clamping: input.count)
        z.pointee.next_out = output.baseAddress?.assumingMemoryBound(to: UInt8.self)
        z.pointee.avail_out = UInt32(clamping: output.count)
        let inBefore = z.pointee.avail_in
        let outBefore = z.pointee.avail_out
        let status = inflate(z, Z_NO_FLUSH)
        let consumed = Int(inBefore - z.pointee.avail_in)
        let produced = Int(outBefore - z.pointee.avail_out)
        z.pointee.next_in = nil
        z.pointee.next_out = nil
        switch status {
        case Z_OK, Z_BUF_ERROR: return CodecProgress(consumed: consumed, produced: produced, finished: false)
        case Z_STREAM_END: return CodecProgress(consumed: consumed, produced: produced, finished: true)
        default: throw DataError()
        }
    }
}
