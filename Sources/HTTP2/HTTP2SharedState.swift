public import HTTPCore

/// The frames waiting for the connection's single writer (RFC 9113 §5, docs/ROADMAP.md §5.4).
///
/// Two lanes of encoded frames, each one `ByteBuffer`:
/// - **priority**: PING ACK and connection WINDOW_UPDATE, which carry no ordering constraint
///   with other frames and should not wait behind DATA (#0050);
/// - **ordered**: everything else (our SETTINGS, SETTINGS ACK, HEADERS + CONTINUATION, DATA,
///   RST_STREAM, GOAWAY) in exactly the order it was enqueued. HPACK blocks and the SETTINGS
///   ACK that changes the peer's table size must reach the wire in encoding order.
///
/// The writer takes both lanes at once (priority first, except in the first batch, which
/// starts with the server's SETTINGS) and sends them with one `send`, so everything queued
/// while a send was in progress goes out as one batch.
///
/// Bounds: stream writers (HEADERS, DATA) may enqueue only while the ordered lane holds fewer
/// than ``capacity`` bytes, so the queue holds at most `capacity` plus one frame; they wait
/// otherwise. Control frames the reader produces in reply to the peer never wait (the reader
/// must not block on the writer) but are counted: more than ``maxControlFrames`` queued and
/// not yet written is a flood (#0056).
struct HTTP2OutboundQueue: Sendable {
    let capacity: Int
    let maxControlFrames: Int
    var priority = ByteBuffer()
    var ordered = ByteBuffer()
    /// Reply control frames queued since the writer last took a batch.
    var controlFrames = 0
    /// Set when nothing more will be enqueued: the writer sends what is left, then closes the
    /// transport with this reason.
    var closeReason: CloseReason?
    /// Batches taken and bytes taken, for tests and metrics.
    var batches = 0
    var bytesTaken = 0

    init(capacity: Int, maxControlFrames: Int) {
        self.capacity = capacity
        self.maxControlFrames = maxControlFrames
    }

    var isEmpty: Bool { priority.readableBytes == 0 && ordered.readableBytes == 0 }

    /// Whether a stream writer may enqueue now.
    var hasSpace: Bool { ordered.readableBytes < capacity }

    /// Takes everything queued, priority lane first. `nil` when empty.
    mutating func takeBatch() -> ByteBuffer? {
        guard !isEmpty else { return nil }
        var batch: ByteBuffer
        if ordered.readableBytes == 0 {
            batch = priority
        } else if priority.readableBytes == 0 {
            batch = ordered
        } else if batches == 0 {
            // The first batch starts with our SETTINGS, which must be the first frame (§3.4).
            batch = ordered
            batch.append(priority)
        } else {
            batch = priority
            batch.append(ordered)
        }
        priority = ByteBuffer()
        ordered = ByteBuffer()
        controlFrames = 0
        batches += 1
        bytesTaken += batch.readableBytes
        return batch
    }
}

/// Continuations to resume once the lock is released (ROADMAP §5.4: never inside the lock),
/// and request bodies to end there (ending one resumes its reader and returns credit).
struct HTTP2Wakeups: Sendable {
    var writer: CheckedContinuation<Void, Never>?
    var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    /// Bodies of streams that were reset.
    var resetBodies: [HTTP2BodyChannel] = []
    /// PING waiters and whether their ACK arrived.
    var pings: [(CheckedContinuation<Bool, Never>, Bool)] = []

    init() {}

    func resume() {
        writer?.resume()
        for waiter in waiters.values { waiter.resume() }
        for (waiter, acknowledged) in pings { waiter.resume(returning: acknowledged) }
        for body in resetBodies { body.fail(TransportError.connectionReset) }
    }
}

