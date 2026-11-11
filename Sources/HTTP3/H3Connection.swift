import HeaderCompression

/// Settings for one HTTP/3 connection.
public struct H3Configuration: Sendable, Hashable {
    /// The largest decoded request field section accepted (name + value + 32 per field,
    /// RFC 9114 §4.2.2), advertised as `SETTINGS_MAX_FIELD_SECTION_SIZE`. A larger request
    /// head is answered with `431`.
    public var maxFieldSectionSize: Int
    /// The largest encoded HEADERS frame payload accepted; larger is `H3_EXCESSIVE_LOAD`.
    public var maxEncodedFieldSectionLength: Int
    /// Advertise `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1` (RFC 9220), for WebSockets over HTTP/3
    /// (#0111). Off by default.
    public var enableConnectProtocol: Bool
    /// Most bytes asked for per stream receive.
    public var receiveSize: Int
    /// Request body chunks buffered between the stream reader and the handler. The reader stops
    /// reading the QUIC stream (backpressure) while this many chunks wait.
    public var bodyQueueCapacity: Int

    public init(
        maxFieldSectionSize: Int = 16 * 1024,
        maxEncodedFieldSectionLength: Int = 64 * 1024,
        enableConnectProtocol: Bool = false,
        receiveSize: Int = 16 * 1024,
        bodyQueueCapacity: Int = 4
    ) {
        precondition(maxFieldSectionSize > 0 && maxEncodedFieldSectionLength > 0,
                     "H3Configuration field section limits must be positive")
        precondition(receiveSize > 0 && bodyQueueCapacity > 0, "H3Configuration sizes must be positive")
        self.maxFieldSectionSize = maxFieldSectionSize
        self.maxEncodedFieldSectionLength = maxEncodedFieldSectionLength
        self.enableConnectProtocol = enableConnectProtocol
        self.receiveSize = receiveSize
        self.bodyQueueCapacity = bodyQueueCapacity
    }

    /// The SETTINGS this server sends: a QPACK dynamic table of capacity 0, no blocked
    /// streams, the field section limit, and extended CONNECT when enabled.
    public var localSettings: H3Settings {
        H3Settings(
            qpackMaxTableCapacity: 0,
            maxFieldSectionSize: UInt64(maxFieldSectionSize),
            qpackBlockedStreams: 0,
            enableConnectProtocol: enableConnectProtocol ? true : nil)
    }
}

/// Connection-level HTTP/3 state for a server (RFC 9114 §6.2, §7.2.4; RFC 9204 §4.2).
///
/// A value type with no I/O: the runner (``HTTP3``) reads streams and frames and reports them
/// here; each ``handle(_:)`` returns the single ``Action`` to take. It decides:
///
/// - what to do with each peer stream: serve a request, read the one control stream, read the
///   one QPACK encoder and decoder stream, or ignore a reserved or unknown stream type with
///   STOP_SENDING `H3_STREAM_CREATION_ERROR`;
/// - the control-stream rules: SETTINGS first (`H3_MISSING_SETTINGS`), SETTINGS only once
///   (`H3_FRAME_UNEXPECTED`), a second control, encoder or decoder stream or a client push
///   stream (`H3_STREAM_CREATION_ERROR`), a critical stream closing
///   (`H3_CLOSED_CRITICAL_STREAM`), and push-ID bookkeeping (`H3_ID_ERROR`);
/// - that the first connection error wins: it returns ``Action/closeConnection(code:)`` once
///   and ignores everything after it.
///
/// Frame-level rules (frame types per stream, SETTINGS payload validation, duplicate and
/// HTTP/2-only setting identifiers) are checked by ``H3FrameParser`` and ``H3Settings``; their
/// errors arrive here as ``Event/connectionError(_:)``.
public struct H3Connection: Sendable {
    /// The peer's streams that the connection cannot live without (RFC 9114 §6.2.1,
    /// RFC 9204 §4.2).
    public enum CriticalStream: Sendable, Hashable {
        case control
        case qpackEncoder
        case qpackDecoder
    }

    /// A frame received on the peer's control stream.
    public enum ControlFrame: Sendable, Equatable {
        case settings(H3Settings)
        case goaway(id: UInt64)
        case maxPushID(UInt64)
        case cancelPush(pushID: UInt64)
    }

    public enum Event: Sendable, Equatable {
        /// The peer opened a bidirectional stream.
        case requestStream(streamID: UInt64)
        /// The type of a peer unidirectional stream was read.
        case uniStream(H3UniStreamType)
        /// A frame arrived on the peer's control stream.
        case controlFrame(ControlFrame)
        /// A critical stream ended (FIN) or was reset.
        case criticalStreamClosed(CriticalStream)
        /// A parser found a connection error; `code` is an `H3_*` or `QPACK_*` code.
        case connectionError(code: UInt64)
    }

