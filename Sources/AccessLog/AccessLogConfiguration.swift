public import HTTPCore

/// The line format of an ``AccessLog``.
public enum AccessLogFormat: Sendable, Hashable {
    /// NCSA Common Log Format:
    /// `127.0.0.1 - - [10/Oct/2026:13:55:36 +0000] "GET /index.html HTTP/1.1" 200 2326`
    case common
    /// NCSA Combined Log Format: Common plus the quoted `Referer` and `User-Agent`.
    case combined
    /// One JSON object per line (JSON Lines) with every recorded field:
    /// `{"time":"2026-10-10T13:55:36Z","remote":"127.0.0.1","protocol":"HTTP/1.1","method":"GET","path":"/","query":"","status":200,"bytes":2326,"duration_us":41,"referer":null,"user_agent":"curl/8.7.1"}`
    case json
}

/// Where an ``AccessLog`` writes its lines. The writer runs as a ``ServerComponent``, never on
/// the request path.
public enum AccessLogDestination: Sendable {
    /// A file opened with `O_APPEND` (created with mode 0644 if missing). Each batch is one
    /// `write`, so lines from other processes appending to the same file never interleave
    /// within a batch.
    case file(path: String)
    /// File descriptor 1.
    case standardOutput
    /// File descriptor 2.
    case standardError
    /// `os.Logger` at the `info` level, one entry per line (lines are public).
    case osLog(subsystem: String, category: String)
    /// Lines are formatted and handed to the writer, which discards them: the cost of an
    /// access log minus the I/O (benchmarks).
    case discard
    /// Each batch of complete lines (newline-terminated) is passed to `handler` on the
    /// writer's task (custom sinks, tests).
    case handler(@Sendable (ByteBuffer) -> Void)
}

/// Buffering and flushing of an ``AccessLog``.
public struct AccessLogOptions: Sendable {
    /// A connection hands its buffered lines to the writer once they reach this many bytes.
    public var batchSize: Int
    /// Batches the writer may have queued (memory is only used while they wait: 1024 batches
    /// of 8 KiB is at most 8 MiB). When the queue is full, a batch is dropped and its lines
    /// are counted in ``AccessLogStatistics/linesDropped``: the request path never waits for
    /// the writer. The writer drains the queue in bursts about once a millisecond, so the
    /// queue must hold a millisecond or so of lines at the peak rate.
    public var queueCapacity: Int
    /// How often the writer collects lines that idle connections have buffered, so a line
    /// reaches the destination within about this long of its request.
    public var flushInterval: Duration

    public init(batchSize: Int = 8 * 1024, queueCapacity: Int = 1024, flushInterval: Duration = .seconds(1)) {
        precondition(batchSize > 0, "AccessLogOptions.batchSize must be positive")
        precondition(queueCapacity > 0, "AccessLogOptions.queueCapacity must be positive")
        self.batchSize = batchSize
        self.queueCapacity = queueCapacity
        self.flushInterval = flushInterval
    }
}

/// Lines an ``AccessLog`` wrote and dropped since it was created.
public struct AccessLogStatistics: Sendable, Hashable {
    /// Lines handed toward the writer (written, queued or dropped). Counted per batch, so
    /// lines still buffered by a connection are not in it yet.
    public var linesLogged: UInt64
    /// Lines the writer wrote to the destination.
    public var linesWritten: UInt64
    /// Lines dropped because the writer's queue was full or the writer had stopped.
    public var linesDropped: UInt64
    /// Bytes the writer wrote.
    public var bytesWritten: UInt64
    /// Failed writes (their lines count as dropped).
    public var writeErrors: UInt64

    public init(linesLogged: UInt64 = 0, linesWritten: UInt64 = 0, linesDropped: UInt64 = 0,
                bytesWritten: UInt64 = 0, writeErrors: UInt64 = 0) {
        self.linesLogged = linesLogged
        self.linesWritten = linesWritten
        self.linesDropped = linesDropped
        self.bytesWritten = bytesWritten
        self.writeErrors = writeErrors
    }
}

/// Thrown by ``AccessLog/run(server:)`` when the destination cannot be opened; the server
/// then shuts down and `Server.run()` rethrows it.
public struct AccessLogError: Error, Sendable, Hashable, CustomStringConvertible {
    public var path: String
    public var errno: Int32

    public init(path: String, errno: Int32) {
        self.path = path
        self.errno = errno
    }

    public var description: String { "cannot open access log \(path) (errno \(errno))" }
}
