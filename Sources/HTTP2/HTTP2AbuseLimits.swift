/// Limits against the published HTTP/2 denial-of-service patterns (#0056, docs/HTTP2.md DoS
/// list), the HTTP/2 counterpart of HTTP/3's `H3AbuseLimits` (#0104).
///
/// Rates are counted per connection in a fixed window (``window``, 10 s) that starts at the
/// first event of its kind. Going over a rate closes the connection with
/// `GOAWAY(ENHANCE_YOUR_CALM)`. `nil` turns a limit off.
///
/// | Setting | Default | Pattern | Response |
/// |---|---|---|---|
/// | ``maxResetStreamsPerWindow`` | 100 | Rapid reset (CVE-2023-44487): RST_STREAM on a stream whose handler still runs, and streams refused over the concurrency limit | `GOAWAY(ENHANCE_YOUR_CALM)` |
/// | ``maxControlFramesPerWindow`` | 1,000 | PING, SETTINGS, PRIORITY and unknown-type frame floods | `GOAWAY(ENHANCE_YOUR_CALM)` |
/// | ``maxEmptyFramesPerWindow`` | 100 | DATA without payload or END_STREAM; HEADERS and CONTINUATION without fragment or END_HEADERS | `GOAWAY(ENHANCE_YOUR_CALM)` |
/// | ``maxWindowUpdatesPerWindow`` | 10,000 | WINDOW_UPDATE floods | `GOAWAY(ENHANCE_YOUR_CALM)` |
/// | ``maxSmallDataFramesPerWindow`` | 1,000 | Small-window slow read: DATA the send window cut below ``smallDataFrameSize`` | `GOAWAY(ENHANCE_YOUR_CALM)` |
/// | ``windowStallTimeout`` | 30 s | Zero-window stall: a response waits this long for send window | stream window: `RST_STREAM(ENHANCE_YOUR_CALM)`; connection window: `GOAWAY(ENHANCE_YOUR_CALM)` |
/// | ``maxStreamsPerConnection`` | 100,000 | Stream-identifier exhaustion: one connection used for ever more streams | graceful `GOAWAY(NO_ERROR)`; the client reconnects |
///
/// Other patterns have their own settings in ``HTTP2Configuration``: CONTINUATION floods
/// (VU#421644: `maxContinuationFrames`, `headerBlockLimit`), queued reply floods
/// (`maxQueuedControlFrames`), HPACK bombs (`headerBlockLimit`), and a slow preface
/// (`settingsTimeout`: no preface means no SETTINGS ACK). Handler tasks still running after
/// their stream closed (reset streams being cancelled) count against twice
/// `maxConcurrentStreams`; past it new streams are refused.
public struct HTTP2AbuseLimits: Sendable, Hashable {
    public var window: Duration
    public var maxResetStreamsPerWindow: Int?
    public var maxControlFramesPerWindow: Int?
    public var maxEmptyFramesPerWindow: Int?
    public var maxWindowUpdatesPerWindow: Int?
    public var maxSmallDataFramesPerWindow: Int?
    /// DATA frames shorter than this (default 256 bytes), cut short by a flow-control window,
    /// count toward ``maxSmallDataFramesPerWindow``. Clients that return credit at half a
    /// window, as nghttp2 and browsers do, stay above it with windows of 512 bytes or more.
    public var smallDataFrameSize: Int
    public var windowStallTimeout: Duration?
    public var maxStreamsPerConnection: Int?

    public static let defaultWindow = Duration.seconds(10)

