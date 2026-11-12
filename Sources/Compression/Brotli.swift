#if canImport(Darwin)
import Darwin
#endif

/// Apple's `libcompression`, loaded at run time for Brotli.
///
/// This target is named `Compression`, the same as the SDK's Clang module for
/// `compression.h`, so `import Compression` here would import this module itself. The few
/// functions needed are resolved once with `dlsym` from the system library instead (always
/// present in the shared cache on macOS 12+); declarations mirror `compression.h`.
/// `COMPRESSION_BROTLI` is Brotli at quality 2 (the only encoder level Apple ships); its
/// decoder reads any quality, which is what precompressed `.br` sidecars need.
struct BrotliLibrary: @unchecked Sendable {
    /// `compression_stream` from `compression.h`.
    struct Stream {
        var dst: UnsafeMutablePointer<UInt8>?
        var dstSize: Int
        var src: UnsafePointer<UInt8>?
        var srcSize: Int
        var state: UnsafeMutableRawPointer?
    }

    typealias Buffer = @convention(c) (UnsafeMutablePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int,
                                      UnsafeMutableRawPointer?, Int32) -> Int
    typealias StreamInit = @convention(c) (UnsafeMutableRawPointer, Int32, Int32) -> Int32
    typealias StreamProcess = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    typealias StreamDestroy = @convention(c) (UnsafeMutableRawPointer) -> Int32

    static let algorithm: Int32 = 0xB02          // COMPRESSION_BROTLI
    static let encode: Int32 = 0                 // COMPRESSION_STREAM_ENCODE
    static let decode: Int32 = 1                 // COMPRESSION_STREAM_DECODE
    static let finalize: Int32 = 1               // COMPRESSION_STREAM_FINALIZE
    static let statusOK: Int32 = 0               // COMPRESSION_STATUS_OK
    static let statusEnd: Int32 = 1              // COMPRESSION_STATUS_END

    let encodeBuffer: Buffer
    let decodeBuffer: Buffer
    let streamInit: StreamInit
    let streamProcess: StreamProcess
    let streamDestroy: StreamDestroy

    /// The library, or `nil` where it (or Brotli) is unavailable.
    static let shared: BrotliLibrary? = {
        #if canImport(Darwin)
        guard let handle = dlopen("/usr/lib/libcompression.dylib", RTLD_NOW | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, as: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let encodeBuffer = symbol("compression_encode_buffer", as: Buffer.self),
              let decodeBuffer = symbol("compression_decode_buffer", as: Buffer.self),
              let streamInit = symbol("compression_stream_init", as: StreamInit.self),
              let streamProcess = symbol("compression_stream_process", as: StreamProcess.self),
              let streamDestroy = symbol("compression_stream_destroy", as: StreamDestroy.self)
        else { return nil }
        let library = BrotliLibrary(encodeBuffer: encodeBuffer, decodeBuffer: decodeBuffer, streamInit: streamInit,
                                    streamProcess: streamProcess, streamDestroy: streamDestroy)
        // Brotli arrived in macOS 12; check the stream API accepts it.
        let probe = UnsafeMutablePointer<Stream>.allocate(capacity: 1)
        defer { probe.deallocate() }
        probe.initialize(to: Stream(dst: nil, dstSize: 0, src: nil, srcSize: 0, state: nil))
        guard streamInit(probe, encode, algorithm) == statusOK else { return nil }
        _ = streamDestroy(probe)
        return library
        #else
        return nil
        #endif
    }()
}

/// A streaming Brotli encoder or decoder over `libcompression` (``BrotliLibrary``).
///
/// Not safe for concurrent use; ownership moves between tasks, hence `@unchecked Sendable`.
public final class BrotliStream: @unchecked Sendable {
    let library: BrotliLibrary
    let stream: UnsafeMutablePointer<BrotliLibrary.Stream>
    public let isEncoder: Bool
    var finished = false

    /// Error from ``process(_:into:finish:)``: invalid compressed data, or a library failure.
    public struct DataError: Error, Sendable {}

    /// - Returns: `nil` when Brotli is not available on this system.
    public init?(encoder: Bool) {
        guard let library = BrotliLibrary.shared else { return nil }
        self.library = library
        isEncoder = encoder
        stream = .allocate(capacity: 1)
        stream.initialize(to: BrotliLibrary.Stream(dst: nil, dstSize: 0, src: nil, srcSize: 0, state: nil))
        guard library.streamInit(stream, encoder ? BrotliLibrary.encode : BrotliLibrary.decode,
                                 BrotliLibrary.algorithm) == BrotliLibrary.statusOK else {
            stream.deallocate()
            return nil
        }
    }

    deinit {
        _ = library.streamDestroy(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    /// Encodes or decodes from `input` into `output`. For an encoder, `finish` ends the
    /// stream once all input is consumed; call again with the same flag until ``CodecProgress/finished``.
    public func process(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer,
                        finish: Bool) throws(DataError) -> CodecProgress {
        if finished || output.count == 0 { return CodecProgress(consumed: 0, produced: 0, finished: finished) }
        let s = stream
        s.pointee.src = input.baseAddress?.assumingMemoryBound(to: UInt8.self)
        s.pointee.srcSize = input.count
        s.pointee.dst = output.baseAddress?.assumingMemoryBound(to: UInt8.self)
        s.pointee.dstSize = output.count
        let status = library.streamProcess(s, finish ? BrotliLibrary.finalize : 0)
        let consumed = input.count - s.pointee.srcSize
        let produced = output.count - s.pointee.dstSize
        s.pointee.src = nil
        s.pointee.dst = nil
        switch status {
        case BrotliLibrary.statusOK:
            return CodecProgress(consumed: consumed, produced: produced, finished: false)
        case BrotliLibrary.statusEnd:
            finished = true
            return CodecProgress(consumed: consumed, produced: produced, finished: true)
        default:
            throw DataError()
        }
    }

    /// Compresses `input` in one call into `output`; returns the size, or `nil` when it does
    /// not fit (or Brotli is unavailable). Uses the buffer API: no stream state is kept.
    public static func compress(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) -> Int? {
        guard let library = BrotliLibrary.shared, input.count > 0 else { return nil }
        let size = library.encodeBuffer(output.baseAddress?.assumingMemoryBound(to: UInt8.self), output.count,
                                        input.baseAddress?.assumingMemoryBound(to: UInt8.self), input.count,
                                        nil, BrotliLibrary.algorithm)
        return size > 0 ? size : nil
    }
}