/// Everything about an HTTP/2 connection that the reader, the writer, the timers and the stream
/// tasks share, kept in one `Mutex` (docs/ROADMAP.md §5.4: not an actor).
///
/// Every method here runs inside the critical section and never suspends. A state change and
/// the frames it produces happen together: in particular a response head is HPACK-encoded and
/// enqueued in one step, so the encoder's dynamic table follows wire order and a block's
/// HEADERS and CONTINUATION frames are contiguous. Continuations to resume are returned as
/// ``HTTP2Wakeups``.
struct HTTP2SharedState: Sendable {
    var machine: HTTP2Connection
    var encoder: HTTP2ResponseHeadEncoder
    var outbound: HTTP2OutboundQueue
    /// The writer, when it waits for frames.
    var writer: CheckedContinuation<Void, Never>?
    /// Stream writers waiting for queue space or flow-control window, by waiter ID.
    var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    /// Bumped whenever a waiter could make progress (a batch was taken, a window changed, the
    /// connection is closing). A waiter that saw an older value retries instead of waiting.
    var generation: UInt64 = 0
    var nextWaiterID: UInt64 = 0
    /// Streams whose handler task is running.
    var activeStreams = 0
    /// The graceful GOAWAY was sent: close once the last stream finishes.
    var draining = false
    /// Request bodies of streams whose handler runs and whose peer may still send DATA
    /// (#0048). The reader adds and completes them; a reset or the end of the handler removes
    /// them.
    var bodies: [UInt32: HTTP2BodyChannel] = [:]
    /// Tasks waiting for the ACK of our PING, by opaque data (#0050).
    var pingWaiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    /// The opaque data of the last PING sent.
    var lastPingData: UInt64 = 0x5357_5300_0000_0000

    init(configuration: HTTP2Configuration) {
        machine = HTTP2Connection(configuration: configuration.connection)
        encoder = HTTP2ResponseHeadEncoder(tableCapacity: configuration.responseHeaderTableSize)
        outbound = HTTP2OutboundQueue(
            capacity: configuration.outboundQueueSize, maxControlFrames: configuration.maxQueuedControlFrames)
    }

    /// Whether frames can still be enqueued.
    var isOpen: Bool { outbound.closeReason == nil }

    // MARK: Events

