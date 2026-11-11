import Testing
import HTTPCore

@Suite struct ByteBufferWriterTests {
    /// Every copy length through the inline small-copy paths and into the memcpy path, at
    /// several destination offsets.
    @Test func copiesEveryLengthExactly() {
        let source = ByteBuffer(bytes: (0..<100).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })
        for offset in 0..<9 {
            for length in 0...80 {
                var buffer = ByteBuffer(bytes: [UInt8](repeating: 0xEE, count: offset))
                buffer.withWriter(reservingCapacity: length + 1) { writer in
                    writer.append(ByteView(offset: 3, length: length), from: source)
                    writer.append(0xFF)
                }
                var expected = [UInt8](repeating: 0xEE, count: offset)
                expected += (3..<(3 + length)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }
                expected.append(0xFF)
                #expect(buffer == ByteBuffer(bytes: expected), "offset \(offset) length \(length)")
            }
        }
    }

    @Test func writesLiteralsIntegersAndBuffers() {
        var buffer = ByteBuffer("x")
        let other = ByteBuffer("buf")
        buffer.withWriter(reservingCapacity: 64) { writer in
            writer.append("lit")
            writer.append(UInt8(ascii: ":"), UInt8(ascii: " "))
            writer.append(decimal: 0)
            writer.append(UInt8(ascii: ","))
            writer.append(decimal: 1_234_567_890)
            writer.append(UInt8(ascii: ","))
            writer.append(twoDigits: 7)
            writer.append(twoDigits: 42)
            writer.append(other)
            [UInt8](arrayLiteral: 0x21, 0x3F).withUnsafeBufferPointer { writer.append(contentsOf: $0.span) }
        }
        #expect(buffer == ByteBuffer("xlit: 0,1234567890,0742buf!?"))
    }

    @Test func reservesOnceAndTracksRoom() {
        var buffer = ByteBuffer()
        let room = buffer.withWriter(reservingCapacity: 10) { writer -> Int in
            let before = writer.writableBytes
            writer.append("12345")
            #expect(writer.writableBytes == before - 5)
            return before
        }
        #expect(room >= 10)
        #expect(buffer.readableBytes == 5)
        #expect(buffer.capacity >= 10)
    }

    @Test func unsharesBeforeWriting() {
        let original = ByteBuffer("abc")
        var copy = original
        copy.withWriter(reservingCapacity: 3) { $0.append("def") }
        #expect(original == ByteBuffer("abc"))
        #expect(copy == ByteBuffer("abcdef"))
    }
}
