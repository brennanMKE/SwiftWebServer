/// Fixed-capacity byte storage behind the HPACK tables (docs/ROADMAP.md §7: "HPACK ring over one
/// byte arena").
///
/// ## Unsafe code
///
/// All pointer manipulation in the `HPACK` target lives in this file: the arena itself and the
/// two ``UnsafeBridge`` helpers that hand `HeaderCompression` (whose API takes
/// `UnsafeRawBufferPointer`) a view of a `Span`, and give a `Span` over a scratch `[UInt8]`
/// (`Array.span` needs macOS 26). Everything else reads bytes through bounds-checked `Span`s.
///
/// The arena never grows: capacity is fixed at creation, so nothing resizes mid-request.
/// It is a reference type; owners (``HPACKDynamicTable``) copy it before mutating when it is
/// shared, which keeps their value semantics and makes `@unchecked Sendable` sound.
final class ByteArena: @unchecked Sendable {
    /// Number of bytes the arena holds.
    let capacity: Int
    private let bytes: UnsafeMutablePointer<UInt8>

    init(capacity: Int) {
        precondition(capacity >= 0, "ByteArena capacity must not be negative")
        self.capacity = capacity
        bytes = .allocate(capacity: Swift.max(capacity, 1))
        bytes.initialize(repeating: 0, count: Swift.max(capacity, 1))
    }

    deinit {
        bytes.deallocate()
    }

    /// A copy with the same capacity and contents (copy-on-write support).
    func copy() -> ByteArena {
        let new = ByteArena(capacity: capacity)
        new.bytes.update(from: bytes, count: capacity)
        return new
    }

    @inline(__always)
    private func check(_ offset: Int, _ count: Int) {
        precondition(offset >= 0 && count >= 0 && offset <= capacity &- count,
                     "ByteArena range \(offset)+\(count) outside 0..<\(capacity)")
    }

    /// Copies `source` to `offset`.
    func write(_ source: Span<UInt8>, at offset: Int) {
        check(offset, source.count)
        let destination = bytes + offset
        source.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            destination.update(from: base, count: buffer.count)
        }
    }

    /// Copies the UTF-8 bytes of `literal` to `offset`.
    func write(_ literal: StaticString, at offset: Int) {
        check(offset, literal.utf8CodeUnitCount)
        let destination = bytes + offset
        literal.withUTF8Buffer { buffer in
            guard let base = buffer.baseAddress else { return }
            destination.update(from: base, count: buffer.count)
        }
    }

    /// Copies `count` bytes from `source` to `destination`; the ranges may overlap.
    func move(from source: Int, to destination: Int, count: Int) {
        check(source, count)
        check(destination, count)
        guard count > 0, source != destination else { return }
        // `update(from:count:)` is memmove: it handles overlapping ranges in either direction.
        (bytes + destination).update(from: bytes + source, count: count)
    }

    /// Calls `body` with a bounds-checked span of `count` bytes at `offset`.
    @inline(__always)
    func withSpan<R, E: Error>(
        offset: Int, count: Int, _ body: (Span<UInt8>) throws(E) -> R
    ) throws(E) -> R {
        check(offset, count)
        return try body(UnsafeBufferPointer(start: bytes + offset, count: count).span)
    }
}

/// Bridges between `Span` and the pointer-based APIs this target must call.
enum UnsafeBridge {
    /// Calls `body` with the raw bytes of `span` (for `HeaderCompression` calls).
    @inline(__always)
    static func withRawBytes<R, E: Error>(
        _ span: Span<UInt8>, _ body: (UnsafeRawBufferPointer) throws(E) -> R
    ) throws(E) -> R {
        try span.withUnsafeBytes(body)
    }

    /// Calls `body` with a span of `array[range]`.
    @inline(__always)
    static func withSpan<R, E: Error>(
        of array: [UInt8], _ range: Range<Int>, _ body: (Span<UInt8>) throws(E) -> R
    ) throws(E) -> R {
        precondition(range.lowerBound >= 0 && range.upperBound <= array.count,
                     "scratch range \(range) outside 0..<\(array.count)")
        // `withUnsafeBufferPointer` is rethrows-only, so carry a typed error out by hand.
        var failure: E?
        let result: R? = array.withUnsafeBufferPointer { buffer -> R? in
            let slice = UnsafeBufferPointer(rebasing: buffer[range])
            do throws(E) {
                return try body(slice.span)
            } catch {
                failure = error
                return nil
            }
        }
        if let failure { throw failure }
        return result!
    }
}
