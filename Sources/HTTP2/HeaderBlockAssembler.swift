public import HPACK

/// Joins a HEADERS or PUSH_PROMISE frame and its CONTINUATION frames into one header block
/// and enforces their sequence (RFC 9113 §4.3, §6.10).
///
/// A value type with no I/O (docs/ROADMAP.md §5.4). The connection passes every frame it
/// parses through ``handle(_:)`` before anything else, because only this machine knows whether
/// a header block is open:
/// - While a block is open, the only frame allowed is CONTINUATION on the same stream. Any
///   other frame, including an unknown type, or a CONTINUATION on another stream, is a
///   connection `PROTOCOL_ERROR`. So is a CONTINUATION when no block is open.
/// - When the block ends (END_HEADERS), the action is ``Action/decode(_:)``. The caller then
///   calls ``decode(_:fragment:with:into:)``, which hands the block to HPACK. Every block must
///   be decoded, in order, even on a refused, reset or ignored stream, so the HPACK dynamic
///   table stays in step with the peer's (§4.3).
///
/// A block that arrives in one HEADERS frame is decoded in place from that frame's fragment,
/// with no copy. A block split across frames is copied into one buffer, bounded by
/// ``Configuration/maxBlockSize`` and allocated once.
///
/// CONTINUATION flood defence (VU#421644, docs/HTTP2.md DoS list, #0056): the block's encoded
/// size is capped at ``Configuration/maxBlockSize`` and its CONTINUATION count at
/// ``Configuration/maxContinuationFrames``. Both are checked on every frame, so an endless or
/// oversized block fails on the frame that crosses the limit, not at END_HEADERS, with a
/// connection `ENHANCE_YOUR_CALM`. A block that is not kept cannot be decoded, so the
/// connection must close either way (§4.3).
///
/// Trailers: a server receives a request head and at most one trailer section per stream.
/// Clients open streams with increasing identifiers (§5.1.1), so a HEADERS block on a stream
/// at or below the highest stream that already carried one is the stream's second block: its
/// trailers. The assembler relies on ``HTTP2StreamTable`` to reject HEADERS on streams that
/// cannot carry one (and a second block without END_STREAM, §8.1).
public struct HeaderBlockAssembler: Sendable {
    public struct Configuration: Hashable, Sendable {
        /// The largest encoded header block, HEADERS plus CONTINUATION payloads, after padding
        /// is removed. Defaults to SETTINGS_MAX_HEADER_LIST_SIZE (docs/HTTP2.md: 16,384).
        public var maxBlockSize: Int
        /// The most CONTINUATION frames one block may use. Real peers use one CONTINUATION
        /// per SETTINGS_MAX_FRAME_SIZE of block; the cap catches floods of tiny or empty ones.
        public var maxContinuationFrames: Int

        public init(maxBlockSize: Int = 16_384, maxContinuationFrames: Int = 32) {
            precondition(maxBlockSize >= 0, "maxBlockSize must not be negative")
            precondition(maxContinuationFrames >= 0, "maxContinuationFrames must not be negative")
            self.maxBlockSize = maxBlockSize
            self.maxContinuationFrames = maxContinuationFrames
        }
    }

    /// What a complete header block is.
    public enum Kind: Hashable, Sendable {
        /// The first block on the stream: a request head.
        case headers
        /// A later HEADERS block: the trailer section.
        case trailers
        /// A PUSH_PROMISE block reserving `promisedStreamID` (client role only; a server
        /// rejects PUSH_PROMISE in the frame parser).
        case pushPromise(promisedStreamID: HTTP2StreamID)
    }

    /// A complete header block, ready to decode.
    public struct HeaderBlock: Hashable, Sendable {
        public var streamID: HTTP2StreamID
        public var kind: Kind
        /// END_STREAM from the HEADERS frame (always false for PUSH_PROMISE).
        public var endStream: Bool
        /// The priority fields of the HEADERS frame, if it had them.
        public var priority: HTTP2Priority?
        /// The encoded size in bytes.
        public var size: Int
        /// The number of CONTINUATION frames used.
        public var continuationFrames: Int
        /// Whether the block was assembled into the internal buffer. If not, it is exactly the
        /// fragment of the HEADERS or PUSH_PROMISE frame that completed it.
        public var isAssembled: Bool

        public init(
            streamID: HTTP2StreamID, kind: Kind, endStream: Bool, priority: HTTP2Priority? = nil, size: Int,
            continuationFrames: Int, isAssembled: Bool
        ) {
            self.streamID = streamID
            self.kind = kind
            self.endStream = endStream
            self.priority = priority
            self.size = size
            self.continuationFrames = continuationFrames
            self.isAssembled = isAssembled
        }
    }

    /// A parsed frame. Fragments are the frame's header-block bytes with padding removed, as
    /// ``HTTP2FrameParser/withPayload(_:in:_:)`` provides them; they need only live for the
    /// call.
    public enum Event {
        case headers(
            streamID: HTTP2StreamID, endStream: Bool, endHeaders: Bool, priority: HTTP2Priority?,
            fragment: UnsafeRawBufferPointer)
        case pushPromise(
            streamID: HTTP2StreamID, promisedStreamID: HTTP2StreamID, endHeaders: Bool,
            fragment: UnsafeRawBufferPointer)
        case continuation(streamID: HTTP2StreamID, endHeaders: Bool, fragment: UnsafeRawBufferPointer)
        /// Any other frame, known or unknown, on `streamID` (0 for connection frames).
        case otherFrame(HTTP2FrameType, streamID: HTTP2StreamID)
    }

