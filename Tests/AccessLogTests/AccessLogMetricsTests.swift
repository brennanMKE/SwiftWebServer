import AccessLog
import HTTPCore
import Testing

// #0090: per-connection shards, merging, the latency histogram and the Prometheus text.

@Suite struct AccessLogMetricsTests {
    @Test func histogramBuckets() {
        // Bucket k holds (2^(k-1), 2^k] microseconds; bucket 0 holds [0, 1] µs.
        #expect(LatencyHistogram.bucket(nanoseconds: 0) == 0)
        #expect(LatencyHistogram.bucket(nanoseconds: 1_999) == 0)   // 1 µs after truncation
        #expect(LatencyHistogram.bucket(nanoseconds: 2_000) == 1)
        #expect(LatencyHistogram.bucket(nanoseconds: 3_000) == 2)
        #expect(LatencyHistogram.bucket(nanoseconds: 4_000) == 2)
        #expect(LatencyHistogram.bucket(nanoseconds: 5_000) == 3)
        #expect(LatencyHistogram.bucket(nanoseconds: 1_000_000) == 10)   // 1000 µs ≤ 1024
        #expect(LatencyHistogram.bucket(nanoseconds: 1_024_000) == 10)
        #expect(LatencyHistogram.bucket(nanoseconds: 1_025_000) == 11)
        #expect(LatencyHistogram.bucket(nanoseconds: 8_388_608_000) == 23)   // 2^23 µs
        #expect(LatencyHistogram.bucket(nanoseconds: 8_388_609_000) == 24)   // overflow
        #expect(LatencyHistogram.bucket(nanoseconds: .max) == 24)
        #expect(LatencyHistogram.upperBoundMicroseconds(0) == 1)
        #expect(LatencyHistogram.upperBoundMicroseconds(10) == 1024)
        #expect(LatencyHistogram.upperBoundMicroseconds(23) == 8_388_608)
        #expect(LatencyHistogram.upperBoundMicroseconds(24) == nil)
        // Every bound lands in its own bucket, one more microsecond in the next.
        for bucket in 0..<(LatencyHistogram.bucketCount - 1) {
            let bound = LatencyHistogram.upperBoundMicroseconds(bucket)!
            #expect(LatencyHistogram.bucket(nanoseconds: bound * 1_000) == bucket)
            #expect(LatencyHistogram.bucket(nanoseconds: (bound + 1) * 1_000) == bucket + 1)
        }

        var histogram = LatencyHistogram()
        histogram.record(nanoseconds: 500)
        histogram.record(nanoseconds: 3_000)
        var other = LatencyHistogram()
        other.record(nanoseconds: 3_500)
        histogram.merge(other)
        #expect(histogram.count == 3)
        #expect(histogram.counts[0] == 1)
        #expect(histogram.counts[2] == 2)
        #expect(histogram.sumNanoseconds == 7_000)
    }

    /// Shards of open connections are read on scrape; closed ones are merged into the total.
    @Test func mergesAcrossConnections() async throws {
        let metrics = AccessLogMetrics()
        let log = AccessLog(metrics: metrics)
        let first = openConnection(log)
        let second = openConnection(log)
        for _ in 0..<3 { try await perform(TestRequest("/"), through: log, on: first) }
        try await perform(TestRequest("/missing"), through: log, on: second)
        try await perform(TestRequest(.post, "/", headers: [("Content-Length", "0")]), through: log, on: second,
                       to: Responder(status: .internalServerError))

        var snapshot = metrics.snapshot()
        #expect(snapshot.requests == 5)
        #expect(snapshot.openConnections == 2)
        #expect(snapshot.responses(statusClass: 2) == 3)
        #expect(snapshot.responses(statusClass: 4) == 1)
        #expect(snapshot.responses(statusClass: 5) == 1)
        #expect(snapshot.responseBodyBytes == 5 * 14)
        #expect(snapshot.latency.count == 5)

        log.connectionDidEnd(first)
        snapshot = metrics.snapshot()
        #expect(snapshot.requests == 5)
        #expect(snapshot.connectionsOpened == 2)
        #expect(snapshot.connectionsClosed == 1)

        try await perform(TestRequest("/"), through: log, on: second)
        log.connectionDidEnd(second)
        // Ending a connection twice merges it once.
        log.connectionDidEnd(second)
        snapshot = metrics.snapshot()
        #expect(snapshot.requests == 6)
        #expect(snapshot.openConnections == 0)
        #expect(snapshot.responses(statusClass: 2) == 4)
        #expect(snapshot.latency.count == 6)
        #expect(snapshot.latency.sumNanoseconds > 0)
    }

    /// Requests without per-connection state count too (through the log's shared shard).
    @Test func countsRequestsWithoutConnectionState() async throws {
        let metrics = AccessLogMetrics()
        let log = AccessLog(metrics: metrics)
        _ = try await log.handle(TestRequest("/").request, context: RequestContext(), next: Responder())
        #expect(metrics.snapshot().requests == 1)
        // No start time stamped: no latency sample.
        #expect(metrics.snapshot().latency.count == 0)
    }

