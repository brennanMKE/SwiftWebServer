import Foundation
import Testing
import HTTPCore

extension ByteBuffer {
    /// Test helper: the readable bytes as an array.
    var bytes: [UInt8] { withUnsafeReadableBytes { Array($0) } }
}

@Suite struct ByteBufferTests {
    // MARK: Empty and initialization

    @Test func emptyBufferHasNoCapacityOrBytes() {
        let buffer = ByteBuffer()
        #expect(buffer.isEmpty)
        #expect(buffer.readableBytes == 0)
        #expect(buffer.capacity == 0)
        #expect(buffer.writableBytes == 0)
        #expect(buffer.readerIndex == 0)
        #expect(buffer.writerIndex == 0)
        #expect(buffer.bytes == [])
        #expect(buffer.readableView == ByteView(offset: 0, length: 0))
        buffer.withReadableSpan { #expect($0.count == 0) }
        buffer.withReadableRawSpan { #expect($0.byteCount == 0) }
        #expect(buffer == ByteBuffer(capacity: 100))
    }

    @Test func initWithCapacity() {
        let buffer = ByteBuffer(capacity: 128)
        #expect(buffer.capacity == 128)
        #expect(buffer.writableBytes == 128)
        #expect(buffer.isEmpty)
        #expect(ByteBuffer(capacity: 0).capacity == 0)
    }

    @Test func initFromStaticStringAndSequence() {
        let literal = ByteBuffer("GET /")
        #expect(literal.bytes == Array("GET /".utf8))
        #expect(literal.capacity == 5)
        let fromArray = ByteBuffer(bytes: [1, 2, 3])
        #expect(fromArray.bytes == [1, 2, 3])
        let fromRange = ByteBuffer(bytes: (0..<5).lazy.map { UInt8($0) })
        #expect(fromRange.bytes == [0, 1, 2, 3, 4])
        #expect(ByteBuffer("") == ByteBuffer())
    }

    // MARK: Appending and growth

    @Test func appendSingleBytesGrowsAcrossCapacity() {
        var buffer = ByteBuffer(capacity: 4)
        for byte in UInt8(0)..<4 { buffer.append(byte) }
        #expect(buffer.capacity == 4)
        #expect(buffer.writableBytes == 0)
        buffer.append(4)   // crosses capacity
        #expect(buffer.capacity >= 64)
        #expect(buffer.bytes == [0, 1, 2, 3, 4])
    }

    @Test func growthIsGeometric() {
        var buffer = ByteBuffer()
        var capacities: [Int] = []
        for i in 0..<10_000 {
            buffer.append(UInt8(truncatingIfNeeded: i))
            if capacities.last != buffer.capacity { capacities.append(buffer.capacity) }
        }
        #expect(buffer.readableBytes == 10_000)
        // 64, 128, ..., 16384: logarithmic number of reallocations.
        #expect(capacities.count <= 9)
        for (a, b) in zip(capacities, capacities.dropFirst()) { #expect(b >= a * 2) }
        #expect(buffer.bytes == (0..<10_000).map { UInt8(truncatingIfNeeded: $0) })
    }

    @Test func reserveCapacityGuaranteesWritableBytes() {
        var buffer = ByteBuffer("abc")
        buffer.reserveCapacity(minimumWritableBytes: 1000)
        #expect(buffer.writableBytes >= 1000)
        #expect(buffer.bytes == Array("abc".utf8))
        let capacity = buffer.capacity
        buffer.reserveCapacity(minimumWritableBytes: 10)   // already enough: no change
        #expect(buffer.capacity == capacity)
        buffer.reserveCapacity(minimumWritableBytes: 0)
        #expect(buffer.capacity == capacity)
    }

    @Test func appendStaticStringSpanRawSpanSequenceAndBuffer() {
        var buffer = ByteBuffer()
        buffer.append("HTTP/1.1 ")
        let digits: [UInt8] = Array("200".utf8)
        digits.withUnsafeBufferPointer { buffer.append(contentsOf: $0.span) }
        buffer.append(UInt8(ascii: " "))
        let ok: [UInt8] = Array("OK".utf8)
        ok.withUnsafeBytes { buffer.append(contentsOf: $0.bytes) }
        buffer.append(contentsOf: [13, 10])                         // contiguous
        buffer.append(contentsOf: Set<UInt8>([0x41]))               // non-contiguous
        buffer.append(ByteBuffer("xyz"))
        buffer.append(ByteBuffer())
        buffer.append("")
        #expect(buffer.bytes == Array("HTTP/1.1 200 OK\r\nAxyz".utf8))
    }

    @Test func appendBufferToItself() {
        var buffer = ByteBuffer("ab")
        let copy = buffer
        buffer.append(copy)
        buffer.append(copy.readableView, from: copy)
        #expect(buffer.bytes == Array("ababab".utf8))
        #expect(copy.bytes == Array("ab".utf8))
    }

    @Test func appendViewFromAnotherBuffer() {
        let source = ByteBuffer("Host: example.com")
        var destination = ByteBuffer()
        destination.append(ByteView(offset: 6, length: 7), from: source)
        #expect(destination.bytes == Array("example".utf8))
    }

    // MARK: Integer appends

    @Test(arguments: [
        (UInt64(0), "0"), (9, "9"), (10, "10"), (99, "99"), (100, "100"),
        (1_234_567_890, "1234567890"), (UInt64.max, "18446744073709551615"),
    ])
    func appendUnsignedDecimal(value: UInt64, expected: String) {
        var buffer = ByteBuffer()
        buffer.append(decimal: value)
        #expect(buffer.bytes == Array(expected.utf8))
    }

    @Test func appendSignedAndNarrowDecimal() {
        var buffer = ByteBuffer()
        buffer.append(decimal: -1)
        buffer.append(",")
        buffer.append(decimal: Int64.min)
        buffer.append(",")
        buffer.append(decimal: Int64.max)
        buffer.append(",")
        buffer.append(decimal: Int8.min)
        buffer.append(",")
        buffer.append(decimal: UInt16(65535))
        buffer.append(",")
        buffer.append(decimal: 0)
        #expect(String(decoding: buffer.bytes, as: UTF8.self)
                == "-1,-9223372036854775808,9223372036854775807,-128,65535,0")
    }

    @Test func appendDecimalGrowsAcrossCapacity() {
        var buffer = ByteBuffer(capacity: 2)
        buffer.append("a")
        buffer.append(decimal: 12345)   // needs 5 bytes with 1 writable
        #expect(buffer.bytes == Array("a12345".utf8))
    }

    @Test(arguments: [
        (UInt64(0), "0"), (0xF, "f"), (0x10, "10"), (0xABCDEF, "abcdef"),
        (0x1000, "1000"), (UInt64.max, "ffffffffffffffff"),
    ])
    func appendHex(value: UInt64, expected: String) {
        var buffer = ByteBuffer()
        buffer.append(hex: value)
        #expect(buffer.bytes == Array(expected.utf8))
    }

    // MARK: Network byte order

    @Test func bigEndianIntegersRoundTrip() {
        var buffer = ByteBuffer()
        buffer.append(bigEndian: UInt8(0xAB))
        buffer.append(bigEndian: UInt16(0x0102))
        buffer.append(bigEndian: UInt32(0x0304_0506))
        buffer.append(bigEndian: UInt64.max - 1)
        buffer.append(bigEndian: Int32(-2))
        #expect(buffer.readableBytes == 1 + 2 + 4 + 8 + 4)
        #expect(Array(buffer.bytes.prefix(7)) == [0xAB, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        #expect(buffer.getInteger(at: 1, as: UInt16.self) == 0x0102)
        #expect(buffer.readerIndex == 0)
        let u8 = buffer.readInteger(as: UInt8.self)
        let u16 = buffer.readInteger(as: UInt16.self)
        let u32 = buffer.readInteger(as: UInt32.self)   // unaligned load
        let u64 = buffer.readInteger(as: UInt64.self)
        let i32 = buffer.readInteger(as: Int32.self)
        #expect(u8 == 0xAB)
        #expect(u16 == 0x0102)
        #expect(u32 == 0x0304_0506)
        #expect(u64 == UInt64.max - 1)
        #expect(i32 == -2)
        #expect(buffer.isEmpty)
    }

    @Test func readingIntegerPastWriterIndexReturnsNilWithoutConsuming() {
        var buffer = ByteBuffer(bytes: [0x00, 0x01, 0x02])
        let tooLong = buffer.readInteger(as: UInt32.self)
        #expect(tooLong == nil)
        #expect(buffer.readerIndex == 0)
        #expect(buffer.getInteger(at: 2, as: UInt16.self) == nil)
        #expect(buffer.getInteger(at: -1, as: UInt8.self) == nil)
        #expect(buffer.getInteger(at: 3, as: UInt8.self) == nil)
        #expect(buffer.getInteger(at: 1, as: UInt16.self) == 0x0102)
        #expect(ByteBuffer().getInteger(at: 0, as: UInt8.self) == nil)
        let first = buffer.readInteger(as: UInt16.self)
        let second = buffer.readInteger(as: UInt16.self)
        #expect(first == 0x0001)
        #expect(second == nil)
        #expect(buffer.readerIndex == 2)
    }

    // MARK: Reading and indices

    @Test func readableAccessReflectsReaderIndex() throws {
        var buffer = ByteBuffer("hello world")
        buffer.moveReaderIndex(forwardBy: 6)
        #expect(buffer.readerIndex == 6)
        #expect(buffer.readableBytes == 5)
        #expect(buffer.bytes == Array("world".utf8))
        buffer.withReadableSpan { span in
            #expect(span.count == 5)
            #expect(span[0] == UInt8(ascii: "w"))
        }
        buffer.withReadableRawSpan { raw in
            #expect(raw.byteCount == 5)
            #expect(raw.unsafeLoad(fromByteOffset: 4, as: UInt8.self) == UInt8(ascii: "d"))
        }
        #expect(buffer.byte(at: 0) == UInt8(ascii: "h"))   // consumed bytes stay addressable
        #expect(buffer.byte(at: 10) == UInt8(ascii: "d"))
        buffer.moveReaderIndex(forwardBy: 5)
        #expect(buffer.isEmpty)
        buffer.moveReaderIndex(to: 0)
        #expect(buffer.readableBytes == 11)
        buffer.moveReaderIndex(to: 11)
        #expect(buffer.isEmpty)
        buffer.moveReaderIndex(forwardBy: 0)
    }

    @Test func closuresPropagateTypedErrors() {
        struct Failure: Error {}
        let buffer = ByteBuffer("x")
        #expect(throws: Failure.self) {
            try buffer.withUnsafeReadableBytes { (_) throws(Failure) in throw Failure() }
        }
        #expect(throws: Failure.self) {
            try buffer.withReadableSpan { (_) throws(Failure) in throw Failure() }
        }
    }

