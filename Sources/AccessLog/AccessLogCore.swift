public import HTTPCore
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Complete lines handed from a connection to the writer.
struct LogBatch: Sendable {
    var bytes: ByteBuffer
    var lines: Int
}

/// One connection's line buffer, under the connection's lock.
struct LogBuffer: Sendable {
    var bytes = ByteBuffer()
    var lines = 0
    /// The start of every line on this connection for the current second: the peer and the
    /// date (and for JSON the protocol), rendered once per second so a line is a few appends.
    var prefix = ByteBuffer()
    var prefixSecond: Int64 = -1
    /// The clock tick before which ``prefixSecond`` is current (see `SystemWallClock`).
    var prefixStableUntilTick: UInt64 = 0

    /// Takes the buffered lines, leaving an empty buffer that allocates on its next line (an
    /// idle connection holds no buffer).
    mutating func take() -> LogBatch? {
        guard lines > 0 else { return nil }
        defer {
            bytes = ByteBuffer()
            lines = 0
        }
        return LogBatch(bytes: bytes, lines: lines)
    }
}

/// The access log's per-connection state, set on the connection's ``RequestContext`` by
/// ``AccessLog/connectionWillStart(_:)``.
///
/// - Lines are formatted into ``log``, a buffer under a lock that only this connection's
///   requests and the writer's periodic collection take (uncontended on HTTP/1.1), and handed
///   to the writer in batches.
/// - Metrics go to ``shard`` with relaxed atomic adds, no lock.
///
/// The request path reads only trivial stored values (no retains) besides the lock.
final class AccessLogConnection: Sendable {
    let settings: LogSettings
    let shard = MetricShard()
    let log = Mutex(LogBuffer())
    let format: AccessLogFormat
    let batchSize: Int
    let bufferCapacity: Int
    /// The peer address, escaped for the format; `-` when unknown. Read once per second.
    let remote: ByteBuffer
    let protocolName: StaticString
    /// Where to find a recycled buffer for a new batch; `nil` for the core's shared state.
    let spares: AccessLogCore?

    init(settings: LogSettings, info: ConnectionInfo, spares: AccessLogCore?) {
        self.settings = settings
        self.spares = spares
        format = settings.format
        batchSize = settings.batchSize
        bufferCapacity = settings.bufferCapacity
        var remote = ByteBuffer()
        if let host = info.remoteAddress?.host, !host.isEmpty {
            let bytes = ByteBuffer(bytes: host.utf8)
            remote.withWriter(reservingCapacity: bytes.readableBytes * 6) { writer in
                bytes.withReadableSpan { host in
                    if settings.format == .json {
                        AccessLogLineFormatter.appendJSONEscaped(host, to: &writer)
                    } else {
                        AccessLogLineFormatter.appendCLFEscaped(host, to: &writer)
                    }
                }
            }
        } else {
            remote.append("-")
        }
        self.remote = remote
        switch info.negotiatedALPN {
        case "h3": protocolName = "HTTP/3.0"
        case "h2": protocolName = "HTTP/2.0"
        default: protocolName = "HTTP/1.1"
        }
    }

    /// Formats one line into the buffer; returns a full batch to hand to the writer.
    @inline(__always)
    func append(_ request: HTTPRequest, _ fields: AccessLogLineFormatter.Fields, endTicks: UInt64) -> LogBatch? {
        let format = self.format
        let protocolName = self.protocolName
        let batchSize = self.batchSize
        return log.withLock { state -> LogBatch? in
            if endTicks >= state.prefixStableUntilTick || state.prefix.isEmpty {
                refreshPrefix(&state)
            }
            let bound = fields.bound(for: request, format: format, prefixLength: state.prefix.readableBytes)
            if state.bytes.capacity == 0 {
                if let spare = spares?.spareBuffer() {
                    state.bytes = spare
                } else {
                    state.bytes.reserveCapacity(minimumWritableBytes: Swift.max(bufferCapacity, bound))
                }
            }
            state.bytes.withWriter(reservingCapacity: bound) { writer in
                state.prefix.withReadableSpan { prefix in
                    AccessLogLineFormatter.writeLine(request, fields, format: format, prefix: prefix,
                                                     protocolName: protocolName, to: &writer)
                }
            }
            state.lines &+= 1
            return state.bytes.readableBytes >= batchSize ? state.take() : nil
        }
    }

