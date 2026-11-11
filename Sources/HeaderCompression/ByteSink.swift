/// A destination that encoders and decoders append bytes to.
///
/// `[UInt8]` conforms out of the box. `HTTPCore.ByteBuffer` (or any other owned byte storage)
/// can conform later without this target depending on it.
public protocol ByteSink {
    /// Appends one byte.
    mutating func append(_ byte: UInt8)

    /// Hints that `count` more bytes are about to be appended, so the appends do not
    /// reallocate. Conformers may ignore it.
    mutating func reserveAdditionalCapacity(_ count: Int)
}

extension Array: ByteSink where Element == UInt8 {
    @inlinable
    public mutating func reserveAdditionalCapacity(_ additional: Int) {
        let needed = count + additional
        if needed > capacity {
            // Keep geometric growth: `reserveCapacity` alone allocates exactly what is asked,
            // which turns repeated small reservations into quadratic copying.
            reserveCapacity(Swift.max(needed, capacity &* 2))
        }
    }
}