    // MARK: Discard and compact

    @Test func discardWithNothingReadIsNoOp() {
        var buffer = ByteBuffer("abc")
        let compacted = buffer.discardReadBytes()
        #expect(compacted == false)
        #expect(buffer.readerIndex == 0)
        var empty = ByteBuffer()
        let emptyCompacted = empty.discardReadBytes()
        #expect(emptyCompacted == false)
    }

    @Test func discardAfterReadingEverythingResetsWithoutCopy() {
        var buffer = ByteBuffer("abcdef")
        buffer.moveReaderIndex(forwardBy: 6)
        let compacted = buffer.discardReadBytes()
        #expect(compacted)
        #expect(buffer.readerIndex == 0)
        #expect(buffer.writerIndex == 0)
        #expect(buffer.capacity == 6)
    }

    @Test func discardCompactsWhenRemainderIsSmall() {
        var buffer = ByteBuffer("0123456789")
        buffer.moveReaderIndex(forwardBy: 6)    // 4 readable, 6 consumed
        let compacted = buffer.discardReadBytes()
        #expect(compacted)
        #expect(buffer.readerIndex == 0)
        #expect(buffer.writerIndex == 4)
        #expect(buffer.bytes == Array("6789".utf8))
        #expect(buffer.writableBytes == 6)
    }

