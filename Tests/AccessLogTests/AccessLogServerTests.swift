import AccessLog
import HTTP1
import HTTPCore
import HTTPServer
import HTTPTestSupport
import Testing

// #0090: the access log registered in a real `Server` (in-memory listener, HTTP/1.1 runner):
// found as a connection observer, a start-time consumer and a component from one chain entry.

/// Sends `count` pipelined GETs on one connection (the last with `Connection: close`) and
/// returns how many responses came back.
private func exchange(_ listener: InMemoryListener, client: Int, count: Int) async throws -> Int {
    let connection = await listener.connect()
    var out = ByteBuffer()
    for index in 0..<count {
        let path = index % 5 == 4 ? "/missing" : "/c\(client)/r\(index)"
        out.append(contentsOf: Array("GET \(path) HTTP/1.1\r\nHost: memory\r\n".utf8))
        if index == count - 1 { out.append("Connection: close\r\n") }
        out.append("\r\n")
    }
    try await connection.send(out, endOfStream: false)
    var received = ByteBuffer()
    while try await connection.receive(into: &received, maxLength: 64 * 1024) > 0 {}
    await connection.close(.normal)
    let text = received.withReadableSpan { ASCII.string(from: $0) }
    return text.components(separatedBy: "HTTP/1.1 ").count - 1
}

@Suite struct AccessLogServerTests {
    /// Every request of every connection is written by the time `run()` returns: the
    /// writer is cancelled after the last connection closed and flushes what is left.
    @Test(.timeLimit(.minutes(1)))
    func flushesEveryLineOnShutdown() async throws {
        let capture = Capture()
        let metrics = AccessLogMetrics()
        // Large batches and a long interval: nothing reaches the writer before shutdown
        // except through the connections' close and the final drain.
        let log = AccessLog(format: .json, destination: capture.destination, metrics: metrics,
                            options: AccessLogOptions(batchSize: 1 << 20, flushInterval: .seconds(3600)))
        let listener = InMemoryListener(pendingLimit: 64)
        let server = Server(listeners: [listener], protocols: [HTTP1()]) {
            log
            Responder()
        }
        let clients = 8
        let requests = 25
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            _ = try await server.waitUntilRunning()
            let answered = try await withThrowingTaskGroup(of: Int.self) { clientsGroup in
                for client in 0..<clients {
                    clientsGroup.addTask { try await exchange(listener, client: client, count: requests) }
                }
                return try await clientsGroup.reduce(0, +)
            }
            #expect(answered == clients * requests)
            await server.shutdown()
            try await group.waitForAll()
        }

        let lines = capture.lines
        #expect(lines.count == clients * requests)
        #expect(log.statistics.linesDropped == 0)
        #expect(log.statistics.linesWritten == UInt64(clients * requests))
        for client in 0..<clients {
            #expect(lines.filter { $0.contains("\"path\":\"/c\(client)/") }.count == requests - requests / 5)
        }
        #expect(lines.filter { $0.contains(#""status":404"#) }.count == clients * (requests / 5))

        // Metrics merged across the closed connections.
        let snapshot = metrics.snapshot()
        #expect(snapshot.requests == UInt64(clients * requests))
        #expect(snapshot.responses(statusClass: 2) == UInt64(clients * (requests - requests / 5)))
        #expect(snapshot.responses(statusClass: 4) == UInt64(clients * (requests / 5)))
        #expect(snapshot.connectionsOpened == UInt64(clients))
        #expect(snapshot.connectionsClosed == UInt64(clients))
        // The server stamped every request's start time for the access log.
        #expect(snapshot.latency.count == UInt64(clients * requests))
        #expect(snapshot.log.linesWritten == UInt64(clients * requests))
    }

    /// `/metrics` behind configuration, scraped while a connection is open.
    @Test(.timeLimit(.minutes(1)))
    func scrapeThroughTheServer() async throws {
        let metrics = AccessLogMetrics()
        let listener = InMemoryListener()
        let server = Server(listeners: [listener], protocols: [HTTP1()]) {
            MetricsEndpoint(metrics: metrics)
            AccessLog(metrics: metrics)
            Responder()
        }
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            _ = try await server.waitUntilRunning()
            #expect(try await exchange(listener, client: 0, count: 3) == 3)

            let connection = await listener.connect()
            var request = ByteBuffer()
            request.append("GET /metrics HTTP/1.1\r\nHost: memory\r\nConnection: close\r\n\r\n")
            try await connection.send(request, endOfStream: false)
            var received = ByteBuffer()
            while try await connection.receive(into: &received, maxLength: 64 * 1024) > 0 {}
            await connection.close(.normal)
            let text = received.withReadableSpan { ASCII.string(from: $0) }
            #expect(text.hasPrefix("HTTP/1.1 200"))
            // The scrape itself is in front of the log, so it is not counted.
            #expect(text.contains(#"sws_http_responses_total{class="2xx"} 3"#))
            #expect(text.contains("sws_connections_opened_total 2"))

            await server.shutdown()
            try await group.waitForAll()
        }
        #expect(metrics.snapshot().requests == 3)
        #expect(metrics.snapshot().openConnections == 0)
    }
}