    @Test func prometheusText() {
        let metrics = AccessLogMetrics()
        var latency = LatencyHistogram()
        latency.record(nanoseconds: 800)        // bucket 0
        latency.record(nanoseconds: 700_000)    // 700 µs: bucket 10
        var snapshot = AccessLogMetrics.Snapshot(
            responsesByStatusClass: [0, 2, 0, 1, 0], requestBodyBytes: 10, responseBodyBytes: 42,
            latency: latency, connectionsOpened: 3, connectionsClosed: 1)
        snapshot.log.linesDropped = 7
        var buffer = ByteBuffer()
        metrics.writePrometheus(snapshot, to: &buffer)
        let text = buffer.withReadableSpan { ASCII.string(from: $0) }
        let lines = text.split(separator: "\n").map(String.init)

        #expect(text.hasSuffix("\n"))
        #expect(lines.contains("# TYPE sws_http_responses_total counter"))
        #expect(lines.contains(#"sws_http_responses_total{class="1xx"} 0"#))
        #expect(lines.contains(#"sws_http_responses_total{class="2xx"} 2"#))
        #expect(lines.contains(#"sws_http_responses_total{class="4xx"} 1"#))
        #expect(lines.contains("sws_http_request_body_bytes_total 10"))
        #expect(lines.contains("sws_http_response_body_bytes_total 42"))
        #expect(lines.contains("# TYPE sws_http_request_duration_seconds histogram"))
        #expect(lines.contains(#"sws_http_request_duration_seconds_bucket{le="0.000001"} 1"#))
        #expect(lines.contains(#"sws_http_request_duration_seconds_bucket{le="0.000512"} 1"#))
        #expect(lines.contains(#"sws_http_request_duration_seconds_bucket{le="0.001024"} 2"#))
        #expect(lines.contains(#"sws_http_request_duration_seconds_bucket{le="8.388608"} 2"#))
        #expect(lines.contains(#"sws_http_request_duration_seconds_bucket{le="+Inf"} 2"#))
        #expect(lines.contains("sws_http_request_duration_seconds_sum 0.0007008"))
        #expect(lines.contains("sws_http_request_duration_seconds_count 2"))
        #expect(lines.contains("sws_connections_opened_total 3"))
        #expect(lines.contains("sws_connections_open 2"))
        #expect(lines.contains("sws_access_log_lines_dropped_total 7"))

        // Exposition format 0.0.4: comments, or `name{labels} value`; buckets cumulative and
        // in increasing `le` order; every metric family typed before its samples.
        var typed: Set<String> = []
        var lastBucket: (le: Double, count: UInt64)?
        for line in lines {
            if line.hasPrefix("# TYPE ") {
                typed.insert(String(line.split(separator: " ")[2]))
                continue
            }
            if line.hasPrefix("# HELP ") { continue }
            guard let match = line.wholeMatch(of: /([a-z_]+)(\{[a-z]+="[^"]*"\})? ([0-9.]+)/) else {
                Issue.record("not a sample line: \(line)")
                continue
            }
            let name = String(match.1)
            let family = ["_bucket", "_sum", "_count"].reduce(name) { name, suffix in
                name.hasSuffix(suffix) && typed.contains(String(name.dropLast(suffix.count)))
                    ? String(name.dropLast(suffix.count)) : name
            }
            #expect(typed.contains(family), "\(name) sampled before its TYPE")
            if name.hasSuffix("_bucket"), let labels = match.2 {
                let le = labels.contains("+Inf") ? Double.infinity
                    : Double(labels.split(separator: "\"")[1])!
                let count = UInt64(match.3)!
                if let lastBucket {
                    #expect(le > lastBucket.le)
                    #expect(count >= lastBucket.count)
                }
                lastBucket = (le, count)
            }
        }
        #expect(lastBucket?.le == .infinity)
    }

    @Test func metricsEndpointServesPrometheusText() async throws {
        let metrics = AccessLogMetrics()
        let log = AccessLog(metrics: metrics)
        let connection = openConnection(log)
        try await perform(TestRequest("/"), through: log, on: connection)

        let endpoint = MetricsEndpoint(metrics: metrics)
        let scrape = try await endpoint.handle(TestRequest("/metrics").request, context: RequestContext(), next: Responder())
        #expect(scrape.status.code == 200)
        #expect(scrape.headers.firstValueString(for: .contentType) == "text/plain; version=0.0.4; charset=utf-8")
        guard case .bytes(let body) = scrape.body else {
            Issue.record("expected a bytes body")
            return
        }
        let text = body.withReadableSpan { ASCII.string(from: $0) }
        #expect(text.contains(#"sws_http_responses_total{class="2xx"} 1"#))
        #expect(text == metrics.prometheusText())

        // Other paths and methods pass through.
        let other = try await endpoint.handle(TestRequest("/metricsx").request, context: RequestContext(), next: Responder())
        #expect(other.headers.firstValueString(for: .contentType) == nil)
        let post = try await endpoint.handle(TestRequest(.post, "/metrics").request, context: RequestContext(),
                                             next: Responder(status: .accepted))
        #expect(post.status.code == 202)
    }
}