    public enum Action: Hashable, Sendable {
        /// The frame is not part of a header block; process it as usual.
        case proceed
        /// The fragment was buffered; wait for CONTINUATION.
        case needsContinuation
        /// The block is complete: decode it with ``decode(_:fragment:with:into:)``.
        case decode(HeaderBlock)
        /// Send GOAWAY with this code and close the connection. The assembler stays failed.
        case connectionError(HTTP2ErrorCode)
    }

    /// An open block's metadata.
    struct Pending: Sendable {
        var streamID: HTTP2StreamID
        var kind: Kind
        var endStream: Bool
        var priority: HTTP2Priority?
        var continuationFrames: Int
    }

    public let configuration: Configuration
    var pending: Pending?
    var buffer: [UInt8] = []
    var failure: HTTP2ErrorCode?
    /// The highest stream that has carried a HEADERS block; see "Trailers" above.
    public private(set) var highestHeadersStreamID = HTTP2StreamID.connection

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Whether a block is open, waiting for CONTINUATION.
    public var isAssembling: Bool { pending != nil }

    /// The stream of the open block, if any.
    public var assemblingStreamID: HTTP2StreamID? { pending?.streamID }

    public mutating func handle(_ event: Event) -> Action {
        if let failure { return .connectionError(failure) }
        switch event {
        case .headers(let streamID, let endStream, let endHeaders, let priority, let fragment):
            guard pending == nil else { return fail(.protocolError) }
            let kind: Kind
            if streamID > highestHeadersStreamID {
                highestHeadersStreamID = streamID
                kind = .headers
            } else {
                kind = .trailers
            }
            return begin(
                Pending(streamID: streamID, kind: kind, endStream: endStream, priority: priority, continuationFrames: 0),
                endHeaders: endHeaders, fragment: fragment)

        case .pushPromise(let streamID, let promised, let endHeaders, let fragment):
            guard pending == nil else { return fail(.protocolError) }
            return begin(
                Pending(
                    streamID: streamID, kind: .pushPromise(promisedStreamID: promised), endStream: false, priority: nil,
                    continuationFrames: 0),
                endHeaders: endHeaders, fragment: fragment)

        case .continuation(let streamID, let endHeaders, let fragment):
            guard var block = pending, block.streamID == streamID else { return fail(.protocolError) }
            block.continuationFrames += 1
            guard block.continuationFrames <= configuration.maxContinuationFrames,
                buffer.count + fragment.count <= configuration.maxBlockSize
            else { return fail(.enhanceYourCalm) }
            buffer.append(contentsOf: fragment)
            guard endHeaders else {
                pending = block
                return .needsContinuation
            }
            pending = nil
            return .decode(complete(block, size: buffer.count, isAssembled: true))

        case .otherFrame:
            guard pending == nil else { return fail(.protocolError) }
            return .proceed
        }
    }

    private mutating func begin(_ block: Pending, endHeaders: Bool, fragment: UnsafeRawBufferPointer) -> Action {
        guard fragment.count <= configuration.maxBlockSize else { return fail(.enhanceYourCalm) }
        if endHeaders {
            return .decode(complete(block, size: fragment.count, isAssembled: false))
        }
        if buffer.capacity < configuration.maxBlockSize {
            buffer.reserveCapacity(configuration.maxBlockSize)
        }
        buffer.removeAll(keepingCapacity: true)
        buffer.append(contentsOf: fragment)
        pending = block
        return .needsContinuation
    }

    private func complete(_ block: Pending, size: Int, isAssembled: Bool) -> HeaderBlock {
        HeaderBlock(
            streamID: block.streamID, kind: block.kind, endStream: block.endStream, priority: block.priority,
            size: size, continuationFrames: block.continuationFrames, isAssembled: isAssembled)
    }

    private mutating func fail(_ code: HTTP2ErrorCode) -> Action {
        failure = code
        pending = nil
        buffer.removeAll(keepingCapacity: false)
        return .connectionError(code)
    }

    // MARK: Decoding

    /// Calls `body` with the encoded bytes of `block`, the action of the last ``handle(_:)``
    /// call. `fragment` is that call's fragment; it is used when the block was not assembled.
    public func withBlockBytes<R>(
        _ block: HeaderBlock, fragment: UnsafeRawBufferPointer, _ body: (Span<UInt8>) throws(HTTP2Error) -> R
    ) throws(HTTP2Error) -> R {
        if block.isAssembled {
            return try buffer.withUnsafeBufferPointer { (bytes) throws(HTTP2Error) in try body(bytes.span) }
        }
        return try body(fragment.assumingMemoryBound(to: UInt8.self).span)
    }

    /// Hands `block`, the action of the last ``handle(_:)`` call, to HPACK.
    ///
    /// - Throws: a connection `COMPRESSION_ERROR` for any HPACK failure (RFC 9113 §4.3).
    ///   The decoder is unusable afterwards.
    public func decode<Sink: HPACKFieldSink>(
        _ block: HeaderBlock, fragment: UnsafeRawBufferPointer, with decoder: inout HPACKDecoder,
        into sink: inout Sink
    ) throws(HTTP2Error) {
        try withBlockBytes(block, fragment: fragment) { (bytes) throws(HTTP2Error) in
            do throws(HPACKError) {
                try decoder.decode(bytes, into: &sink)
            } catch {
                throw HTTP2Error(error)
            }
        }
    }
}

extension HTTP2Error {
    /// The connection error for an HPACK failure: always `COMPRESSION_ERROR` (RFC 9113 §4.3).
    public init(_ error: HPACKError) {
        self = .connection(.compressionError, reason: "HPACK: \(error)")
    }
}
