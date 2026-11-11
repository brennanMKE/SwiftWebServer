public import HTTPCore
import Synchronization

/// Sends the bytes of a `.stream` response body for ``HTTP1``: the ``HTTPBodyWriter`` handed to
/// the stream's closure.
///
/// The runner sends the response head first, then runs the closure; every ``write(_:)`` is one
/// `transport.send`, which returns only once the transport accepted the bytes, so a writer
/// faster than the peer is slowed down instead of buffering (backpressure).
///
/// - ``Framing/contentLength(_:)``: bytes go out unframed and unchanged (no copy). Writing more
///   than the declared length throws ``HTTPBodyWriterError/lengthExceeded``; the runner checks
///   for a short body afterwards. Either way the response cannot be completed and the
///   connection is aborted.
/// - ``Framing/chunked``: each write is one chunk, framed in a reused scratch buffer.
/// - ``Framing/closeDelimited``: bytes go out unframed; the connection closes afterwards.
///
/// One writer belongs to one connection and is reused; a writer kept after its closure returned
/// throws ``HTTPBodyWriterError/closed``.
public final class HTTP1ResponseBodyWriter<Transport: ByteStreamTransport>: @unchecked Sendable {
    public enum Framing: Sendable, Hashable {
        case contentLength(Int)
        case chunked
        case closeDelimited
    }

    let transport: Transport
    let busy = Atomic<Bool>(false)
    var responseID: UInt64 = 0
    var active = false
    var framing = Framing.chunked
    /// Content bytes written for the current response.
    public private(set) var written = 0
    var scratch = ByteBuffer()
    var transportError: (any Error)?

    public init(transport: Transport) {
        self.transport = transport
    }

    /// Starts a response body and returns the writer for its closure.
    public func begin(_ framing: Framing) -> Handle {
        responseID &+= 1
        active = true
        written = 0
        transportError = nil
        self.framing = framing
        return Handle(writer: self, id: responseID)
    }

    /// Ends the current response body: later writes through its handle throw.
    public func end() {
        active = false
        scratch.clear()
    }

    /// True when a send failed: the connection must abort.
    public var transportFailed: Bool { transportError != nil }

    /// True when the body wrote exactly its declared length (always true without one).
    public var lengthMatches: Bool {
        if case .contentLength(let length) = framing { return written == length }
        return true
    }

    func write(_ bytes: ByteBuffer, id: UInt64) async throws {
        guard id == responseID && active else { throw HTTPBodyWriterError.closed }
        guard !bytes.isEmpty else { return }
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else {
            // Sends must not interleave; a concurrent write is a programming error.
            throw HTTPBodyWriterError.closed
        }
        defer { busy.store(false, ordering: .releasing) }
        let count = bytes.readableBytes
        do {
            switch framing {
            case .contentLength(let length):
                guard written &+ count <= length else { throw HTTPBodyWriterError.lengthExceeded }
                try await transport.send(bytes, endOfStream: false)
            case .closeDelimited:
                try await transport.send(bytes, endOfStream: false)
            case .chunked:
                scratch.clear()
                HTTP1ChunkedEncoder.appendChunk(bytes, into: &scratch)
                try await transport.send(scratch, endOfStream: false)
            }
        } catch let error as HTTPBodyWriterError {
            throw error
        } catch {
            transportError = error
            throw error
        }
        written &+= count
    }

    /// The writer of one response body.
    public struct Handle: HTTPBodyWriter {
        let writer: HTTP1ResponseBodyWriter<Transport>
        let id: UInt64

        public func write(_ bytes: ByteBuffer) async throws {
            try await writer.write(bytes, id: id)
        }
    }
}
