public import HTTPCore

/// Writes HTTP/2 frames (RFC 9113 §4.1, §6) into a ``ByteBuffer``.
///
/// Each method reserves the frame's full size once and then writes the 9-octet header,
/// any fixed fields and the payload straight into the buffer, so nothing is staged in an
/// intermediate allocation. Undefined flags are never set.
///
/// The encoder does not know the peer's SETTINGS_MAX_FRAME_SIZE: callers split DATA and
/// header blocks (HEADERS + CONTINUATION) to fit it. Payload lengths above 2^24 − 1, pad
/// lengths that do not fit, and stream IDs that the frame type forbids are programming
/// errors and trap.
public enum HTTP2FrameEncoder {
    /// Appends a frame header.
    @inlinable
    public static func encodeHeader(_ header: HTTP2FrameHeader, into buffer: inout ByteBuffer) {
        precondition(header.length >= 0 && header.length <= HTTP2FrameHeader.maxLength, "frame length is 24 bits")
        buffer.append(UInt8(truncatingIfNeeded: header.length >> 16))
        buffer.append(bigEndian: UInt16(truncatingIfNeeded: header.length))
        buffer.append(header.type.rawValue)
        buffer.append(header.flags.rawValue)
        buffer.append(bigEndian: header.streamID.rawValue)
    }

    /// Appends a frame of any type, including unknown ones, with a raw payload.
    @inlinable
    public static func encodeFrame(
        type: HTTP2FrameType, flags: HTTP2FrameFlags = [], streamID: HTTP2StreamID,
        payload: UnsafeRawBufferPointer, into buffer: inout ByteBuffer
    ) {
        buffer.reserveCapacity(minimumWritableBytes: HTTP2FrameHeader.size + payload.count)
        encodeHeader(HTTP2FrameHeader(length: payload.count, type: type, flags: flags, streamID: streamID), into: &buffer)
        buffer.append(contentsOf: payload.bytes)
    }

    // MARK: DATA

    /// Appends a DATA frame header, and the Pad Length octet when `padding` is given. The
    /// caller then appends `dataLength` bytes itself (for example, read from a file straight
    /// into the buffer) followed by ``encodePadding(_:into:)`` when padded.
    @inlinable
    public static func encodeDataHeader(
        streamID: HTTP2StreamID, dataLength: Int, endStream: Bool = false, padding: UInt8? = nil,
        into buffer: inout ByteBuffer
    ) {
        precondition(!streamID.isConnection, "DATA requires a stream")
        var flags: HTTP2FrameFlags = endStream ? .endStream : []
        var length = dataLength
        if let padding {
            flags.insert(.padded)
            length += 1 + Int(padding)
        }
        buffer.reserveCapacity(minimumWritableBytes: HTTP2FrameHeader.size + length)
        encodeHeader(HTTP2FrameHeader(length: length, type: .data, flags: flags, streamID: streamID), into: &buffer)
        if let padding { buffer.append(padding) }
    }

    /// Appends a whole DATA frame.
    @inlinable
    public static func encodeData(
        streamID: HTTP2StreamID, data: UnsafeRawBufferPointer, endStream: Bool = false, padding: UInt8? = nil,
        into buffer: inout ByteBuffer
    ) {
        encodeDataHeader(streamID: streamID, dataLength: data.count, endStream: endStream, padding: padding, into: &buffer)
        buffer.append(contentsOf: data.bytes)
        if let padding { encodePadding(padding, into: &buffer) }
    }

    /// Appends `count` zero padding octets.
    @inlinable
    public static func encodePadding(_ count: UInt8, into buffer: inout ByteBuffer) {
        buffer.reserveCapacity(minimumWritableBytes: Int(count))
        for _ in 0..<count { buffer.append(0) }
    }

    // MARK: Header blocks