    @Test func discardCompactsAtEqualSplit() {
        var buffer = ByteBuffer("abcd")
        buffer.moveReaderIndex(forwardBy: 2)
        let compacted = buffer.discardReadBytes()
        #expect(compacted)
        #expect(buffer.bytes == Array("cd".utf8))
    }

    @Test func discardSkipsWhenRemainderIsLarge() {
        var buffer = ByteBuffer("0123456789")
        buffer.moveReaderIndex(forwardBy: 3)    // 7 readable, 3 consumed: not worth it
        let compacted = buffer.discardReadBytes()
        #expect(compacted == false)
        #expect(buffer.readerIndex == 3)
        #expect(buffer.bytes == Array("3456789".utf8))
    }

    @Test func discardOnSharedStorageLeavesCopyIntact() {
        var buffer = ByteBuffer("0123456789")
        buffer.moveReaderIndex(forwardBy: 8)
        let copy = buffer
        let compacted = buffer.discardReadBytes()
        #expect(compacted)
        #expect(buffer.bytes == Array("89".utf8))
        #expect(copy.readerIndex == 8)
        #expect(copy.bytes == Array("89".utf8))
        #expect(copy.byte(at: 0) == UInt8(ascii: "0"))
    }

    // MARK: Clear

    @Test func clearKeepingCapacity() {
        var buffer = ByteBuffer(capacity: 32)
        buffer.append("abc")
        buffer.moveReaderIndex(forwardBy: 1)
        buffer.clear()
        #expect(buffer.isEmpty)
        #expect(buffer.readerIndex == 0)
        #expect(buffer.writerIndex == 0)
        #expect(buffer.capacity == 32)
        buffer.append("z")
        #expect(buffer.bytes == [UInt8(ascii: "z")])
    }

