import Testing

/// Compile check for docs/notes/span-availability.md.
///
/// With a macOS 15 deployment target, `Span`, `RawSpan` and `MutableSpan` are
/// back-deployed and can be created from unsafe buffer pointers. The
/// `Array.span` / `Array.mutableSpan` properties and `InlineArray` require macOS 26.
@Suite struct SpanAvailabilityTests {
    @Test func spanAndRawSpanFromBufferPointerOnMacOS15() {
        let bytes: [UInt8] = [0x47, 0x45, 0x54, 0x20]
        bytes.withUnsafeBufferPointer { buffer in
            let span: Span<UInt8> = buffer.span
            #expect(span.count == 4)
            #expect(span[0] == 0x47)
            let raw: RawSpan = span.bytes
            #expect(raw.byteCount == 4)
            #expect(raw.unsafeLoad(fromByteOffset: 1, as: UInt8.self) == 0x45)
            #expect(span.extracting(1..<3).count == 2)
        }
    }

    @Test func mutableSpanFromBufferPointerOnMacOS15() {
        var bytes: [UInt8] = [0, 0, 0]
        bytes.withUnsafeMutableBufferPointer { buffer in
            var span: MutableSpan<UInt8> = buffer.mutableSpan
            span[1] = 7
        }
        #expect(bytes == [0, 7, 0])
    }

    @Test func arraySpanPropertiesAndInlineArrayNeedMacOS26() {
        guard #available(macOS 26, *) else { return }
        var bytes: [UInt8] = [1, 2, 3]
        #expect(bytes.span.count == 3)
        var mutable = bytes.mutableSpan
        mutable[0] = 9
        #expect(bytes[0] == 9)

        var digits: InlineArray<4, UInt8> = [1, 2, 3, 4]
        digits[3] = 9
        #expect(digits.count == 4)
        #expect(digits[3] == 9)
    }
}
