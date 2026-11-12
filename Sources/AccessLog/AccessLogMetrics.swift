public import HTTPCore
import Synchronization

/// Request latency in fixed log-scale buckets: bucket `k` (0...23) counts durations in
/// `(2^(k-1), 2^k]` microseconds (bucket 0 is `[0, 1]` µs), so the bounds run from 1 µs to
/// about 8.4 s; the last bucket (24) counts everything slower. Finding a bucket is one
/// leading-zero count, no search.
public struct LatencyHistogram: Sendable, Hashable {
    /// Buckets, the overflow bucket included.
    public static let bucketCount = 25

    /// The inclusive upper bound of `bucket` in microseconds, or `nil` for the overflow bucket.
    public static func upperBoundMicroseconds(_ bucket: Int) -> UInt64? {
        precondition(bucket >= 0 && bucket < bucketCount, "no bucket \(bucket)")
        return bucket == bucketCount - 1 ? nil : 1 << UInt64(bucket)
    }

    /// The bucket a duration of `nanoseconds` falls in.
    @inlinable
    public static func bucket(nanoseconds: UInt64) -> Int {
        let microseconds = nanoseconds / 1_000
        guard microseconds > 1 else { return 0 }
        return Swift.min(64 &- (microseconds &- 1).leadingZeroBitCount, bucketCount &- 1)
    }

    /// Count per bucket (not cumulative), ``bucketCount`` entries.
    public var counts: [UInt64]
    /// Sum of all recorded durations.
    public var sumNanoseconds: UInt64

    public init(counts: [UInt64] = Array(repeating: 0, count: LatencyHistogram.bucketCount), sumNanoseconds: UInt64 = 0) {
        precondition(counts.count == Self.bucketCount, "a LatencyHistogram has \(Self.bucketCount) buckets")
        self.counts = counts
        self.sumNanoseconds = sumNanoseconds
    }

    /// Recorded durations.
    public var count: UInt64 { counts.reduce(0, &+) }

    /// Adds one duration.
    public mutating func record(nanoseconds: UInt64) {
        counts[Self.bucket(nanoseconds: nanoseconds)] &+= 1
        sumNanoseconds &+= nanoseconds
    }

    /// Adds `other`'s counts to this histogram.
    public mutating func merge(_ other: LatencyHistogram) {
        for index in 0..<Self.bucketCount { counts[index] &+= other.counts[index] }
        sumNanoseconds &+= other.sumNanoseconds
    }
}

/// Request metrics that an ``AccessLog`` collects (#0090, #0064).
///
/// Each connection counts into its own shard, which is merged into the total when the
/// connection closes; a scrape (``snapshot()``) adds the open connections' shards to that
/// total (docs/ROADMAP.md §7, "shard, don't share"). The request path touches only its own
/// connection's counters: relaxed atomic adds on cache lines no other core writes, no lock.
///
/// Pass the same instance to ``AccessLog`` (which records) and to ``MetricsEndpoint`` (which
/// serves the Prometheus text).
public final class AccessLogMetrics: Sendable {
    /// What a scrape returns.
    public struct Snapshot: Sendable, Hashable {
        /// Responses per status class: index 0 is 1xx, 1 is 2xx, … 4 is 5xx.
        public var responsesByStatusClass: [UInt64]
        /// Request body bytes (as declared by `Content-Length`; chunked bodies count 0).
        public var requestBodyBytes: UInt64
        /// Response body bytes (the declared length; streams without one count 0).
        public var responseBodyBytes: UInt64
        /// Time from the request reaching the chain to the handler's response.
        public var latency: LatencyHistogram
        /// Connections that opened (with the access log registered).
        public var connectionsOpened: UInt64
        /// Connections that closed and were merged into the total.
        public var connectionsClosed: UInt64
        /// The access log's writer statistics, summed over the logs recording here.
        public var log: AccessLogStatistics

        public init(responsesByStatusClass: [UInt64] = [0, 0, 0, 0, 0], requestBodyBytes: UInt64 = 0,
                    responseBodyBytes: UInt64 = 0, latency: LatencyHistogram = LatencyHistogram(),
                    connectionsOpened: UInt64 = 0, connectionsClosed: UInt64 = 0,
                    log: AccessLogStatistics = AccessLogStatistics()) {
            self.responsesByStatusClass = responsesByStatusClass
            self.requestBodyBytes = requestBodyBytes
            self.responseBodyBytes = responseBodyBytes
            self.latency = latency
            self.connectionsOpened = connectionsOpened
            self.connectionsClosed = connectionsClosed
            self.log = log
        }

        /// Requests answered.
        public var requests: UInt64 { responsesByStatusClass.reduce(0, &+) }

        /// Connections open at the time of the snapshot.
        public var openConnections: UInt64 { connectionsOpened &- connectionsClosed }