    /// Re-renders the line prefix when the second changed.
    @inline(never)
    func refreshPrefix(_ state: inout LogBuffer) {
        let reading = settings.clock.read()
        state.prefixStableUntilTick = reading.stableUntilTick
        guard reading.seconds != state.prefixSecond || state.prefix.isEmpty else { return }
        state.prefixSecond = reading.seconds
        state.prefix.clear()
        state.prefix.withWriter(reservingCapacity: remote.readableBytes + 128) { writer in
            remote.withReadableSpan { remote in
                AccessLogLineFormatter.writePrefix(format: format, remote: remote, seconds: reading.seconds,
                                                   protocolName: protocolName, to: &writer)
            }
        }
    }
}

/// What every connection of one access log formats with. Its identity tells a log's own
/// connection state from another log's.
final class LogSettings: Sendable {
    let format: AccessLogFormat
    let batchSize: Int
    /// Buffer capacity: a batch plus room for the line that completes it.
    let bufferCapacity: Int
    let clock = SystemWallClock()

    init(format: AccessLogFormat, batchSize: Int) {
        self.format = format
        self.batchSize = batchSize
        self.bufferCapacity = batchSize + 1024
    }
}

/// The shared state behind an ``AccessLog`` value: configuration, the writer's queue, the
/// open connections (for periodic collection) and the statistics.
@usableFromInline
final class AccessLogCore: Sendable {
    let settings: LogSettings
    let destination: AccessLogDestination?
    let options: AccessLogOptions
    let metrics: AccessLogMetrics?
    let queue: BoundedAsyncQueue<LogBatch>
    /// `mach_timebase_info` (ticks to nanoseconds); 1/1 where ticks are nanoseconds.
    let timebaseNumerator: UInt64
    let timebaseDenominator: UInt64

    /// Lines from requests that carry no connection state (a runner driven without
    /// ``ConnectionObservers``) and the leftovers of closed connections, coalesced into
    /// batches. Shared, so its lock can be contended; connections normally bypass it.
    let sharedConnection: AccessLogConnection
    /// Open connections, so the writer can collect what idle ones have buffered.
    let live = Mutex<[ObjectIdentifier: AccessLogConnection]>([:])

    let counters = LogCounters()
    /// Written batches' buffers, reused by connections for their next batch so a batch costs
    /// no `malloc`/`free` pair (the free would be on the writer's thread).
    let spareBuffers = Mutex<[ByteBuffer]>([])

    init(format: AccessLogFormat, destination: AccessLogDestination?, metrics: AccessLogMetrics?,
         options: AccessLogOptions) {
        let settings = LogSettings(format: format, batchSize: options.batchSize)
        self.settings = settings
        self.destination = destination
        self.options = options
        self.metrics = metrics
        self.queue = BoundedAsyncQueue(capacity: options.queueCapacity)
        self.sharedConnection = AccessLogConnection(settings: settings, info: ConnectionInfo(), spares: nil)
        #if canImport(Darwin)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebaseNumerator = UInt64(Swift.max(info.numer, 1))
        timebaseDenominator = UInt64(Swift.max(info.denom, 1))
        #else
        timebaseNumerator = 1
        timebaseDenominator = 1
        #endif
        if let metrics {
            metrics.attach(counters)
            metrics.attachShared(sharedConnection.shard)
        }
    }

    var format: AccessLogFormat { settings.format }

    var logs: Bool { destination != nil }

    var statistics: AccessLogStatistics { counters.statistics }

    // MARK: Request path

    /// Records one answered request: metrics into the connection's shard, a line into its
    /// buffer.
    @usableFromInline
    func record(_ request: HTTPRequest, context: RequestContext, status: Int, responseBytes: Int?) {
        let end = MonotonicInstant.now()
        var duration: UInt64?
        if let start = context.startTime, start.ticks <= end.ticks {
            duration = (end.ticks &- start.ticks) &* timebaseNumerator / timebaseDenominator
        }
        let connection: AccessLogConnection
        if let own = context[AccessLogConnectionKey.self], own.settings === settings {
            connection = own
        } else {
            connection = sharedConnection
        }
        // HEAD and 1xx/204/304 responses carry no body bytes.
        let sentBytes = request.method == .head || status < 200 || status == 204 || status == 304
            ? 0 : responseBytes
        if metrics != nil {
            connection.shard.record(status: status, requestBytes: request.body.knownLength ?? 0,
                                    responseBytes: sentBytes ?? 0, durationNanoseconds: duration)
        }
        guard logs else { return }
        var referer: ByteView?
        var userAgent: ByteView?
        if format != .common {
            referer = request.headers.firstValue(for: .referer)
            userAgent = request.headers.firstValue(for: .userAgent)
        }
        let fields = AccessLogLineFormatter.Fields(status: status, responseBytes: sentBytes,
                                                   durationNanoseconds: duration, referer: referer,
                                                   userAgent: userAgent)
        if let batch = connection.append(request, fields, endTicks: end.ticks) { submit(batch) }
    }