    public enum Action: Sendable, Hashable {
        case none
        /// Run the request stream's state machine and the handler.
        case serveRequest
        /// Answer the request stream with RESET_STREAM `code` without processing it.
        case rejectRequest(code: UInt64)
        /// Read the peer's control stream.
        case readControlStream
        /// Read and validate the peer's QPACK encoder stream.
        case readQPACKEncoderStream
        /// Read and validate the peer's QPACK decoder stream.
        case readQPACKDecoderStream
        /// Stop reading the stream with STOP_SENDING `code` (reserved and unknown types).
        case ignoreStream(stopSendingCode: UInt64)
        /// Close the connection with `code`. Returned once, for the first error.
        case closeConnection(code: UInt64)
    }

    public let configuration: H3Configuration
    /// The peer's SETTINGS, once received.
    public private(set) var peerSettings: H3Settings?
    /// The code the connection is closing with, once an error occurred.
    public private(set) var closeCode: UInt64?
    /// The largest push ID the client allows (MAX_PUSH_ID). The server never pushes; it is
    /// tracked only to validate CANCEL_PUSH and later MAX_PUSH_ID frames.
    public private(set) var maxPushID: UInt64?
    /// The push ID of the client's last GOAWAY.
    public private(set) var peerGoawayID: UInt64?
    /// Highest client bidirectional stream ID seen, for GOAWAY (#0102).
    public private(set) var largestRequestStreamID: UInt64?

    var sawControlStream = false
    var sawEncoderStream = false
    var sawDecoderStream = false

    public init(configuration: H3Configuration = H3Configuration()) {
        self.configuration = configuration
    }

    /// True once a connection error occurred.
    public var isClosing: Bool { closeCode != nil }

    public mutating func handle(_ event: Event) -> Action {
        guard closeCode == nil else {
            if case .requestStream = event { return .rejectRequest(code: HTTP3Error.requestRejected.rawValue) }
            return .none
        }
        switch event {
        case .requestStream(let id):
            // Only client-initiated bidirectional streams carry requests (RFC 9114 §6.1).
            guard id & 0x3 == 0 else { return fail(.streamCreationError) }
            if largestRequestStreamID.map({ id > $0 }) ?? true { largestRequestStreamID = id }
            return .serveRequest

        case .uniStream(let type):
            switch type {
            case .control:
                guard !sawControlStream else { return fail(.streamCreationError) }
                sawControlStream = true
                return .readControlStream
            case .qpackEncoder:
                guard !sawEncoderStream else { return fail(.streamCreationError) }
                sawEncoderStream = true
                return .readQPACKEncoderStream
            case .qpackDecoder:
                guard !sawDecoderStream else { return fail(.streamCreationError) }
                sawDecoderStream = true
                return .readQPACKDecoderStream
            case .push:
                // Only servers push; a client push stream is a connection error (§6.2.2).
                return fail(.streamCreationError)
            case .reserved, .unknown:
                return .ignoreStream(stopSendingCode: HTTP3Error.streamCreationError.rawValue)
            }

        case .controlFrame(let frame):
            return handleControlFrame(frame)

        case .criticalStreamClosed:
            return fail(.closedCriticalStream)

        case .connectionError(let code):
            closeCode = code
            return .closeConnection(code: code)
        }
    }

    mutating func handleControlFrame(_ frame: ControlFrame) -> Action {
        guard peerSettings != nil else {
            guard case .settings(let settings) = frame else { return fail(.missingSettings) }
            peerSettings = settings
            return .none
        }
        switch frame {
        case .settings:
            return fail(.frameUnexpected)
        case .goaway(let id):
            // A client's GOAWAY carries a push ID, which must not increase (§5.2).
            if let previous = peerGoawayID, id > previous { return fail(.idError) }
            peerGoawayID = id
            return .none
        case .maxPushID(let id):
            if let previous = maxPushID, id < previous { return fail(.idError) }
            maxPushID = id
            return .none
        case .cancelPush(let id):
            // We never push, but a push ID above the client's limit is still an error (§7.2.3).
            guard let limit = maxPushID, id <= limit else { return fail(.idError) }
            return .none
        }
    }

    mutating func fail(_ error: HTTP3Error) -> Action {
        closeCode = error.rawValue
        return .closeConnection(code: error.rawValue)
    }

    // MARK: Local streams

    /// The first bytes of our control stream: its type (0x00) and our SETTINGS.
    public func controlStreamPreface() -> [UInt8] {
        var bytes: [UInt8] = []
        // Neither the type nor any setting can exceed the varint range.
        try! H3UniStreamType.control.encode(into: &bytes)
        try! H3FrameEncoder.encodeSettings(configuration.localSettings, into: &bytes)
        return bytes
    }

    /// The first byte of our QPACK encoder stream. With a table capacity of 0 we never send an
    /// encoder instruction, so the stream carries only its type.
    public static let qpackEncoderStreamPreface: [UInt8] = [0x02]
    /// The first byte of our QPACK decoder stream. With static-only field sections there is
    /// nothing to acknowledge, so it carries only its type.
    public static let qpackDecoderStreamPreface: [UInt8] = [0x03]
}
