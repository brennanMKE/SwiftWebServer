import AccessLog
import Foundation
import HTTPCore
import Testing

// #0090: batching, drop-on-full, and the writer's destinations.

@Suite struct AccessLogWriterTests {
    /// With a full queue a batch is dropped and its lines counted; the request never waits.
    @Test(.timeLimit(.minutes(1)))
    func dropsAndCountsWhenTheQueueIsFull() async throws {
        let capture = Capture()
        // Every line is a batch; the queue holds two.
        let log = AccessLog(format: .common, destination: capture.destination,
                            options: AccessLogOptions(batchSize: 1, queueCapacity: 2))
        let connection = openConnection(log)
        for index in 0..<5 { try await perform(TestRequest("/\(index)"), through: log, on: connection) }
        #expect(log.statistics.linesLogged == 5)
        #expect(log.statistics.linesDropped == 3)
        log.connectionDidEnd(connection)
        try await drain(log)
        #expect(capture.lines.count == 2)
        #expect(capture.lines[0].contains("GET /0 "))
        #expect(capture.lines[1].contains("GET /1 "))
        #expect(log.statistics.linesWritten == 2)
        #expect(log.statistics.linesDropped == 3)
    }

    /// Lines fill a connection's buffer up to the batch size before going to the writer.
    @Test(.timeLimit(.minutes(1)))
    func batchesByBytes() async throws {
        let capture = Capture()
        let log = AccessLog(format: .common, destination: capture.destination,
                            options: AccessLogOptions(batchSize: 1024, queueCapacity: 64))
        let connection = openConnection(log)
        for _ in 0..<100 { try await perform(TestRequest("/0123456789"), through: log, on: connection) }
        log.connectionDidEnd(connection)
        try await drain(log)
        let batches = capture.batches.withLock { $0 }
        #expect(capture.lines.count == 100)
        // ~80-byte lines in 1 KiB batches, then the leftover at close.
        #expect(batches.count > 1 && batches.count < 20, "\(batches.count) batches")
        for batch in batches { #expect(batch.last == 0x0A) }
    }

    /// The periodic collection hands over lines an idle connection buffered.
    @Test(.timeLimit(.minutes(1)))
    func flushIntervalCollectsIdleConnections() async throws {
        let capture = Capture()
        let log = AccessLog(format: .common, destination: capture.destination,
                            options: AccessLogOptions(flushInterval: .milliseconds(20)))
        let handle = ServerHandle(localAddresses: [], draining: ShutdownSignal()) {}
        try await withThrowingTaskGroup { group in
            group.addTask { try await log.run(server: handle) }
            let connection = openConnection(log)
            try await perform(TestRequest("/idle"), through: log, on: connection)
            let deadline = ContinuousClock.now + .seconds(10)
            while capture.lines.isEmpty && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(capture.lines.count == 1)
            group.cancelAll()
            try await group.waitForAll()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitFlushHandsLinesToTheWriter() async throws {
        let capture = Capture()
        let log = AccessLog(format: .common, destination: capture.destination,
                            options: AccessLogOptions(flushInterval: .seconds(3600)))
        let handle = ServerHandle(localAddresses: [], draining: ShutdownSignal()) {}
        try await withThrowingTaskGroup { group in
            group.addTask { try await log.run(server: handle) }
            let connection = openConnection(log)
            try await perform(TestRequest("/now"), through: log, on: connection)
            log.flush()
            let deadline = ContinuousClock.now + .seconds(10)
            while capture.lines.isEmpty && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(capture.lines.count == 1)
            group.cancelAll()
            try await group.waitForAll()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func appendsToAFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "sws-accesslog-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "access.log").path
        try Data("existing line\n".utf8).write(to: URL(fileURLWithPath: path))

        let log = AccessLog(format: .json, destination: .file(path: path))
        let connection = openConnection(log)
        for _ in 0..<3 { try await perform(TestRequest("/f"), through: log, on: connection) }
        log.connectionDidEnd(connection)
        try await drain(log)

        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[0] == "existing line")
        for line in lines.dropFirst() {
            #expect(try JSONSerialization.jsonObject(with: Data(line.utf8)) is [String: Any])
        }
        #expect(log.statistics.bytesWritten > 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func unopenableFileThrows() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "sws-missing-\(UUID().uuidString)/access.log").path
        let log = AccessLog(destination: .file(path: path))
        await #expect(throws: AccessLogError.self) { try await drain(log) }
    }

    /// Metrics only: no lines, and `run` returns at once.
    @Test(.timeLimit(.minutes(1)))
    func metricsOnlyLogsNothing() async throws {
        let metrics = AccessLogMetrics()
        let log = AccessLog(metrics: metrics)
        let connection = openConnection(log)
        try await perform(TestRequest("/"), through: log, on: connection)
        log.connectionDidEnd(connection)
        try await drain(log)
        #expect(log.statistics.linesLogged == 0)
        #expect(metrics.snapshot().requests == 1)
    }
}