    @Test func clearReleasingCapacity() {
        var buffer = ByteBuffer("abc")
        buffer.clear(keepingCapacity: false)
        #expect(buffer.capacity == 0)
        #expect(buffer.isEmpty)
        buffer.append("q")
        #expect(buffer.bytes == [UInt8(ascii: "q")])
    }

    @Test func clearOnSharedStorageDoesNotAffectCopy() {
        var buffer = ByteBuffer(capacity: 16)
        buffer.append("abc")
        let copy = buffer
        buffer.clear()
        buffer.append("xyz")
        #expect(copy.bytes == Array("abc".utf8))
        #expect(buffer.bytes == Array("xyz".utf8))
        #expect(buffer.capacity == 16)
    }

    // MARK: Copy-on-write and index stability

    @Test func copyOnWrite() {
        var a = ByteBuffer("abc")
        let b = a
        a.append("d")
        #expect(a.bytes == Array("abcd".utf8))
        #expect(b.bytes == Array("abc".utf8))
        var c = b
        c.moveReaderIndex(forwardBy: 1)
        #expect(b.readerIndex == 0)
        #expect(c.bytes == Array("bc".utf8))
    }

    @Test func viewsSurviveGrowthAndCopy() {
        var buffer = ByteBuffer(capacity: 8)
        buffer.append("Host: a")
        let value = ByteView(offset: 6, length: 1)
        buffer.moveReaderIndex(forwardBy: 7)
        for _ in 0..<100 { buffer.append("x") }   // grows several times
        #expect(value.string(in: buffer) == "a")
        #expect(buffer.readerIndex == 7)
        let copy = buffer
        buffer.append("y")
        #expect(value.string(in: copy) == "a")
        #expect(value.string(in: buffer) == "a")
    }

    @Test func buffersAreSendable() async {
        let buffer = ByteBuffer("sent")
        let received = await Task.detached { buffer.bytes }.value
        #expect(received == Array("sent".utf8))
    }

    // MARK: Receiving into the tail

