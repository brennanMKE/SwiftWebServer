import Testing
import QPACK

private func parseEncoder(
    _ bytes: [UInt8], maxStringLength: Int = 1024
) throws -> QPACKInstructionParseResult<QPACKEncoderInstruction> {
    try bytes.withUnsafeBytes { raw in
        try QPACKEncoderInstruction.parse(raw, maxStringLength: maxStringLength)
    }
}

private func parseDecoder(_ bytes: [UInt8]) throws -> QPACKInstructionParseResult<QPACKDecoderInstruction> {
    try bytes.withUnsafeBytes { raw in try QPACKDecoderInstruction.parse(raw) }
}

private func encoderStream(_ bytes: [UInt8]) throws -> Int {
    var reader = QPACKEncoderStreamReader()
    return try bytes.withUnsafeBytes { raw in try reader.consume(raw) }
}

private func decoderStream(_ bytes: [UInt8]) throws -> QPACKInstructionParseResult<QPACKDecoderInstruction> {
    var reader = QPACKDecoderStreamReader()
    return try bytes.withUnsafeBytes { raw in try reader.next(raw) }
}

@Suite struct QPACKEncoderStreamTests {
    // RFC 9204 Appendix B.2, encoder stream.
    static let appendixB2 = hex(
        "3fbd01 c00f 7777 772e 6578 616d 706c 652e 636f 6d c10c 2f73 616d 706c 652f 7061 7468")

    @Test func parsesAppendixB2Structurally() throws {
        var bytes = Self.appendixB2[...]
        #expect(try parseEncoder(Array(bytes)) == .instruction(.setDynamicTableCapacity(220), consumed: 3))
        bytes = bytes.dropFirst(3)
        #expect(
            try parseEncoder(Array(bytes))
                == .instruction(
                    .insertWithNameReference(
                        isStatic: true, nameIndex: 0,
                        value: QPACKStringReference(offset: 2, length: 15, isHuffman: false)),
                    consumed: 17))
        bytes = bytes.dropFirst(17)
        #expect(
            try parseEncoder(Array(bytes))
                == .instruction(
                    .insertWithNameReference(
                        isStatic: true, nameIndex: 1,
                        value: QPACKStringReference(offset: 2, length: 12, isHuffman: false)),
                    consumed: 14))
        #expect(bytes.count == 14)
    }

    @Test func parsesOtherInstructions() throws {
        #expect(
            try parseEncoder([0x43, 0x66, 0x6F, 0x6F, 0x83, 0x01, 0x02, 0x03])
                == .instruction(
                    .insertWithLiteralName(
                        name: QPACKStringReference(offset: 1, length: 3, isHuffman: false),
                        value: QPACKStringReference(offset: 5, length: 3, isHuffman: true)),
                    consumed: 8))
        #expect(try parseEncoder([0x63, 0, 0, 0, 0x00]) == .instruction(
            .insertWithLiteralName(
                name: QPACKStringReference(offset: 1, length: 3, isHuffman: true),
                value: QPACKStringReference(offset: 5, length: 0, isHuffman: false)),
            consumed: 5))
        #expect(try parseEncoder([0x80, 0x00]) == .instruction(
            .insertWithNameReference(
                isStatic: false, nameIndex: 0, value: QPACKStringReference(offset: 2, length: 0, isHuffman: false)),
            consumed: 2))
        #expect(try parseEncoder([0x02]) == .instruction(.duplicate(index: 2), consumed: 1))
        #expect(try parseEncoder([0x1F, 0x01]) == .instruction(.duplicate(index: 32), consumed: 2))
    }

    @Test func partialInstructionsNeedMoreData() throws {
        for length in 0..<3 {
            #expect(try parseEncoder(Array(Self.appendixB2.prefix(length))) == .needsMoreData)
        }
        for length in 3..<20 {
            #expect(try parseEncoder(Array(Self.appendixB2[3..<length])) == .needsMoreData)
        }
        #expect(try parseEncoder([0x43, 0x66]) == .needsMoreData)
        #expect(try parseEncoder([0x43, 0x66, 0x6F, 0x6F]) == .needsMoreData)
        #expect(try parseEncoder([0x1F]) == .needsMoreData)
    }

    @Test func structuralErrors() {
        #expect(throws: QPACKError(.encoderStreamError, .stringTooLong)) {
            try parseEncoder([0xC0, 0x05], maxStringLength: 4)
        }
        #expect(throws: QPACKError(.encoderStreamError, .integerOverflow)) {
            try parseEncoder([0x3F] + [UInt8](repeating: 0xFF, count: 10) + [0x01])
        }
    }

    @Test func capacityZeroIsTheOnlyLegalInstruction() throws {
        #expect(try encoderStream([]) == 0)
        #expect(try encoderStream([0x20]) == 1)
        #expect(try encoderStream([0x20, 0x20, 0x20]) == 3)
        var reader = QPACKEncoderStreamReader()
        #expect(try [0x20].withUnsafeBytes { raw in try reader.next(raw) }
            == .instruction(.setDynamicTableCapacity(0), consumed: 1))
    }

    @Test func everythingElseIsAnEncoderStreamError() {
        let cases: [([UInt8], QPACKError.Reason)] = [
            (Self.appendixB2, .tableCapacityExceeded),
            ([0x21], .tableCapacityExceeded),
            ([0x3F], .tableCapacityExceeded),  // rejected before the continuation arrives
            ([0x20, 0x21], .tableCapacityExceeded),
            ([0xC0], .insertExceedsCapacity),  // rejected before the value arrives
            ([0x80, 0x00], .insertExceedsCapacity),
            ([0x40], .insertExceedsCapacity),
            ([0x7F, 0xFF, 0xFF], .insertExceedsCapacity),
            ([0x00], .invalidDynamicIndex),
            ([0x1F], .invalidDynamicIndex),
        ]
        for (bytes, reason) in cases {
            #expect(throws: QPACKError(.encoderStreamError, reason), "\(bytes)") { try encoderStream(bytes) }
        }
        #expect(QPACKError.Code.encoderStreamError.rawValue == 0x0201)
    }
}

