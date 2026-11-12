import HTTPCore
import Darwin
import os

/// The open destination of a running writer.
enum AccessLogSink {
    case descriptor(Int32, closeWhenDone: Bool)
    case logger(Logger)
    case discard
    case handler(@Sendable (ByteBuffer) -> Void)

    static func open(_ destination: AccessLogDestination) throws -> AccessLogSink {
        switch destination {
        case .file(let path):
            let fd = path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, mode_t(0o644)) }
            guard fd >= 0 else { throw AccessLogError(path: path, errno: errno) }
            return .descriptor(fd, closeWhenDone: true)
        case .standardOutput: return .descriptor(STDOUT_FILENO, closeWhenDone: false)
        case .standardError: return .descriptor(STDERR_FILENO, closeWhenDone: false)
        case .osLog(let subsystem, let category): return .logger(Logger(subsystem: subsystem, category: category))
        case .discard: return .discard
        case .handler(let handler): return .handler(handler)
        }
    }

    /// Writes one batch; returns false when the write failed.
    func write(_ batch: ByteBuffer) -> Bool {
        switch self {
        case .descriptor(let fd, _):
            return batch.withUnsafeReadableBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += written
                }
                return true
            }
        case .logger(let logger):
            batch.withReadableSpan { span in
                var start = 0
                for index in 0..<span.count where span[index] == UInt8(ascii: "\n") {
                    let line = ASCII.string(from: span.extracting(start..<index))
                    logger.info("\(line, privacy: .public)")
                    start = index + 1
                }
            }
            return true
        case .discard:
            return true
        case .handler(let handler):
            handler(batch)
            return true
        }
    }

    func close() {
        if case .descriptor(let fd, true) = self { _ = Darwin.close(fd) }
    }
}

extension AccessLogCore {
    /// The writer (``AccessLog/run(server:)``): writes batches as connections hand them over,
    /// collects what idle connections buffered every ``AccessLogOptions/flushInterval``, and
    /// when cancelled (the server cancels components after the last connection closed) writes
    /// everything still queued or buffered before returning.
    func runWriter() async throws {
        guard let destination else {
            return   // metrics only: nothing to write
        }
        let sink = try AccessLogSink.open(destination)
        defer { sink.close() }
        let interval = options.flushInterval
        await withDiscardingTaskGroup { group in
            group.addTask {
                while (try? await Task.sleep(for: interval)) != nil {
                    self.collect()
                }
            }
            // `next()` returns nil once this task is cancelled and the queue is empty.
            while let batch = await queue.next() {
                write(batch, to: sink)
                while let more = queue.tryNext() { write(more, to: sink) }
                // Let batches gather before waiting again: a busy server then wakes the writer
                // about once per `writerCoalescing` instead of once per batch (a wake-up is
                // paid on the request path that hands the batch over).
                if (try? await Task.sleep(for: Self.writerCoalescing)) == nil { break }
            }
            group.cancelAll()
        }
        // Shutting down: what is queued, then what connections (and the shared buffer) still
        // hold, written directly so a full queue drops nothing here.
        // Lines handed over after this are dropped and counted.
        queue.finish()
        while let batch = await queue.next() { write(batch, to: sink) }
        for batch in takeAll() {
            counters.linesLogged.wrappingAdd(UInt64(batch.lines), ordering: .relaxed)
            write(batch, to: sink)
        }
    }

    /// How long the writer lets batches gather after each burst.
    static let writerCoalescing: Duration = .milliseconds(1)

    /// Writes one batch, counts it and keeps its buffer for reuse.
    func write(_ batch: LogBatch, to sink: AccessLogSink) {
        defer { recycle(batch.bytes) }
        if sink.write(batch.bytes) {
            counters.linesWritten.wrappingAdd(UInt64(batch.lines), ordering: .relaxed)
            counters.bytesWritten.wrappingAdd(UInt64(batch.bytes.readableBytes), ordering: .relaxed)
        } else {
            counters.writeErrors.wrappingAdd(1, ordering: .relaxed)
            counters.linesDropped.wrappingAdd(UInt64(batch.lines), ordering: .relaxed)
        }
    }
}