    @Test func writeIntoTailThenCommit() {
        var buffer = ByteBuffer("ab")
        let written = buffer.withUnsafeMutableWritableBytes(minimumWritableBytes: 3) { tail in
            #expect(tail.count >= 3)
            tail[0] = UInt8(ascii: "c")
            tail[1] = UInt8(ascii: "d")
            return 2
        }
        buffer.commitWritten(written)
        #expect(buffer.bytes == Array("abcd".utf8))
    }

    @Test func writeIntoTailOfEmptyAndFullBuffers() {
        var empty = ByteBuffer()
        let count = empty.withUnsafeMutableWritableBytes { $0.count }
        #expect(count == 0)
        empty.commitWritten(0)
        #expect(empty.isEmpty)

        var full = ByteBuffer("abcd")
        #expect(full.writableBytes == 0)
        let tailCount = full.withUnsafeMutableWritableBytes(minimumWritableBytes: 1) { $0.count }
        #expect(tailCount >= 1)
        full.commitWritten(0)
        #expect(full.bytes == Array("abcd".utf8))
    }

    @Test func writeIntoTailUnsharesStorage() {
        var buffer = ByteBuffer(capacity: 8)
        buffer.append("a")
        let copy = buffer
        buffer.withUnsafeMutableWritableBytes { $0[0] = UInt8(ascii: "b") }
        buffer.commitWritten(1)
        #expect(buffer.bytes == Array("ab".utf8))
        #expect(copy.bytes == Array("a".utf8))
        #expect(copy.capacity == 8)
    }

    @Test func commitFullTail() {
        var buffer = ByteBuffer(capacity: 4)
        buffer.withUnsafeMutableWritableBytes { tail in
            for i in tail.indices { tail[i] = UInt8(i) }
        }
        buffer.commitWritten(buffer.writableBytes)
        #expect(buffer.bytes == [0, 1, 2, 3])
        #expect(buffer.writableBytes == 0)
    }

    // MARK: Data at the edges

    @Test func dataRoundTrip() {
        let data = Data("payload".utf8)
        var buffer = ByteBuffer(data)
        #expect(buffer.bytes == Array("payload".utf8))
        buffer.append(contentsOf: Data([0x21]))
        buffer.append(contentsOf: Data())
        buffer.moveReaderIndex(forwardBy: 3)
        #expect(buffer.makeData() == Data("load!".utf8))
        #expect(ByteBuffer(Data()).isEmpty)
        #expect(ByteBuffer().makeData().isEmpty)
        // A sliced Data with a non-zero start index.
        let slice = Data("xxabc".utf8).dropFirst(2)
        #expect(ByteBuffer(slice).bytes == Array("abc".utf8))
    }

    // MARK: Equality

    @Test func equalityComparesReadableBytesOnly() {
        var a = ByteBuffer("xxhello")
        a.moveReaderIndex(forwardBy: 2)
        let b = ByteBuffer("hello")
        #expect(a == b)
        #expect(a != ByteBuffer("hellO"))
        #expect(a != ByteBuffer("hell"))
        #expect(b.debugDescription.contains("writerIndex: 5"))
    }

    // MARK: Invariants trap on misuse

    @Test func readingPastWriterIndexTraps() async {
        await #expect(processExitsWith: .failure) {
            var buffer = ByteBuffer("ab")
            buffer.moveReaderIndex(forwardBy: 3)
        }
        await #expect(processExitsWith: .failure) {
            var buffer = ByteBuffer("ab")
            buffer.moveReaderIndex(to: 3)
        }
        await #expect(processExitsWith: .failure) {
            _ = ByteBuffer("ab").byte(at: 2)
        }
    }

    @Test func committingPastCapacityTraps() async {
        await #expect(processExitsWith: .failure) {
            var buffer = ByteBuffer(capacity: 4)
            buffer.commitWritten(5)
        }
        await #expect(processExitsWith: .failure) {
            var buffer = ByteBuffer(capacity: 4)
            buffer.commitWritten(-1)
        }
    }

    @Test func viewOutsideWrittenBytesTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = ByteView(offset: 1, length: 2).string(in: ByteBuffer("ab"))
        }
        await #expect(processExitsWith: .failure) {
            _ = ByteView(offset: -1, length: 0)
        }
    }
}
