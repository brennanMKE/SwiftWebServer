/// The I/O boundary every protocol runs over (docs/ROADMAP.md §5.2).
///
/// Protocol code never touches sockets: HTTP/1.1, HTTP/2 and WebSockets run over a
/// ``ByteStreamTransport``; HTTP/3 runs over a ``MultiplexedTransport`` whose streams are
/// themselves byte streams. `NetworkTransport` adapts `NWConnection`; `HTTPTestSupport` provides
/// in-memory implementations so protocol logic is tested without sockets.

/// A bidirectional, demand-driven byte stream (a TCP or TLS connection, a QUIC stream, or an
/// in-memory pipe).
///
/// ## Demand
///
/// Bytes are read only when asked for: ``receive(into:maxLength:)`` performs the read, so a
/// connection that stops calling it applies backpressure to the peer. At most **one** receive
/// may be outstanding at a time; a second concurrent call is a programming error that
/// implementations report with ``TransportError/receiveAlreadyPending``. Callers also issue at
/// most one ``send(_:endOfStream:)`` at a time, so bytes are never interleaved.
///
/// ## Backpressure
///
/// ``send(_:endOfStream:)`` returns once the transport has *accepted* the bytes (copied them into
/// a bounded buffer or handed them to the kernel). It suspends while that buffer is full, so a
/// slow reader slows the writer instead of growing memory.
///
/// ## Cancellation
///
/// Cancelling the task that is suspended in `receive` or `send` makes the call throw
/// `CancellationError` promptly and leaves no continuation behind. A cancelled `send` may have
/// delivered a prefix of its bytes (as with a real socket); the stream is then in an undefined
/// position and should be closed.
///
/// ## Errors
///
/// Transport failures are thrown as ``TransportError``. Cancellation is `CancellationError`.
public protocol ByteStreamTransport: Sendable {
    /// Appends up to `maxLength` (> 0) bytes to `buffer`, suspending until at least one byte is
    /// available, and returns how many were appended.
    ///
    /// Returns `0` at end of stream: the peer finished sending (half-close or graceful close).
    /// End of stream is sticky; every later call also returns `0`.
    func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int

    /// Sends the readable bytes of `bytes`, then, if `endOfStream` is true, shuts down the
    /// sending direction (half-close: receiving continues to work).
    ///
    /// Returns once the transport has accepted the bytes. After `endOfStream` or ``close(_:)``,
    /// further sends throw ``TransportError/outputShutdown`` or ``TransportError/closed``.
    func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws

    /// Sends the bytes of a file region without loading the whole file.
    ///
    /// The default implementation (``ByteStreamTransport/sendFileByReading(_:chunkSize:)``) is a
    /// bounded `pread` loop over one reusable buffer. Adapters may override it with something
    /// cheaper (for example `sendfile`).
    func sendFile(_ region: FileRegion) async throws

    /// Closes both directions. Idempotent. A graceful reason flushes accepted bytes before the
    /// peer sees end of stream; ``CloseReason/abort`` discards them and resets the connection.
    /// A receive or send in progress on another task fails with ``TransportError/closed``.
    func close(_ reason: CloseReason) async

    /// Addresses and security properties of the connection. Constant for its lifetime.
    var info: ConnectionInfo { get }
}

/// A multiplexed connection (QUIC) carrying many independent byte streams
/// (docs/ROADMAP.md §5.2). Implementations: `NWConnectionGroup` in #0098, in-memory in #0099.
public protocol MultiplexedTransport: Sendable {
    /// One stream of the connection.
    associatedtype Stream: ByteStreamTransport & StreamIdentified
    /// Streams opened by the peer, in the order they arrive. Iteration ends when the connection
    /// closes; it throws if the connection fails.
    associatedtype Inbound: AsyncSequence<Stream, any Error>

    /// Streams opened by the peer (bidirectional request streams and unidirectional streams).
    var inboundStreams: Inbound { get }

    /// Opens a locally initiated unidirectional stream (HTTP/3 control and QPACK streams).
    func openUnidirectionalStream() async throws -> Stream

    /// Closes the whole connection with an application error code (for HTTP/3, an
    /// `H3_*` code; `H3_NO_ERROR` is `0x100`).
    func close(applicationError: UInt64) async
}

/// A stream with a transport-level identifier, such as a QUIC stream ID (RFC 9000 §2.1).
public protocol StreamIdentified {
    /// The stream's identifier. For QUIC, bit 0 is the initiator (0 = client) and bit 1 the
    /// directionality (0 = bidirectional).
    var streamID: UInt64 { get }
}

extension StreamIdentified {
    /// True when the stream ID marks a unidirectional QUIC stream (RFC 9000 §2.1).
    public var isUnidirectional: Bool { streamID & 0x2 != 0 }

    /// True when the stream ID marks a client-initiated QUIC stream (RFC 9000 §2.1).
    public var isClientInitiated: Bool { streamID & 0x1 == 0 }
}

/// Why a transport is being closed. Adapters use it to choose between a graceful close and a
/// reset, and observability records it.
public enum CloseReason: Sendable, Hashable {
    /// The conversation finished (for example `Connection: close`, or the peer's end of stream).
    case normal
    /// The connection was idle or a read/write deadline passed.
    case timeout
    /// The peer violated the protocol.
    case protocolError
    /// The server is draining or stopping.
    case shutdown
    /// Discard unsent bytes and reset the connection (TCP RST, QUIC stream reset).
    case abort

    /// True when accepted but undelivered bytes are discarded instead of flushed.
    public var isAbortive: Bool { self == .abort }
}

/// A host and port, rendered once per connection (not on the request path).
public struct TransportAddress: Sendable, Hashable, CustomStringConvertible {
    /// A numeric IP address (`127.0.0.1`, `::1`) or, for test transports, any name.
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// `host:port`, with IPv6 hosts bracketed (`[::1]:8080`).
    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

/// Addresses and security properties of a connection (docs/ROADMAP.md §5.2).
public struct ConnectionInfo: Sendable, Hashable {
    public var localAddress: TransportAddress?
    public var remoteAddress: TransportAddress?
    /// True for TLS (and QUIC) connections.
    public var isSecure: Bool
    /// The ALPN protocol agreed in the TLS handshake (`"h2"`, `"http/1.1"`, `"h3"`), or `nil`
    /// for cleartext connections or when the client offered none.
    public var negotiatedALPN: String?

    public init(
        localAddress: TransportAddress? = nil,
        remoteAddress: TransportAddress? = nil,
        isSecure: Bool = false,
        negotiatedALPN: String? = nil
    ) {
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.isSecure = isSecure
        self.negotiatedALPN = negotiatedALPN
    }
}

/// Errors thrown by ``ByteStreamTransport`` implementations.
public enum TransportError: Error, Sendable, Hashable {
    /// The transport was closed locally (``ByteStreamTransport/close(_:)``).
    case closed
    /// A send after the sending direction was shut down with `endOfStream`.
    case outputShutdown
    /// The peer reset the connection or stopped reading.
    case connectionReset
    /// A receive was started while another receive was outstanding.
    case receiveAlreadyPending
    /// A deadline passed.
    case timedOut
    /// Reading a ``FileRegion`` failed with `errno`.
    case fileReadFailed(errno: Int32)
    /// Opening or inspecting a file failed with `errno`.
    case fileOpenFailed(errno: Int32)
    /// The file ended before the ``FileRegion`` did (the file shrank).
    case unexpectedEndOfFile
    /// Any other platform failure, with its POSIX or framework error code.
    case failed(code: Int32)
}
