public import HTTPCore
import Synchronization

/// The stream of an extended CONNECT answered `2xx`, as the tunnel's byte stream (RFC 8441 §5,
/// #0067): DATA payloads the reader queued in the stream's ``HTTP2BodyChannel`` come out of
/// ``receive(into:maxLength:)``; each ``send(_:endOfStream:)`` becomes DATA frames through the
/// connection's outbound queue and flow control, its end of stream our END_STREAM.
///
/// Flow control holds both ways: receive window credit goes back only as the tunnel takes
/// bytes from the channel (at most one window is buffered there, plus one chunk here), and a
/// send waits for stream and connection window like a response body.
///
/// | Tunnel side | Stream |
/// |---|---|
/// | receive returns 0 | the peer's END_STREAM |
/// | receive or send throws `connectionReset` | the stream was reset (RST_STREAM either way) |
/// | `send(_, endOfStream: true)`, `close(.normal)`, `close(.shutdown)` | END_STREAM |
/// | `close(.abort)`, `close(.timeout)`, `close(.protocolError)` | `RST_STREAM(CANCEL)` |
final class HTTP2TunnelTransport<Transport: ByteStreamTransport, Handler: HTTPHandler>: ByteStreamTransport {
    enum Ending: Sendable, Equatable {
        /// END_STREAM was sent (or is sent now).
        case finished
        /// The tunnel reset the stream.
        case reset
        /// Sending failed: the stream was reset by the peer, or the connection is closing.
        case failed
    }

    struct State {
        /// DATA payload taken from the channel but not yet returned.
        var pending = ByteBuffer()
        var endSent = false
        var reset = false
        var sendFailed = false
        var closed = false
    }

    let driver: HTTP2ConnectionDriver<Transport, Handler>
    let streamID: HTTP2StreamID
    /// The stream's DATA; `nil` when the CONNECT's HEADERS ended the stream.
    let channel: HTTP2BodyChannel?
    private let state = Mutex(State())

    init(driver: HTTP2ConnectionDriver<Transport, Handler>, streamID: HTTP2StreamID, channel: HTTP2BodyChannel?) {
        self.driver = driver
        self.streamID = streamID
        self.channel = channel
    }

    var info: ConnectionInfo { driver.transport.info }

    func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        precondition(maxLength > 0, "maxLength must be positive")
        if let taken = takePending(into: &buffer, maxLength: maxLength) { return taken }
        if state.withLock({ $0.closed }) { throw TransportError.closed }
        guard let channel else { return 0 }
        let chunk: ByteBuffer?
        do {
            chunk = try await channel.nextChunk(request: channel.requestID)
        } catch let error as TransportError {
            if state.withLock({ $0.closed }) { throw TransportError.closed }
            throw error == .connectionReset ? TransportError.connectionReset : TransportError.closed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TransportError.closed
        }
        guard let chunk else { return 0 }
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
            if state.reset || state.sendFailed { return .connectionReset }
            if state.closed { return .closed }
            if state.endSent { return .outputShutdown }
            if endOfStream { state.endSent = true }
            return nil
        }
        if let refused { throw refused }
        if bytes.readableBytes == 0 && !endOfStream { return }
        let sent: Bool
        do {
            sent = try await driver.sendData(bytes, endStream: endOfStream, on: streamID)
        } catch {
            state.withLock { $0.sendFailed = true }
            throw error
        }
        guard sent else {
            state.withLock { $0.sendFailed = true }
            try Task.checkCancellation()
            throw TransportError.connectionReset
        }
    }

    func close(_ reason: CloseReason) async {
        let (finish, reset) = state.withLock { state -> (Bool, Bool) in
            guard !state.closed else { return (false, false) }
            state.closed = true
            let abortive = reason == .abort || reason == .timeout || reason == .protocolError
            if abortive && !state.reset && !state.sendFailed {
                state.reset = true
                return (false, true)
            }
            let finish = !state.endSent && !state.reset && !state.sendFailed
            state.endSent = true
            return (finish, false)
        }
        if reset {
            driver.handle(.sendReset(streamID: streamID, .cancel))
        } else if finish {
            do {
                if try await !driver.sendData(ByteBuffer(), endStream: true, on: streamID) {
                    state.withLock { $0.sendFailed = true }
                }
            } catch {
                state.withLock { $0.sendFailed = true }
            }
        }
        // Wake a receive waiting for DATA; what is still buffered is credited.
        channel?.fail(TransportError.closed)
    }

    /// After the tunnel closure returned: sends END_STREAM if it did not end the stream, and
    /// reports how the stream ended.
    func finish() async -> Ending {
        await close(.normal)
        return state.withLock { state in
            if state.reset { return .reset }
            if state.sendFailed { return .failed }
            return .finished
        }
    }
}

extension HTTPRequest {
    /// `:method CONNECT` with a `:protocol` (RFC 8441 §4).
    var isExtendedConnect: Bool { method == .connect && !connectProtocol.isEmpty }
}