    public init(
        window: Duration = HTTP2AbuseLimits.defaultWindow,
        maxResetStreamsPerWindow: Int? = 100,
        maxControlFramesPerWindow: Int? = 1_000,
        maxEmptyFramesPerWindow: Int? = 100,
        maxWindowUpdatesPerWindow: Int? = 10_000,
        maxSmallDataFramesPerWindow: Int? = 1_000,
        smallDataFrameSize: Int = 256,
        windowStallTimeout: Duration? = .seconds(30),
        maxStreamsPerConnection: Int? = 100_000
    ) {
        precondition(window > .zero, "HTTP2AbuseLimits.window must be positive")
        for limit in [maxResetStreamsPerWindow, maxControlFramesPerWindow, maxEmptyFramesPerWindow,
                      maxWindowUpdatesPerWindow, maxSmallDataFramesPerWindow] {
            if let limit { precondition(limit >= 0, "HTTP2AbuseLimits limits must not be negative") }
        }
        precondition(smallDataFrameSize >= 0, "smallDataFrameSize must not be negative")
        if let windowStallTimeout { precondition(windowStallTimeout > .zero, "windowStallTimeout must be positive") }
        if let maxStreamsPerConnection { precondition(maxStreamsPerConnection > 0, "maxStreamsPerConnection must be positive") }
        self.window = window
        self.maxResetStreamsPerWindow = maxResetStreamsPerWindow
        self.maxControlFramesPerWindow = maxControlFramesPerWindow
        self.maxEmptyFramesPerWindow = maxEmptyFramesPerWindow
        self.maxWindowUpdatesPerWindow = maxWindowUpdatesPerWindow
        self.maxSmallDataFramesPerWindow = maxSmallDataFramesPerWindow
        self.smallDataFrameSize = smallDataFrameSize
        self.windowStallTimeout = windowStallTimeout
        self.maxStreamsPerConnection = maxStreamsPerConnection
    }

    /// No limits at all.
    public static let disabled = HTTP2AbuseLimits(
        maxResetStreamsPerWindow: nil, maxControlFramesPerWindow: nil, maxEmptyFramesPerWindow: nil,
        maxWindowUpdatesPerWindow: nil, maxSmallDataFramesPerWindow: nil, windowStallTimeout: nil,
        maxStreamsPerConnection: nil)
}

/// What a hostile peer did too often.
public enum HTTP2AbuseKind: Sendable, Hashable, CaseIterable {
    /// ``HTTP2AbuseLimits/maxResetStreamsPerWindow``.
    case resetStreams
    /// ``HTTP2AbuseLimits/maxControlFramesPerWindow``.
    case controlFrames
    /// ``HTTP2AbuseLimits/maxEmptyFramesPerWindow``.
    case emptyFrames
    /// ``HTTP2AbuseLimits/maxWindowUpdatesPerWindow``.
    case windowUpdates
    /// ``HTTP2AbuseLimits/maxSmallDataFramesPerWindow``.
    case smallDataFrames

    var reason: String {
        switch self {
        case .resetStreams: "too many reset or refused streams (rapid reset)"
        case .controlFrames: "too many PING, SETTINGS, PRIORITY or unknown frames"
        case .emptyFrames: "too many empty frames"
        case .windowUpdates: "too many WINDOW_UPDATE frames"
        case .smallDataFrames: "too many window-limited small DATA frames (slow read)"
        }
    }
}

/// The per-connection counts behind ``HTTP2AbuseLimits``. A value type with no I/O; the
/// connection keeps it in its shared state and passes the time in.
public struct HTTP2AbuseMonitor: Sendable {
    struct Count: Sendable {
        var windowStart: ContinuousClock.Instant?
        var count = 0
    }

    public let limits: HTTP2AbuseLimits
    var counts = [Count](repeating: Count(), count: HTTP2AbuseKind.allCases.count)

    public init(limits: HTTP2AbuseLimits) {
        self.limits = limits
    }

    public func limit(_ kind: HTTP2AbuseKind) -> Int? {
        switch kind {
        case .resetStreams: limits.maxResetStreamsPerWindow
        case .controlFrames: limits.maxControlFramesPerWindow
        case .emptyFrames: limits.maxEmptyFramesPerWindow
        case .windowUpdates: limits.maxWindowUpdatesPerWindow
        case .smallDataFrames: limits.maxSmallDataFramesPerWindow
        }
    }

    static func index(_ kind: HTTP2AbuseKind) -> Int {
        switch kind {
        case .resetStreams: 0
        case .controlFrames: 1
        case .emptyFrames: 2
        case .windowUpdates: 3
        case .smallDataFrames: 4
        }
    }

    /// Records `amount` events of `kind` at `now`. Returns `false` when the window's count is
    /// now over the limit.
    public mutating func record(_ kind: HTTP2AbuseKind, amount: Int = 1, now: ContinuousClock.Instant) -> Bool {
        guard let limit = limit(kind), amount > 0 else { return true }
        let i = Self.index(kind)
        if let start = counts[i].windowStart, start.advanced(by: limits.window) > now {
            counts[i].count += amount
        } else {
            counts[i] = Count(windowStart: now, count: amount)
        }
        return counts[i].count <= limit
    }

    /// The count of `kind` in the current window (for tests).
    public func count(_ kind: HTTP2AbuseKind) -> Int { counts[Self.index(kind)].count }
}