    /// Hands a batch to the writer, or drops and counts it if the queue is full. Never waits.
    func submit(_ batch: LogBatch) {
        // Counted per batch, not per line: a global counter bumped by every request on every
        // core would bounce its cache line between them.
        counters.linesLogged.wrappingAdd(UInt64(batch.lines), ordering: .relaxed)
        if !queue.trySend(batch) {
            counters.linesDropped.wrappingAdd(UInt64(batch.lines), ordering: .relaxed)
        }
    }

    // MARK: Connections

    func openConnection(_ info: ConnectionInfo) -> AccessLogConnection {
        let connection = AccessLogConnection(settings: settings, info: info, spares: self)
        if logs { live.withLock { $0[ObjectIdentifier(connection)] = connection } }
        metrics?.open(connection.shard)
        return connection
    }

    func closeConnection(_ connection: AccessLogConnection) {
        if logs {
            live.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(connection)) }
            // Coalesce the leftovers with other closed connections' rather than queue a tiny
            // batch per connection.
            if let leftover = connection.log.withLock({ $0.take() }) { appendShared(leftover) }
        }
        metrics?.close(connection.shard)
    }

    func appendShared(_ batch: LogBatch) {
        let full = sharedConnection.log.withLock { state -> LogBatch? in
            state.bytes.append(batch.bytes)
            state.lines &+= batch.lines
            return state.bytes.readableBytes >= options.batchSize ? state.take() : nil
        }
        if let full { submit(full) }
    }

    /// Spare buffers kept after a burst (about 0.6 MiB at the default batch size).
    static let maximumSpareBuffers = 64

    /// Keeps a written buffer for a connection's next batch.
    func recycle(_ buffer: ByteBuffer) {
        var buffer = buffer
        guard buffer.capacity >= settings.bufferCapacity else { return }
        buffer.clear(keepingCapacity: true)
        spareBuffers.withLock { spares in
            if spares.count < Self.maximumSpareBuffers { spares.append(buffer) }
        }
    }

    /// A cleared buffer for a new batch: a recycled one when there is one.
    func spareBuffer() -> ByteBuffer? {
        spareBuffers.withLock { $0.popLast() }
    }

    /// Hands every buffered line to the writer: the open connections' and the shared buffer.
    func collect() {
        for batch in takeAll() { submit(batch) }
    }

    /// Takes every buffered line (open connections, then the shared buffer).
    func takeAll() -> [LogBatch] {
        let connections = live.withLock { Array($0.values) }
        var batches: [LogBatch] = []
        for connection in connections {
            if let batch = connection.log.withLock({ $0.take() }) { batches.append(batch) }
        }
        if let batch = sharedConnection.log.withLock({ $0.take() }) { batches.append(batch) }
        return batches
    }
}

/// An access log's writer statistics: shared with ``AccessLogMetrics`` (which reports them)
/// without the metrics holding the log.
final class LogCounters: Sendable {
    let linesLogged = Atomic<UInt64>(0)
    let linesWritten = Atomic<UInt64>(0)
    let linesDropped = Atomic<UInt64>(0)
    let bytesWritten = Atomic<UInt64>(0)
    let writeErrors = Atomic<UInt64>(0)

    var statistics: AccessLogStatistics {
        AccessLogStatistics(linesLogged: linesLogged.load(ordering: .relaxed),
                            linesWritten: linesWritten.load(ordering: .relaxed),
                            linesDropped: linesDropped.load(ordering: .relaxed),
                            bytesWritten: bytesWritten.load(ordering: .relaxed),
                            writeErrors: writeErrors.load(ordering: .relaxed))
    }
}

/// The ``RequestContext`` key of the access log's per-connection state.
enum AccessLogConnectionKey: RequestContextKey {
    static var defaultValue: AccessLogConnection? { nil }
}
