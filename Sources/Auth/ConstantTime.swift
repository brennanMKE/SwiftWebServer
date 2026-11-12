/// Comparisons whose running time does not depend on where (or whether) the inputs differ.
public enum ConstantTime {
    /// True when `a` and `b` hold the same bytes.
    ///
    /// Every byte of the longer input is read, differences are OR-ed together, and nothing
    /// branches on the data, so the time depends only on the lengths. Unequal lengths compare
    /// unequal (secrets compared here, digests and MACs, have public, fixed lengths).
    @inline(never)
    public static func equals<A: Collection<UInt8>, B: Collection<UInt8>>(_ a: A, _ b: B) -> Bool {
        let countA = a.count, countB = b.count
        var difference = UInt(bitPattern: countA ^ countB)
        var ia = a.startIndex, ib = b.startIndex
        let count = Swift.max(countA, countB)
        var i = 0
        while i < count {
            // Past the end of the shorter input, compare against 0 (the length already differs).
            var x: UInt8 = 0, y: UInt8 = 0
            if i < countA { x = a[ia]; ia = a.index(after: ia) }
            if i < countB { y = b[ib]; ib = b.index(after: ib) }
            difference |= UInt(x ^ y)
            i &+= 1
        }
        return difference == 0
    }

    /// True when the `count` bytes at `a` and `b` are equal; constant time in `count`.
    @inline(never)
    public static func equals(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, count: Int) -> Bool {
        var difference: UInt8 = 0
        for i in 0..<count {
            difference |= a.load(fromByteOffset: i, as: UInt8.self) ^ b.load(fromByteOffset: i, as: UInt8.self)
        }
        return difference == 0
    }
}