    /// Appends a HEADERS frame carrying an HPACK header-block fragment.
    @inlinable
    public static func encodeHeaders(
        streamID: HTTP2StreamID, fragment: UnsafeRawBufferPointer, endStream: Bool = false, endHeaders: Bool = true,
        priority: HTTP2Priority? = nil, padding: UInt8? = nil, into buffer: inout ByteBuffer
    ) {
        precondition(!streamID.isConnection, "HEADERS requires a stream")
        var flags: HTTP2FrameFlags = []
        if endStream { flags.insert(.endStream) }
        if endHeaders { flags.insert(.endHeaders) }
        var length = fragment.count
        if let padding {
            flags.insert(.padded)
            length += 1 + Int(padding)
        }
        if priority != nil {
            flags.insert(.priority)
            length += HTTP2Priority.size
        }
        buffer.reserveCapacity(minimumWritableBytes: HTTP2FrameHeader.size + length)
        encodeHeader(HTTP2FrameHeader(length: length, type: .headers, flags: flags, streamID: streamID), into: &buffer)
        if let padding { buffer.append(padding) }
        if let priority { encodePriorityFields(priority, into: &buffer) }
        buffer.append(contentsOf: fragment.bytes)
        if let padding { encodePadding(padding, into: &buffer) }
    }

    /// Appends a PUSH_PROMISE frame (server to client only).
    @inlinable
    public static func encodePushPromise(
        streamID: HTTP2StreamID, promisedStreamID: HTTP2StreamID, fragment: UnsafeRawBufferPointer,
        endHeaders: Bool = true, padding: UInt8? = nil, into buffer: inout ByteBuffer
    ) {
        precondition(!streamID.isConnection, "PUSH_PROMISE requires a stream")
        var flags: HTTP2FrameFlags = endHeaders ? .endHeaders : []
        var length = 4 + fragment.count
        if let padding {
            flags.insert(.padded)
            length += 1 + Int(padding)
        }
        buffer.reserveCapacity(minimumWritableBytes: HTTP2FrameHeader.size + length)
        encodeHeader(HTTP2FrameHeader(length: length, type: .pushPromise, flags: flags, streamID: streamID), into: &buffer)
        if let padding { buffer.append(padding) }
        buffer.append(bigEndian: promisedStreamID.rawValue)
        buffer.append(contentsOf: fragment.bytes)
        if let padding { encodePadding(padding, into: &buffer) }
    }

    /// Appends a CONTINUATION frame.
    @inlinable
    public static func encodeContinuation(
        streamID: HTTP2StreamID, fragment: UnsafeRawBufferPointer, endHeaders: Bool = true,
        into buffer: inout ByteBuffer
    ) {
        precondition(!streamID.isConnection, "CONTINUATION requires a stream")
        encodeFrame(
            type: .continuation, flags: endHeaders ? .endHeaders : [], streamID: streamID, payload: fragment,
            into: &buffer)
    }

    // MARK: Control frames

    /// Appends a PRIORITY frame.
    @inlinable
    public static func encodePriority(streamID: HTTP2StreamID, _ priority: HTTP2Priority, into buffer: inout ByteBuffer) {
        precondition(!streamID.isConnection, "PRIORITY requires a stream")
        buffer.reserveCapacity(minimumWritableBytes: HTTP2FrameHeader.size + HTTP2Priority.size)
        encodeHeader(HTTP2FrameHeader(length: HTTP2Priority.size, type: .priority, streamID: streamID), into: &buffer)
        encodePriorityFields(priority, into: &buffer)
    }

    /// Appends an RST_STREAM frame.
    @inlinable
    public static func encodeRSTStream(streamID: HTTP2StreamID, _ code: HTTP2ErrorCode, into buffer: inout ByteBuffer) {
        precondition(!streamID.isConnection, "RST_STREAM requires a stream")
        buffer.reserveCapacity(minimumWritableBytes: HTTP2FrameHeader.size + 4)
        encodeHeader(HTTP2FrameHeader(length: 4, type: .rstStream, streamID: streamID), into: &buffer)
        buffer.append(bigEndian: code.rawValue)
    }