        /// Responses whose status is `class`xx (1...5).
        public func responses(statusClass: Int) -> UInt64 {
            responsesByStatusClass[statusClass - 1]
        }

        /// Adds a shard's counts.
        mutating func merge(_ shard: MetricShard) {
            for index in 0..<5 {
                responsesByStatusClass[index] &+= shard.load(index)
            }
            requestBodyBytes &+= shard.load(MetricShard.requestBytesSlot)
            responseBodyBytes &+= shard.load(MetricShard.responseBytesSlot)
            for index in 0..<LatencyHistogram.bucketCount {
                latency.counts[index] &+= shard.load(MetricShard.latencyBase + index)
            }
            latency.sumNanoseconds &+= shard.load(MetricShard.latencySumSlot)
        }
    }

    struct State {
        /// Closed connections' shards, merged.
        var total = Snapshot()
        /// Open connections' shards.
        var live: [ObjectIdentifier: MetricShard] = [:]
        /// Access logs whose writer statistics are reported here.
        var logs: [ObjectIdentifier: LogCounters] = [:]
    }

    let state = Mutex(State())

    public init() {}

    /// The totals so far: closed connections plus the current counts of open ones.
    public func snapshot() -> Snapshot {
        let (snapshot, logs) = state.withLock { state -> (Snapshot, [LogCounters]) in
            var snapshot = state.total
            for shard in state.live.values { snapshot.merge(shard) }
            return (snapshot, Array(state.logs.values))
        }
        var result = snapshot
        for log in logs {
            let statistics = log.statistics
            result.log.linesLogged &+= statistics.linesLogged
            result.log.linesWritten &+= statistics.linesWritten
            result.log.linesDropped &+= statistics.linesDropped
            result.log.bytesWritten &+= statistics.bytesWritten
            result.log.writeErrors &+= statistics.writeErrors
        }
        return result
    }

    // MARK: Shards

    /// A connection opened: count it and start reading its shard on scrapes.
    func open(_ shard: MetricShard) {
        state.withLock { state in
            state.total.connectionsOpened &+= 1
            state.live[ObjectIdentifier(shard)] = shard
        }
    }

    /// A connection closed: fold its shard into the total.
    func close(_ shard: MetricShard) {
        state.withLock { state in
            guard state.live.removeValue(forKey: ObjectIdentifier(shard)) != nil else { return }
            state.total.merge(shard)
            state.total.connectionsClosed &+= 1
        }
    }

    /// Counts recorded outside any connection (a runner driven without connection observers)
    /// are merged on every scrape from this shard, which stays live.
    func attachShared(_ shard: MetricShard) {
        state.withLock { $0.live[ObjectIdentifier(shard)] = shard }
    }

    func attach(_ log: LogCounters) {
        state.withLock { $0.logs[ObjectIdentifier(log)] = log }
    }

    // MARK: Prometheus

    /// The snapshot in the Prometheus text exposition format (version 0.0.4).
    public func prometheusText() -> String {
        var buffer = ByteBuffer(capacity: 4096)
        writePrometheus(snapshot(), to: &buffer)
        return buffer.withReadableSpan { ASCII.string(from: $0) }
    }

