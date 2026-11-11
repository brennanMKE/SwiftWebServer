/// A cheap `(offset, length)` range of bytes in a ``ByteBuffer``.
///
/// Header values, path and query are represented as views into the connection's receive
/// buffer instead of copies (docs/ROADMAP.md §7, "cheapest form; convert at edges"). A view
/// holds no reference to the buffer; pass the buffer it came from to read it. Offsets are
/// absolute buffer indices, so a view stays valid while the buffer grows, and becomes invalid
/// after ``ByteBuffer/discardReadBytes()`` returns `true` or after
/// ``ByteBuffer/clear(keepingCapacity:)``.
public struct ByteView: Sendable, Hashable {
    /// Absolute index of the first byte in the buffer.
    public var offset: Int
    /// Number of bytes.
    public var length: Int

    @inlinable
    public init(offset: Int, length: Int) {
        precondition(offset >= 0 && length >= 0, "ByteView offset and length must not be negative")
        self.offset = offset
        self.length = length
    }

    /// An empty view.
    public static let empty = ByteView(offset: 0, length: 0)

    /// Absolute index one past the last byte.
    @inlinable public var endOffset: Int { offset + length }

    /// True when the view has no bytes.
    @inlinable public var isEmpty: Bool { length == 0 }

    /// The sub-range `range` of this view, with bounds relative to the view's start.
    @inlinable
    public func subview(_ range: Range<Int>) -> ByteView {
        precondition(range.lowerBound >= 0 && range.upperBound <= length,
                     "subview \(range) outside 0..<\(length)")
        return ByteView(offset: offset + range.lowerBound, length: range.count)
    }

    /// Decodes the bytes as UTF-8 (invalid sequences become U+FFFD). Allocates; use off the hot path.
    @inlinable
    public func string(in buffer: ByteBuffer) -> String {
        buffer.withSpan(of: self) { ASCII.string(from: $0) }
    }

    /// Case-insensitive ASCII comparison with a static byte string, such as a header name.
    @inlinable
    public func equalsCaseInsensitive(_ literal: StaticString, in buffer: ByteBuffer) -> Bool {
        guard length == literal.utf8CodeUnitCount else { return false }
        return buffer.withSpan(of: self) { ASCII.equalsCaseInsensitive($0, literal) }
    }

    /// Exact byte comparison with a static byte string.
    @inlinable
    public func equals(_ literal: StaticString, in buffer: ByteBuffer) -> Bool {
        guard length == literal.utf8CodeUnitCount else { return false }
        return buffer.withSpan(of: self) { ASCII.equals($0, literal) }
    }

    /// The bytes parsed as an unsigned decimal integer, or `nil` (see ``ASCII/parseDecimal(_:)``).
    @inlinable
    public func decimalValue(in buffer: ByteBuffer) -> UInt64? {
        buffer.withSpan(of: self) { ASCII.parseDecimal($0) }
    }

    /// The bytes parsed as an unsigned hexadecimal integer, or `nil` (see ``ASCII/parseHex(_:)``).
    @inlinable
    public func hexValue(in buffer: ByteBuffer) -> UInt64? {
        buffer.withSpan(of: self) { ASCII.parseHex($0) }
    }

    /// FNV-1a hash of the lowercased bytes (see ``ASCII/fnv1aLowercased(_:)-(Span<UInt8>)``).
    @inlinable
    public func fnv1aLowercased(in buffer: ByteBuffer) -> UInt32 {
        buffer.withSpan(of: self) { ASCII.fnv1aLowercased($0) }
    }
}