    /// Appends a SETTINGS frame with the present settings, in identifier order.
    @inlinable
    public static func encodeSettings(_ settings: HTTP2Settings, into buffer: inout ByteBuffer) {
        let length = settings.parameterCount * HTTP2Settings.parameterSize
        buffer.reserveCapacity(minimumWritableBytes: HTTP2FrameHeader.size + length)
        encodeHeader(HTTP2FrameHeader(length: length, type: .settings, streamID: .connection), into: &buffer)
        settings.forEachParameter { id, value in
            buffer.append(bigEndian: id)
            buffer.append(bigEndian: value)
        }
    }

    /// Appends a SETTINGS acknowledgement.
    @inlinable
    public static func encodeSettingsAck(into buffer: inout ByteBuffer) {
        encodeHeader(HTTP2FrameHeader(length: 0, type: .settings, flags: .ack, streamID: .connection), into: &buffer)
    }

    /// Appends a PING frame. Reply to a peer PING with `ack: true` and the same data.
    @inlinable
    public static func encodePing(opaqueData: UInt64, ack: Bool = false, into buffer: inout ByteBuffer) {
        buffer.reserveCapacity(minimumWritableBytes: HTTP2FrameHeader.size + 8)
        encodeHeader(
            HTTP2FrameHeader(length: 8, type: .ping, flags: ack ? .ack : [], streamID: .connection), into: &buffer)
        buffer.append(bigEndian: opaqueData)
    }

    /// Appends a GOAWAY frame with raw debug data.
    @inlinable
    public static func encodeGoaway(
        lastStreamID: HTTP2StreamID, _ code: HTTP2ErrorCode, debugData: UnsafeRawBufferPointer,
        into buffer: inout ByteBuffer
    ) {
        let length = 8 + debugData.count
        buffer.reserveCapacity(minimumWritableBytes: HTTP2FrameHeader.size + length)
        encodeHeader(HTTP2FrameHeader(length: length, type: .goaway, streamID: .connection), into: &buffer)
        buffer.append(bigEndian: lastStreamID.rawValue)
        buffer.append(bigEndian: code.rawValue)
        buffer.append(contentsOf: debugData.bytes)
    }

    /// Appends a GOAWAY frame for a connection error. The debug data is the error code's name
    /// (``HTTP2Error/goawayDebugData``), never the internal reason.
    @inlinable
    public static func encodeGoaway(
        lastStreamID: HTTP2StreamID, error: HTTP2Error, into buffer: inout ByteBuffer
    ) {
        error.goawayDebugData.withUTF8Buffer { debug in
            encodeGoaway(lastStreamID: lastStreamID, error.code, debugData: UnsafeRawBufferPointer(debug), into: &buffer)
        }
    }

    /// Appends a WINDOW_UPDATE frame. `increment` must be 1 through 2^31 − 1.
    @inlinable
    public static func encodeWindowUpdate(streamID: HTTP2StreamID, increment: UInt32, into buffer: inout ByteBuffer) {
        precondition(increment >= 1 && increment <= 0x7fff_ffff, "WINDOW_UPDATE increment is 1 through 2^31-1")
        buffer.reserveCapacity(minimumWritableBytes: HTTP2FrameHeader.size + 4)
        encodeHeader(HTTP2FrameHeader(length: 4, type: .windowUpdate, streamID: streamID), into: &buffer)
        buffer.append(bigEndian: increment)
    }

    @inlinable
    static func encodePriorityFields(_ priority: HTTP2Priority, into buffer: inout ByteBuffer) {
        buffer.append(bigEndian: priority.dependency.rawValue | (priority.exclusive ? 0x8000_0000 : 0))
        buffer.append(UInt8(priority.weight - 1))
    }
}