@Suite struct QPACKDecoderStreamTests {
    @Test func parsesAllInstructions() throws {
        // RFC 9204 Appendix B.2, decoder stream: Section Acknowledgment for stream 4.
        #expect(try parseDecoder([0x84]) == .instruction(.sectionAcknowledgment(streamID: 4), consumed: 1))
        #expect(try parseDecoder([0x7F, 0x01]) == .instruction(.streamCancellation(streamID: 64), consumed: 2))
        // RFC 9204 Appendix B.3: Insert Count Increment of 1.
        #expect(try parseDecoder([0x01]) == .instruction(.insertCountIncrement(1), consumed: 1))
        #expect(try parseDecoder([]) == .needsMoreData)
        #expect(try parseDecoder([0xFF]) == .needsMoreData)
        #expect(throws: QPACKError(.decoderStreamError, .integerOverflow)) {
            try parseDecoder([0x7F] + [UInt8](repeating: 0xFF, count: 10) + [0x01])
        }
    }

    @Test func streamCancellationIsAccepted() throws {
        #expect(try decoderStream([0x41]) == .instruction(.streamCancellation(streamID: 1), consumed: 1))
        #expect(try decoderStream([0x40]) == .instruction(.streamCancellation(streamID: 0), consumed: 1))
        #expect(try decoderStream([0x7F, 0x81, 0x01]) == .instruction(.streamCancellation(streamID: 63 + 129), consumed: 3))
        #expect(try decoderStream([0x7F]) == .needsMoreData)
        #expect(try decoderStream([]) == .needsMoreData)
    }

    @Test func acknowledgmentsAndIncrementsAreDecoderStreamErrors() {
        let cases: [([UInt8], QPACKError.Reason)] = [
            ([0x84], .unexpectedSectionAcknowledgment),
            ([0x80], .unexpectedSectionAcknowledgment),
            ([0xFF], .unexpectedSectionAcknowledgment),  // rejected before the continuation arrives
            ([0x00], .invalidInsertCountIncrement),
            ([0x01], .invalidInsertCountIncrement),
            ([0x3F], .invalidInsertCountIncrement),
        ]
        for (bytes, reason) in cases {
            #expect(throws: QPACKError(.decoderStreamError, reason), "\(bytes)") { try decoderStream(bytes) }
        }
        #expect(throws: QPACKError(.decoderStreamError, .integerOverflow)) {
            try decoderStream([0x7F] + [UInt8](repeating: 0xFF, count: 10) + [0x01])
        }
        #expect(QPACKError.Code.decoderStreamError.rawValue == 0x0202)
    }
}
