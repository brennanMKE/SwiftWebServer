public import HTTPCore
import Synchronization

/// A request stream after an extended CONNECT was answered `2xx`, as the tunnel's byte stream
/// (RFC 9220 §3, #0111): DATA payloads the body reader queued in ``H3BodyChannel`` come out of
/// ``receive(into:maxLength:)``; each ``send(_:endOfStream:)`` is one DATA frame through the
/// response sink (send budget and deadline), its end of stream our FIN.
///
/// | Tunnel side | Request stream |
/// |---|---|
/// | receive returns 0 | the peer's FIN |
/// | receive throws `connectionReset` | the peer reset the stream (or sent STOP_SENDING) |
/// | `send(_, endOfStream: true)`, `close(.normal)`, `close(.shutdown)` | FIN |
/// | `close(.abort)`, `close(.timeout)`, `close(.protocolError)` | RESET_STREAM and STOP_SENDING `H3_REQUEST_CANCELLED` |
final class H3TunnelTransport<Stream: ByteStreamTransport & ResettableStream>: ByteStreamTransport {
    enum Ending: Sendable {
        /// FIN was sent (or is sent now).
        case finished
        /// The tunnel reset the stream.
        case reset
        /// Sending failed (the peer reset the stream, or the connection is closing).
        case failed
    }

    struct State {
        /// DATA payload taken from the channel but not yet returned.
        var pending = ByteBuffer()
        var finSent = false
        var reset = false
        var sendFailed = false
        var closed = false
    }

    let sink: H3ResponseSink<Stream>
    let stream: Stream
    let channel: H3BodyChannel
    private let state = Mutex(State())

    init(sink: H3ResponseSink<Stream>, stream: Stream, channel: H3BodyChannel) {
        self.sink = sink
        self.stream = stream
        self.channel = channel
    }

    var info: ConnectionInfo { stream.info }

    func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        precondition(maxLength > 0, "maxLength must be positive")
        if let taken = takePending(into: &buffer, maxLength: maxLength) { return taken }
        if state.withLock({ $0.closed }) { throw TransportError.closed }
        guard let chunk = await channel.queue.next() else {
            if state.withLock({ $0.closed }) { throw TransportError.closed }
            if let failure = channel.failure {
                throw (failure as? TransportError) == .connectionReset ? TransportError.connectionReset : TransportError.closed
            }
            try Task.checkCancellation()
            return 0
        }
        state.withLock { $0.pending = chunk }
        return takePending(into: &buffer, maxLength: maxLength) ?? 0
    }

    /// Moves up to `maxLength` pending bytes into `buffer`; `nil` when none are pending.
    private func takePending(into buffer: inout ByteBuffer, maxLength: Int) -> Int? {
        state.withLock { state -> Int? in
            guard state.pending.readableBytes > 0 else { return nil }
            let count = min(maxLength, state.pending.readableBytes)
            buffer.append(ByteView(offset: state.pending.readerIndex, length: count), from: state.pending)
            state.pending.moveReaderIndex(forwardBy: count)
            return count
        }
    }

    func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws {
        let refused = state.withLock { state -> TransportError? in
            if state.closed || state.reset { return .closed }
            if state.finSent { return .outputShutdown }
            if endOfStream { state.finSent = true }
            return nil
        }
        if let refused { throw refused }
        var frame = ByteBuffer()
        if bytes.readableBytes > 0 {
            var header = ByteBufferSink(buffer: ByteBuffer(capacity: bytes.readableBytes + 9))
            try H3FrameEncoder.encodeDataHeader(length: UInt64(bytes.readableBytes), into: &header)
            frame = header.buffer
            frame.append(bytes)
        }
        do {
            try await sink.send(frame, endOfStream: endOfStream)
        } catch {
            state.withLock { $0.sendFailed = true }
            throw error
        }
    }

    func sendFile(_ region: FileRegion) async throws {
        try await sendFileByReading(region, chunkSize: FileRegion.defaultChunkSize)
    }

    func close(_ reason: CloseReason) async {
        let (finish, reset) = state.withLock { state -> (Bool, Bool) in
            guard !state.closed else { return (false, false) }
            state.closed = true
            let abortive = reason == .abort || reason == .timeout || reason == .protocolError
            if abortive && !state.reset {
                state.reset = true
                return (false, true)
            }
            let finish = !state.finSent && !state.reset && !state.sendFailed
            state.finSent = true
            return (finish, false)
        }
        if reset {
            await stream.reset(applicationError: HTTP3Error.requestCancelled.rawValue)
            await stream.stopSending(applicationError: HTTP3Error.requestCancelled.rawValue)
        } else if finish {
            do {
                try await sink.send(ByteBuffer(), endOfStream: true)
            } catch {
                state.withLock { $0.sendFailed = true }
            }
        }
        // Wake a receive waiting for DATA.
        channel.queue.finish()
    }

    /// After the tunnel closure returned: sends FIN if it did not end the stream, and reports
    /// how the stream ended.
    func finish() async -> Ending {
        await close(.normal)
        return state.withLock { state in
            if state.reset { return .reset }
            if state.sendFailed { return .failed }
            return .finished
        }
    }
}