    /// Feeds `event` to the state machine and performs the frames its action calls for.
    /// Returns the action, for the parts only the caller can do (the reader applies local
    /// settings and dispatches streams; stream writers learn whether to send).
    mutating func handle(_ event: HTTP2Connection.Event, wakeups: inout HTTP2Wakeups) -> HTTP2Connection.Action {
        let action = machine.handle(event)
        if case .rstStream(let id, _) = event, let body = bodies.removeValue(forKey: id.rawValue) {
            // The peer reset the stream: its body ends and what is buffered is credited.
            wakeups.resetBodies.append(body)
        }
        switch action {
        case .none, .applyLocalSettings, .send, .sendData, .waitForWindow, .drop, .acceptTrailers:
            break

        case .acceptData(let increment):
            if let increment {
                HTTP2FrameEncoder.encodeWindowUpdate(streamID: .connection, increment: increment, into: &outbound.priority)
                if let flood = countControlFrame(wakeups: &wakeups) { return flood }
                wakeWriter(&wakeups)
            }

        case .dispatch:
            // Counted in the same critical section as the decision, so a graceful shutdown
            // never closes under a stream it already promised to serve (GOAWAY last-stream-ID).
            activeStreams += 1

        case .sendPreface(let settings, let increment):
            HTTP2FrameEncoder.encodeSettings(settings, into: &outbound.ordered)
            if let increment {
                HTTP2FrameEncoder.encodeWindowUpdate(streamID: .connection, increment: increment, into: &outbound.ordered)
            }
            wakeWriter(&wakeups)

        case .acknowledgeSettings(let headerTableSize):
            // The new table size reaches the encoder before the ACK is queued, and both before
            // any later response head: the next block starts with the size update (RFC 7541
            // §4.2), and every block before the ACK was encoded under the old size.
            if let headerTableSize { encoder.setPeerMaxTableSize(headerTableSize) }
            HTTP2FrameEncoder.encodeSettingsAck(into: &outbound.ordered)
            if let flood = countControlFrame(wakeups: &wakeups) { return flood }
            wakeWriter(&wakeups)
            wakeWaiters(&wakeups)  // INITIAL_WINDOW_SIZE may have grown the send windows.

        case .sendPingAck(let data):
            HTTP2FrameEncoder.encodePing(opaqueData: data, ack: true, into: &outbound.priority)
            if let flood = countControlFrame(wakeups: &wakeups) { return flood }
            wakeWriter(&wakeups)

        case .sendPing(let data):
            // Our own PING: ahead of DATA, so the round trip does not include queued responses.
            HTTP2FrameEncoder.encodePing(opaqueData: data, ack: false, into: &outbound.priority)
            wakeWriter(&wakeups)

        case .pingAcknowledged(let data):
            if let waiter = pingWaiters.removeValue(forKey: data) { wakeups.pings.append((waiter, true)) }

        case .sendWindowUpdate(let connectionIncrement, let id, let streamIncrement):
            // Neither has an ordering constraint with other frames: the priority lane.
            if let connectionIncrement {
                HTTP2FrameEncoder.encodeWindowUpdate(streamID: .connection, increment: connectionIncrement, into: &outbound.priority)
            }
            if let streamIncrement {
                HTTP2FrameEncoder.encodeWindowUpdate(streamID: id, increment: streamIncrement, into: &outbound.priority)
            }
            if let flood = countControlFrame(wakeups: &wakeups) { return flood }
            wakeWriter(&wakeups)

        case .resetStream(let id, let code, let increment):
            if let body = bodies.removeValue(forKey: id.rawValue) { wakeups.resetBodies.append(body) }
            HTTP2FrameEncoder.encodeRSTStream(streamID: id, code, into: &outbound.ordered)
            if let increment {
                HTTP2FrameEncoder.encodeWindowUpdate(streamID: .connection, increment: increment, into: &outbound.priority)
            }
            if let flood = countControlFrame(wakeups: &wakeups) { return flood }
            wakeWriter(&wakeups)
            wakeWaiters(&wakeups)

        case .windowChanged:
            wakeWaiters(&wakeups)

        case .goaway(let last, let error):
            HTTP2FrameEncoder.encodeGoaway(lastStreamID: last, error: error, into: &outbound.ordered)
            close(error.code == .settingsTimeout ? .timeout : .protocolError, wakeups: &wakeups)

        case .gracefulGoaway(let last):
            HTTP2FrameEncoder.encodeGoaway(
                lastStreamID: last, .noError, debugData: UnsafeRawBufferPointer(start: nil, count: 0),
                into: &outbound.ordered)
            draining = true
            wakeWriter(&wakeups)
            if activeStreams == 0 { close(.shutdown, wakeups: &wakeups) }
        }
        return action
    }

    /// Counts a reply control frame; past the limit the peer is flooding (#0056).
    private mutating func countControlFrame(wakeups: inout HTTP2Wakeups) -> HTTP2Connection.Action? {
        outbound.controlFrames += 1
        guard outbound.controlFrames > outbound.maxControlFrames else { return nil }
        return handle(.connectionError(.connection(.enhanceYourCalm, reason: "too many queued control frames")),
                      wakeups: &wakeups)
    }

    // MARK: Stream writers

    /// What a stream writer does after one attempt.
    enum StreamStep: Sendable, Equatable {
        /// The frame was enqueued; for DATA, `length` bytes of it.
        case sent(length: Int, endStream: Bool)
        /// Wait until ``generation`` moves past this value, then try again.
        case wait(generation: UInt64)
        /// The stream or connection is closed: stop writing the response.
        case dropped
    }

    /// Encodes and enqueues a response head, unless the queue is full.
    mutating func sendHeaders(
        streamID: HTTP2StreamID, status: HTTPStatus, headers: HTTPFields, contentLength: Int?, endStream: Bool,
        wakeups: inout HTTP2Wakeups
    ) -> StreamStep {
        guard isOpen else { return .dropped }
        guard outbound.hasSpace else { return .wait(generation: generation) }
        switch handle(.sendHeaders(streamID: streamID, endStream: endStream), wakeups: &wakeups) {
        case .send:
            encoder.encode(
                streamID: streamID, status: status, headers: headers, contentLength: contentLength,
                endStream: endStream, maxFrameSize: machine.peerMaxFrameSize, into: &outbound.ordered)
            wakeWriter(&wakeups)
            return .sent(length: 0, endStream: endStream)
        default:
            return .dropped
        }
    }

