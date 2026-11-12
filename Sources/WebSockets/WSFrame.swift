public import HTTPCore

/// A frame opcode (RFC 6455 §5.2). Reserved opcodes (3–7, 11–15) are rejected by the parser,
/// so a parsed header only ever carries one of these.
public enum WSOpcode: UInt8, Sendable, Hashable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA

    /// Close, ping and pong (opcodes with the high bit set).
    @inlinable public var isControl: Bool { rawValue & 0x8 != 0 }
}

/// The fixed part of a frame (RFC 6455 §5.2), as the parser read it.
public struct WSFrameHeader: Sendable, Hashable {
    /// The FIN bit: this frame ends its message.
    public var fin: Bool
    /// RSV1–RSV3 in bits 6–4 (`0x40`, `0x20`, `0x10`), as on the wire.
    public var reservedBits: UInt8
    public var opcode: WSOpcode
    /// The masking key in wire order (first key byte in the high byte), or `nil` when the
    /// frame was not masked.
    public var maskKey: UInt32?
    public var payloadLength: UInt64

    public init(fin: Bool, reservedBits: UInt8 = 0, opcode: WSOpcode, maskKey: UInt32? = nil, payloadLength: UInt64) {
        self.fin = fin
        self.reservedBits = reservedBits
        self.opcode = opcode
        self.maskKey = maskKey
        self.payloadLength = payloadLength
    }

    /// Largest header: 2 bytes, an 8-byte length and a 4-byte mask.
    public static let maximumSize = 14
}

/// Serializes frames (RFC 6455 §5.2). A server sends unmasked frames; the masked form exists
/// for client roles and for tests that play the client.
public enum WSFrameWriter {
    /// Appends a frame header for `payloadLength` bytes, using the shortest length encoding.
    @inlinable
    public static func appendHeader(
        fin: Bool = true, reservedBits: UInt8 = 0, opcode: WSOpcode, payloadLength: Int, maskKey: UInt32? = nil,
        into buffer: inout ByteBuffer
    ) {
        precondition(payloadLength >= 0)
        buffer.append((fin ? 0x80 : 0) | (reservedBits & 0x70) | opcode.rawValue)
        let maskBit: UInt8 = maskKey == nil ? 0 : 0x80
        if payloadLength <= 125 {
            buffer.append(maskBit | UInt8(payloadLength))
        } else if payloadLength <= 0xFFFF {
            buffer.append(maskBit | 126)
            buffer.append(bigEndian: UInt16(payloadLength))
        } else {
            buffer.append(maskBit | 127)
            buffer.append(bigEndian: UInt64(payloadLength))
        }
        if let maskKey { buffer.append(bigEndian: maskKey) }
    }

    /// Appends a whole frame. With a `maskKey` the payload is masked as it is copied.
    @inlinable
    public static func appendFrame(
        fin: Bool = true, reservedBits: UInt8 = 0, opcode: WSOpcode, payload: ByteBuffer, maskKey: UInt32? = nil,
        into buffer: inout ByteBuffer
    ) {
        appendHeader(fin: fin, reservedBits: reservedBits, opcode: opcode, payloadLength: payload.readableBytes,
                     maskKey: maskKey, into: &buffer)
        if let maskKey {
            WSMasking.appendMasked(payload, key: maskKey, offset: 0, into: &buffer)
        } else {
            buffer.append(payload)
        }
    }

    /// The payload of a Close frame: the code in network order, then the UTF-8 reason. No
    /// code means an empty payload (and no reason).
    public static func closePayload(code: WebSocketCloseCode?, reason: String = "") -> ByteBuffer {
        guard let code else { return ByteBuffer() }
        var payload = ByteBuffer(capacity: 2 + reason.utf8.count)
        payload.append(bigEndian: code.rawValue)
        payload.append(contentsOf: reason.utf8)
        return payload
    }
}

/// Masking and unmasking (RFC 6455 §5.3): byte `i` of the payload is XORed with byte
/// `i % 4` of the key. Done a machine word at a time.
public enum WSMasking {
    /// The key rotated so that its first byte applies to payload byte `offset`, repeated to 8
    /// bytes in memory order (so a native-endian load XORs the right byte into each lane).
    @inlinable
    static func wordMask(key: UInt32, offset: Int) -> UInt64 {
        let shift = UInt32((offset & 3) * 8)
        let rotated = shift == 0 ? key : (key << shift) | (key >> (32 &- shift))
        // `rotated` is in wire order (first byte high); memory order is its big-endian bytes.
        let lane = UInt64(rotated.bigEndian)
        return lane | (lane << 32)
    }

    /// XORs `count` bytes from `source` into `destination` (which may be the same memory),
    /// starting `offset` bytes into the mask.
    @inlinable
    static func xor(
        _ source: UnsafeRawPointer, _ destination: UnsafeMutableRawPointer, count: Int, key: UInt32, offset: Int
    ) {
        let mask = wordMask(key: key, offset: offset)
        var i = 0
        while i &+ 8 <= count {
            let word = source.loadUnaligned(fromByteOffset: i, as: UInt64.self)
            destination.storeBytes(of: word ^ mask, toByteOffset: i, as: UInt64.self)
            i &+= 8
        }
        // The tail: the same mask, a byte at a time, in memory order.
        var tailMask = mask
        withUnsafeBytes(of: &tailMask) { maskBytes in
            var j = 0
            while i < count {
                let byte = source.load(fromByteOffset: i, as: UInt8.self)
                destination.storeBytes(of: byte ^ maskBytes[j], toByteOffset: i, as: UInt8.self)
                i &+= 1
                j &+= 1
            }
        }
    }

    /// Appends the readable bytes of `payload` to `buffer`, masked starting `offset` bytes
    /// into the key.
    @inlinable
    public static func appendMasked(_ payload: ByteBuffer, key: UInt32, offset: Int, into buffer: inout ByteBuffer) {
        let count = payload.readableBytes
        guard count > 0 else { return }
        buffer.withUnsafeMutableWritableBytes(minimumWritableBytes: count) { destination in
            payload.withUnsafeReadableBytes { source in
                xor(source.baseAddress!, destination.baseAddress!, count: count, key: key, offset: offset)
            }
        }
        buffer.commitWritten(count)
    }

    /// Moves `count` readable bytes of `source` to the end of `destination`, unmasking them
    /// with `key` starting `offset` bytes into it. One pass: the copy out of the receive
    /// buffer, which has to happen anyway, is the unmask.
    @inlinable
    public static func moveUnmasked(
        _ count: Int, from source: inout ByteBuffer, into destination: inout ByteBuffer, key: UInt32, offset: Int
    ) {
        guard count > 0 else { return }
        precondition(count <= source.readableBytes)
        destination.withUnsafeMutableWritableBytes(minimumWritableBytes: count) { to in
            source.withUnsafeReadableBytes { from in
                xor(from.baseAddress!, to.baseAddress!, count: count, key: key, offset: offset)
            }
        }
        destination.commitWritten(count)
        source.moveReaderIndex(forwardBy: count)
    }
}
