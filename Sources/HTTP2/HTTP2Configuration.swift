/// Settings for HTTP/2 connections. Defaults follow the limits table in `docs/HTTP2.md`.
///
/// The `SETTINGS_*` values are what the server advertises in its first SETTINGS frame. Each one
/// takes effect only once the client has acknowledged it (RFC 9113 §6.5.3); until then the
/// connection uses the protocol defaults.
public struct HTTP2Configuration: Sendable, Hashable {
    /// Whether cleartext connections that start with the HTTP/2 preface (prior knowledge,
    /// RFC 9113 §3.3) are served. When false, such a connection is closed; TLS connections that
    /// negotiated `h2` are always served. Config key `http2.cleartext`.
    public var cleartext: Bool
    /// `SETTINGS_MAX_CONCURRENT_STREAMS`. Excess streams get `RST_STREAM(REFUSED_STREAM)`.
    public var maxConcurrentStreams: Int
    /// `SETTINGS_INITIAL_WINDOW_SIZE`, the receive window of each new stream.
    public var initialWindowSize: UInt32
    /// The connection's receive window, raised from 65,535 with a WINDOW_UPDATE right after the
    /// server's SETTINGS.
    public var connectionWindowSize: UInt32
    /// `SETTINGS_MAX_FRAME_SIZE`: the largest frame payload accepted once acknowledged.
    public var maxFrameSize: Int
    /// `SETTINGS_MAX_HEADER_LIST_SIZE`. Also caps the encoded header block (HEADERS plus
    /// CONTINUATION) and the decoded header list.
    public var maxHeaderListSize: Int
    /// `SETTINGS_HEADER_TABLE_SIZE`: the HPACK dynamic table the client may use for requests.
    public var headerTableSize: Int
    /// The most HPACK dynamic table memory used for responses, whatever the client allows.
    public var responseHeaderTableSize: Int
    /// How long the client has to acknowledge the server's SETTINGS before the connection is
    /// closed with `GOAWAY(SETTINGS_TIMEOUT)`. `nil` waits indefinitely.
    public var settingsTimeout: Duration?
    /// Most bytes asked for per receive.
    public var receiveSize: Int
    /// Bytes of HEADERS, DATA and other ordered frames the outbound queue holds before response
    /// writers suspend. The writer sends everything queued in one `send` per drain.
    public var outboundQueueSize: Int
    /// The most control frames (SETTINGS ACK, PING ACK, WINDOW_UPDATE, RST_STREAM) queued and not
    /// yet written. A peer that provokes more is flooding: `GOAWAY(ENHANCE_YOUR_CALM)` (#0056).
    public var maxQueuedControlFrames: Int
    /// The most CONTINUATION frames one header block may use (VU#421644).
    public var maxContinuationFrames: Int
    /// Largest piece of a `.file` response body read per DATA frame batch.
    public var fileChunkSize: Int

    public static let defaultMaxConcurrentStreams = 100
    public static let defaultInitialWindowSize: UInt32 = 65_535
    public static let defaultConnectionWindowSize: UInt32 = 1 << 20
    public static let defaultMaxHeaderListSize = 16_384
    public static let defaultHeaderTableSize = 4_096

    public init(
        cleartext: Bool = true,
        maxConcurrentStreams: Int = HTTP2Configuration.defaultMaxConcurrentStreams,
        initialWindowSize: UInt32 = HTTP2Configuration.defaultInitialWindowSize,
        connectionWindowSize: UInt32 = HTTP2Configuration.defaultConnectionWindowSize,
        maxFrameSize: Int = HTTP2Settings.defaultMaxFrameSize,
        maxHeaderListSize: Int = HTTP2Configuration.defaultMaxHeaderListSize,
        headerTableSize: Int = HTTP2Configuration.defaultHeaderTableSize,
        responseHeaderTableSize: Int = HTTP2Configuration.defaultHeaderTableSize,
        settingsTimeout: Duration? = .seconds(10),
        receiveSize: Int = 16 * 1024,
        outboundQueueSize: Int = 64 * 1024,
        maxQueuedControlFrames: Int = 1_000,
        maxContinuationFrames: Int = 32,
        fileChunkSize: Int = 16 * 1024
    ) {
        precondition((0...HTTP2StreamTable.Configuration.maxSupportedConcurrentStreams).contains(maxConcurrentStreams),
                     "maxConcurrentStreams out of range")
        precondition(initialWindowSize <= HTTP2Settings.maxWindowSize, "initialWindowSize above 2^31-1")
        precondition(connectionWindowSize >= 65_535 && connectionWindowSize <= HTTP2Settings.maxWindowSize,
                     "connectionWindowSize is 65,535 through 2^31-1")
        precondition((HTTP2Settings.defaultMaxFrameSize...HTTP2Settings.maxMaxFrameSize).contains(maxFrameSize),
                     "maxFrameSize is 2^14 through 2^24-1")
        precondition(maxHeaderListSize > 0 && headerTableSize >= 0 && responseHeaderTableSize >= 0,
                     "header sizes must not be negative")
        precondition(receiveSize > 0 && outboundQueueSize > 0 && maxQueuedControlFrames > 0 && fileChunkSize > 0,
                     "HTTP2Configuration sizes must be positive")
        if let settingsTimeout { precondition(settingsTimeout > .zero, "settingsTimeout must be positive") }
        self.cleartext = cleartext
        self.maxConcurrentStreams = maxConcurrentStreams
        self.initialWindowSize = initialWindowSize
        self.connectionWindowSize = connectionWindowSize
        self.maxFrameSize = maxFrameSize
        self.maxHeaderListSize = maxHeaderListSize
        self.headerTableSize = headerTableSize
        self.responseHeaderTableSize = responseHeaderTableSize
        self.settingsTimeout = settingsTimeout
        self.receiveSize = receiveSize
        self.outboundQueueSize = outboundQueueSize
        self.maxQueuedControlFrames = maxQueuedControlFrames
        self.maxContinuationFrames = maxContinuationFrames
        self.fileChunkSize = fileChunkSize
    }

    /// The SETTINGS frame the server sends first. `SETTINGS_ENABLE_PUSH` is omitted: a server
    /// never sends it (and never pushes). `SETTINGS_NO_RFC7540_PRIORITIES` is 1 (RFC 9218 §2.1):
    /// the RFC 7540 priority signals are parsed, validated and ignored (#0050).
    public var localSettings: HTTP2Settings {
        HTTP2Settings(
            headerTableSize: UInt32(headerTableSize),
            maxConcurrentStreams: UInt32(maxConcurrentStreams),
            initialWindowSize: initialWindowSize,
            maxFrameSize: UInt32(maxFrameSize),
            maxHeaderListSize: UInt32(maxHeaderListSize),
            noRFC7540Priorities: true)
    }

    /// The connection state machine's configuration.
    public var connection: HTTP2Connection.Configuration {
        HTTP2Connection.Configuration(
            localSettings: localSettings,
            connectionWindowSize: connectionWindowSize,
            streams: HTTP2StreamTable.Configuration(maxConcurrentStreams: maxConcurrentStreams))
    }
}
