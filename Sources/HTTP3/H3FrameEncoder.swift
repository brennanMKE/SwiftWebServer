public import HeaderCompression

/// Writes HTTP/3 frames (RFC 9114 §7.2) to any ``ByteSink``.
///
/// Every frame is a type varint, a length varint and a payload. Varints use their minimal
/// form. The only failure is a value of 2^62 or more, reported as
/// ``QUICVarintError/valueOutOfRange(_:)`` before anything is written for that varint.
public enum H3FrameEncoder {
    /// Appends a frame header: the type and the payload length.
    @inlinable
    public static func encodeFrameHeader<Sink: ByteSink>(
        type: H3FrameType, length: UInt64, into sink: inout Sink
    ) throws(QUICVarintError) {
        try QUICVarint.encode(type.rawValue, into: &sink)
        try QUICVarint.encode(length, into: &sink)
    }

    /// Appends a whole frame of any type, including reserved and unknown ones.
    @inlinable
    public static func encodeFrame<Sink: ByteSink>(
        type: H3FrameType, payload: UnsafeRawBufferPointer, into sink: inout Sink
    ) throws(QUICVarintError) {
        try encodeFrameHeader(type: type, length: UInt64(payload.count), into: &sink)
        appendBytes(payload, into: &sink)
    }

    /// Appends a DATA frame header only. The caller then writes `length` payload bytes
    /// itself, so a large body need not be copied through the sink.
    @inlinable
    public static func encodeDataHeader<Sink: ByteSink>(
        length: UInt64, into sink: inout Sink
    ) throws(QUICVarintError) {
        try encodeFrameHeader(type: .data, length: length, into: &sink)
    }

    /// Appends a DATA frame.
    @inlinable
    public static func encodeData<Sink: ByteSink>(
        _ payload: UnsafeRawBufferPointer, into sink: inout Sink
    ) throws(QUICVarintError) {
        try encodeFrame(type: .data, payload: payload, into: &sink)
    }

    /// Appends a HEADERS frame carrying a QPACK-encoded field section.
    @inlinable
    public static func encodeHeaders<Sink: ByteSink>(
        fieldSection: UnsafeRawBufferPointer, into sink: inout Sink
    ) throws(QUICVarintError) {
        try encodeFrame(type: .headers, payload: fieldSection, into: &sink)
    }

    /// Appends a PUSH_PROMISE frame: a push ID followed by a QPACK-encoded field section.
    @inlinable
    public static func encodePushPromise<Sink: ByteSink>(
        pushID: UInt64, fieldSection: UnsafeRawBufferPointer, into sink: inout Sink
    ) throws(QUICVarintError) {
        guard let idLength = QUICVarint.encodedLength(pushID) else { throw .valueOutOfRange(pushID) }
        try encodeFrameHeader(type: .pushPromise, length: UInt64(idLength + fieldSection.count), into: &sink)
        try QUICVarint.encode(pushID, into: &sink)
        appendBytes(fieldSection, into: &sink)
    }

    /// Appends a CANCEL_PUSH frame.
    @inlinable
    public static func encodeCancelPush<Sink: ByteSink>(
        pushID: UInt64, into sink: inout Sink
    ) throws(QUICVarintError) {
        try encodeSingleVarintFrame(type: .cancelPush, value: pushID, into: &sink)
    }

    /// Appends a GOAWAY frame. A server sends a stream ID, a client a push ID.
    @inlinable
    public static func encodeGoaway<Sink: ByteSink>(
        id: UInt64, into sink: inout Sink
    ) throws(QUICVarintError) {
        try encodeSingleVarintFrame(type: .goaway, value: id, into: &sink)
    }

    /// Appends a MAX_PUSH_ID frame.
    @inlinable
    public static func encodeMaxPushID<Sink: ByteSink>(
        _ pushID: UInt64, into sink: inout Sink
    ) throws(QUICVarintError) {
        try encodeSingleVarintFrame(type: .maxPushID, value: pushID, into: &sink)
    }

    /// Appends a SETTINGS frame. `grease`, when given, adds one extra pair after the known
    /// settings; pass a reserved identifier (0x1f·N + 0x21) to exercise the peer's handling of
    /// unknown settings (RFC 9114 §7.2.4.1).
    public static func encodeSettings<Sink: ByteSink>(
        _ settings: H3Settings, grease: (id: UInt64, value: UInt64)? = nil, into sink: inout Sink
    ) throws(QUICVarintError) {
        let length = try settings.payloadLength(grease: grease)
        try encodeFrameHeader(type: .settings, length: UInt64(length), into: &sink)
        try settings.forEachPair { (id, value) throws(QUICVarintError) in
            try QUICVarint.encode(id, into: &sink)
            try QUICVarint.encode(value, into: &sink)
        }
        if let grease {
            try QUICVarint.encode(grease.id, into: &sink)
            try QUICVarint.encode(grease.value, into: &sink)
        }
    }

    @inlinable
    static func encodeSingleVarintFrame<Sink: ByteSink>(
        type: H3FrameType, value: UInt64, into sink: inout Sink
    ) throws(QUICVarintError) {
        guard let length = QUICVarint.encodedLength(value) else { throw .valueOutOfRange(value) }
        try encodeFrameHeader(type: type, length: UInt64(length), into: &sink)
        try QUICVarint.encode(value, into: &sink)
    }

    @inlinable
    static func appendBytes<Sink: ByteSink>(_ bytes: UnsafeRawBufferPointer, into sink: inout Sink) {
        sink.reserveAdditionalCapacity(bytes.count)
        for byte in bytes { sink.append(byte) }
    }
}