    /// Appends `snapshot` in the Prometheus text format.
    public func writePrometheus(_ snapshot: Snapshot, to buffer: inout ByteBuffer) {
        func header(_ name: StaticString, _ type: StaticString, _ help: StaticString) {
            buffer.append("# HELP ")
            buffer.append(name)
            buffer.append(" ")
            buffer.append(help)
            buffer.append("\n# TYPE ")
            buffer.append(name)
            buffer.append(" ")
            buffer.append(type)
            buffer.append("\n")
        }
        func sample(_ name: StaticString, _ value: UInt64) {
            buffer.append(name)
            buffer.append(" ")
            buffer.append(decimal: value)
            buffer.append("\n")
        }

        header("sws_http_responses_total", "counter", "HTTP responses by status class.")
        for index in 0..<5 {
            buffer.append("sws_http_responses_total{class=\"")
            buffer.append(decimal: index + 1)
            buffer.append("xx\"} ")
            buffer.append(decimal: snapshot.responsesByStatusClass[index])
            buffer.append("\n")
        }
        header("sws_http_request_body_bytes_total", "counter", "Request body bytes declared by Content-Length.")
        sample("sws_http_request_body_bytes_total", snapshot.requestBodyBytes)
        header("sws_http_response_body_bytes_total", "counter", "Response body bytes of known length.")
        sample("sws_http_response_body_bytes_total", snapshot.responseBodyBytes)

        header("sws_http_request_duration_seconds", "histogram", "Time from a complete request head to the handler's response.")
        var cumulative: UInt64 = 0
        for bucket in 0..<LatencyHistogram.bucketCount {
            cumulative &+= snapshot.latency.counts[bucket]
            buffer.append("sws_http_request_duration_seconds_bucket{le=\"")
            if let bound = LatencyHistogram.upperBoundMicroseconds(bucket) {
                Self.appendSeconds(microseconds: bound, to: &buffer)
            } else {
                buffer.append("+Inf")
            }
            buffer.append("\"} ")
            buffer.append(decimal: cumulative)
            buffer.append("\n")
        }
        buffer.append("sws_http_request_duration_seconds_sum ")
        Self.appendSeconds(nanoseconds: snapshot.latency.sumNanoseconds, to: &buffer)
        buffer.append("\n")
        sample("sws_http_request_duration_seconds_count", cumulative)

        header("sws_connections_opened_total", "counter", "Connections opened.")
        sample("sws_connections_opened_total", snapshot.connectionsOpened)
        header("sws_connections_open", "gauge", "Connections open now.")
        sample("sws_connections_open", snapshot.openConnections)

        header("sws_access_log_lines_total", "counter", "Access log lines formatted.")
        sample("sws_access_log_lines_total", snapshot.log.linesLogged)
        header("sws_access_log_lines_written_total", "counter", "Access log lines written to the destination.")
        sample("sws_access_log_lines_written_total", snapshot.log.linesWritten)
        header("sws_access_log_lines_dropped_total", "counter", "Access log lines dropped because the writer fell behind.")
        sample("sws_access_log_lines_dropped_total", snapshot.log.linesDropped)
    }

    /// `microseconds` as decimal seconds without trailing zeros (`0.000001`, `1.048576`).
    static func appendSeconds(microseconds: UInt64, to buffer: inout ByteBuffer) {
        appendFixedPoint(microseconds, scale: 1_000_000, digits: 6, to: &buffer)
    }

    static func appendSeconds(nanoseconds: UInt64, to buffer: inout ByteBuffer) {
        appendFixedPoint(nanoseconds, scale: 1_000_000_000, digits: 9, to: &buffer)
    }

    static func appendFixedPoint(_ value: UInt64, scale: UInt64, digits: Int, to buffer: inout ByteBuffer) {
        buffer.append(decimal: value / scale)
        var fraction = value % scale
        guard fraction != 0 else { return }
        var width = digits
        while fraction % 10 == 0 {
            fraction /= 10
            width -= 1
        }
        buffer.append(".")
        let rendered = ASCII.decimalDigitCount(fraction)
        for _ in 0..<(width - rendered) { buffer.append(UInt8(ascii: "0")) }
        buffer.append(decimal: fraction)
    }
}

/// One connection's counters. Written by the connection's requests (relaxed atomic adds: on
/// HTTP/1.1 only one task writes, but HTTP/2 and HTTP/3 requests on one connection overlap),
/// read by scrapes and by the merge at close.
///
/// The counters are atomics in one allocation of ``count`` slots (`InlineArray` needs
/// macOS 26): status classes 0..<5, then the latency buckets, then the byte and duration sums.
final class MetricShard: @unchecked Sendable {
    // @unchecked: `slots` is written only through `Atomic` operations and freed in `deinit`.
    static let latencyBase = 5
    static let requestBytesSlot = latencyBase + LatencyHistogram.bucketCount
    static let responseBytesSlot = requestBytesSlot + 1
    static let latencySumSlot = responseBytesSlot + 1
    static let count = latencySumSlot + 1

    let slots: UnsafeMutablePointer<Atomic<UInt64>>

    init() {
        slots = .allocate(capacity: Self.count)
        for index in 0..<Self.count { (slots + index).initialize(to: Atomic(0)) }
    }

    deinit {
        slots.deinitialize(count: Self.count)
        slots.deallocate()
    }

    @inline(__always)
    func load(_ slot: Int) -> UInt64 {
        slots[slot].load(ordering: .relaxed)
    }

    @inline(__always)
    func add(_ value: UInt64, to slot: Int) {
        slots[slot].wrappingAdd(value, ordering: .relaxed)
    }

    @inline(__always)
    func record(status: Int, requestBytes: Int, responseBytes: Int, durationNanoseconds: UInt64?) {
        add(1, to: Swift.min(Swift.max(status / 100, 1), 5) &- 1)
        if requestBytes > 0 { add(UInt64(requestBytes), to: Self.requestBytesSlot) }
        if responseBytes > 0 { add(UInt64(responseBytes), to: Self.responseBytesSlot) }
        if let durationNanoseconds {
            add(1, to: Self.latencyBase &+ LatencyHistogram.bucket(nanoseconds: durationNanoseconds))
            add(durationNanoseconds, to: Self.latencySumSlot)
        }
    }
}
