public import struct Foundation.Data

/// `Data` conversion for transport edges only (for example `NWConnection` receive and send).
/// Never use `Data` on the request path.
extension ByteBuffer {
    /// Creates a buffer holding a copy of `data`.
    public init(_ data: Data) {
        self.init(capacity: data.count)
        append(contentsOf: data)
    }

    /// Appends a copy of `data`.
    public mutating func append(contentsOf data: Data) {
        data.withUnsafeBytes { raw in
            appendBytes(raw.assumingMemoryBound(to: UInt8.self))
        }
    }

    /// A copy of the readable bytes as `Data`.
    public func makeData() -> Data {
        withUnsafeReadableBytes { Data($0) }
    }
}