    /// Enqueues one DATA frame with as many bytes of `bytes` as the windows and the peer's
    /// MAX_FRAME_SIZE allow (all of them, with END_STREAM when `endStream`).
    mutating func sendData(
        streamID: HTTP2StreamID, bytes: borrowing ByteBuffer, endStream: Bool, wakeups: inout HTTP2Wakeups
    ) -> StreamStep {
        guard isOpen else { return .dropped }
        guard outbound.hasSpace else { return .wait(generation: generation) }
        switch handle(.sendData(streamID: streamID, length: bytes.readableBytes, endStream: endStream), wakeups: &wakeups) {
        case .sendData(let length, let ends):
            HTTP2FrameEncoder.encodeDataHeader(streamID: streamID, dataLength: length, endStream: ends, into: &outbound.ordered)
            if length > 0 {
                outbound.ordered.append(ByteView(offset: bytes.readerIndex, length: length), from: bytes)
            }
            wakeWriter(&wakeups)
            return .sent(length: length, endStream: ends)
        case .waitForWindow:
            return .wait(generation: generation)
        default:
            return .dropped
        }
    }

    // MARK: Writer

    /// What the writer does next.
    enum WriterStep: Sendable {
        case send(ByteBuffer)
        case close(CloseReason)
        case wait
    }

    /// Takes the next batch for the writer, or tells it to close or wait.
    mutating func nextWriterStep(wakeups: inout HTTP2Wakeups) -> WriterStep {
        if let batch = outbound.takeBatch() {
            wakeWaiters(&wakeups)  // Queue space for stream writers.
            return .send(batch)
        }
        if let reason = outbound.closeReason { return .close(reason) }
        return .wait
    }

    /// Parks the writer until a frame is enqueued or the queue closes. Returns false (and keeps
    /// nothing) when there is already something to do.
    mutating func registerWriter(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        guard outbound.isEmpty && outbound.closeReason == nil else { return false }
        writer = continuation
        return true
    }

    // MARK: Lifecycle

    /// Stops accepting frames; the writer sends what is queued and closes with `reason`.
    /// The first reason wins.
    mutating func close(_ reason: CloseReason, wakeups: inout HTTP2Wakeups) {
        if outbound.closeReason == nil { outbound.closeReason = reason }
        wakeWriter(&wakeups)
        wakeWaiters(&wakeups)
        failPings(&wakeups)
    }

    /// No ACK can arrive any more: every PING waiter gets `false`.
    mutating func failPings(_ wakeups: inout HTTP2Wakeups) {
        for waiter in pingWaiters.values { wakeups.pings.append((waiter, false)) }
        pingWaiters.removeAll()
    }

    /// The writer's send failed: drop everything queued and stop every writer.
    mutating func writerFailed(wakeups: inout HTTP2Wakeups) {
        outbound.priority = ByteBuffer()
        outbound.ordered = ByteBuffer()
        outbound.closeReason = .abort
        wakeWaiters(&wakeups)
        failPings(&wakeups)
    }

    /// A stream task ended. Resets the stream if the peer is still sending, and finishes a
    /// graceful drain after the last stream.
    mutating func streamEnded(_ streamID: HTTP2StreamID, wakeups: inout HTTP2Wakeups) {
        activeStreams -= 1
        // DATA that still arrives has no reader: the reader credits it at once.
        bodies.removeValue(forKey: streamID.rawValue)
        if isOpen { _ = handle(.responseFinished(streamID: streamID), wakeups: &wakeups) }
        if draining && activeStreams == 0 { close(.shutdown, wakeups: &wakeups) }
    }

    // MARK: Waiters

    mutating func wakeWriter(_ wakeups: inout HTTP2Wakeups) {
        if let writer {
            wakeups.writer = writer
            self.writer = nil
        }
    }

    mutating func wakeWaiters(_ wakeups: inout HTTP2Wakeups) {
        generation &+= 1
        guard !waiters.isEmpty else { return }
        if wakeups.waiters.isEmpty {
            wakeups.waiters = waiters
        } else {
            for (id, waiter) in waiters { wakeups.waiters[id] = waiter }
        }
        waiters = [:]
    }
}
