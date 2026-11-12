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
/// for their turn otherwise (``HTTP2SharedState`` "Fair waiting", #0054). Control frames the reader produces in reply to the peer never wait (the reader
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
    /// Stream writers whose turn came (#0054).
    var waiters: [CheckedContinuation<Void, Never>] = []
    /// Bodies of streams that were reset.
    var resetBodies: [HTTP2BodyChannel] = []
    /// PING waiters and whether their ACK arrived.
    var pings: [(CheckedContinuation<Bool, Never>, Bool)] = []
    /// Handler tasks of streams that were reset.
    var cancelledTasks: [HTTP2StreamTask] = []

    init() {}

    func resume() {
        writer?.resume()
        for waiter in waiters { waiter.resume() }
        for (waiter, acknowledged) in pings { waiter.resume(returning: acknowledged) }
        // The body fails first, so a handler reading it sees why rather than a cancellation.
        for body in resetBodies { body.fail(TransportError.connectionReset) }
        for task in cancelledTasks { task.cancel() }
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
    /// Stream writers waiting to send, by ticket (#0054). See "Fair waiting" below.
    var sendWaiters: [UInt64: SendWaiter] = [:]
    /// Tickets waiting for queue space or connection window, oldest first.
    var fairQueue: [UInt64] = []
    /// Tickets waiting for their own stream's send window, by stream.
    var streamWaiters: [UInt32: UInt64] = [:]
    /// The ticket whose turn it is: woken, and not yet back to try again.
    var granted: UInt64?
    var nextWaiterID: UInt64 = 0
    /// Streams whose handler task is running.
    var activeStreams = 0
    /// The final graceful GOAWAY was sent: close once the last stream finishes.
    var draining = false
    /// Since when no stream task has run, when ``HTTP2Configuration/idleTimeout`` is set
    /// (``tracksIdleTime``); `nil` while one runs.
    var idleSince: ContinuousClock.Instant?
    let tracksIdleTime: Bool
    /// Request bodies of streams whose handler runs and whose peer may still send DATA
    /// (#0048). The reader adds and completes them; a reset or the end of the handler removes
    /// them.
    var bodies: [UInt32: HTTP2BodyChannel] = [:]
    /// The handler task of every dispatched stream, until it ends (#0051): a reset cancels it.
    var tasks: [UInt32: HTTP2StreamTask] = [:]
    /// Tasks waiting for the ACK of our PING, by opaque data (#0050).
    var pingWaiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    /// The opaque data of the last PING sent.
    var lastPingData: UInt64 = 0x5357_5300_0000_0000

    init(configuration: HTTP2Configuration) {
        machine = HTTP2Connection(configuration: configuration.connection)
        encoder = HTTP2ResponseHeadEncoder(tableCapacity: configuration.responseHeaderTableSize)
        outbound = HTTP2OutboundQueue(
            capacity: configuration.outboundQueueSize, maxControlFrames: configuration.maxQueuedControlFrames)
        tracksIdleTime = configuration.idleTimeout != nil
        if tracksIdleTime { idleSince = .now }
        sendWaiters.reserveCapacity(configuration.maxConcurrentStreams)
        fairQueue.reserveCapacity(configuration.maxConcurrentStreams)
        streamWaiters.reserveCapacity(configuration.maxConcurrentStreams)
    }

    /// Whether frames can still be enqueued.
    var isOpen: Bool { outbound.closeReason == nil }

    // MARK: Events

    /// Feeds `event` to the state machine and performs the frames its action calls for.
    /// Returns the action, for the parts only the caller can do (the reader applies local
    /// settings and dispatches streams; stream writers learn whether to send).
    mutating func handle(_ event: HTTP2Connection.Event, wakeups: inout HTTP2Wakeups) -> HTTP2Connection.Action {
        let action = machine.handle(event)
        if case .rstStream(let id, _) = event {
            // The peer reset the stream: its body ends (what is buffered is credited) and its
            // handler is cancelled.
            if let body = bodies.removeValue(forKey: id.rawValue) { wakeups.resetBodies.append(body) }
            if let task = tasks[id.rawValue] { wakeups.cancelledTasks.append(task) }
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
            idleSince = nil

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
            // INITIAL_WINDOW_SIZE may have grown (or shrunk) every stream send window.
            wakeStreamWaiters(&wakeups)

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
            // The stream is over: its body ends and its handler, if still running, is cancelled.
            if let body = bodies.removeValue(forKey: id.rawValue) { wakeups.resetBodies.append(body) }
            if let task = tasks[id.rawValue] { wakeups.cancelledTasks.append(task) }
            HTTP2FrameEncoder.encodeRSTStream(streamID: id, code, into: &outbound.ordered)
            if let increment {
                HTTP2FrameEncoder.encodeWindowUpdate(streamID: .connection, increment: increment, into: &outbound.priority)
            }
            if let flood = countControlFrame(wakeups: &wakeups) { return flood }
            wakeWriter(&wakeups)
            wakeStream(id, &wakeups)  // Its writer, if waiting, stops.

        case .windowChanged:
            switch event {
            case .windowUpdate(let id, _) where id.isConnection:
                grantNext(&wakeups)
            case .windowUpdate(let id, _), .rstStream(let id, _):
                // Only this stream's writer can use (or must see) the change.
                wakeStream(id, &wakeups)
            default:
                wakeStreamWaiters(&wakeups)
            }

        case .goaway(let last, let error):
            HTTP2FrameEncoder.encodeGoaway(lastStreamID: last, error: error, into: &outbound.ordered)
            close(error.code == .settingsTimeout ? .timeout : .protocolError, wakeups: &wakeups)

        case .gracefulGoaway(let last, let final):
            HTTP2FrameEncoder.encodeGoaway(
                lastStreamID: last, .noError, debugData: UnsafeRawBufferPointer(start: nil, count: 0),
                into: &outbound.ordered)
            wakeWriter(&wakeups)
            if final {
                // Streams above the bound lost their responses: their writers must see it.
                wakeAllWaiters(&wakeups)
                draining = true
                if activeStreams == 0 { close(.shutdown, wakeups: &wakeups) }
            }
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
        /// Wait for this ticket's turn (``HTTP2ConnectionDriver/waitForTurn(_:)``), then try
        /// again with it.
        case wait(ticket: UInt64)
        /// The stream or connection is closed: stop writing the response.
        case dropped
    }

    /// Encodes and enqueues a response head, unless the queue is full or other writers are
    /// ahead. `ticket` is the one a previous attempt waited with.
    mutating func sendHeaders(
        streamID: HTTP2StreamID, status: HTTPStatus, headers: HTTPFields, contentLength: Int?, endStream: Bool,
        ticket: UInt64? = nil, wakeups: inout HTTP2Wakeups
    ) -> StreamStep {
        if let step = admit(ticket, streamID: streamID, needsWindow: false, wakeups: &wakeups) { return step }
        defer { grantNext(&wakeups) }
        // A head larger than the peer's SETTINGS_MAX_HEADER_LIST_SIZE would be refused by it:
        // send a bare 500 instead, and no body (#0055, like HTTP/3's #0102).
        var tooLarge = false
        if let limit = machine.peerMaxHeaderListSize {
            tooLarge = HTTP2ResponseHeadEncoder.listSize(status: status, headers: headers, contentLength: contentLength)
                > Int(limit)
        }
        let ends = endStream || tooLarge
        switch handle(.sendHeaders(streamID: streamID, endStream: ends), wakeups: &wakeups) {
        case .send:
            if tooLarge {
                encoder.encode(
                    streamID: streamID, status: .internalServerError, headers: HTTPFields(), contentLength: nil,
                    endStream: true, maxFrameSize: machine.peerMaxFrameSize, into: &outbound.ordered)
            } else {
                encoder.encode(
                    streamID: streamID, status: status, headers: headers, contentLength: contentLength,
                    endStream: endStream, maxFrameSize: machine.peerMaxFrameSize, into: &outbound.ordered)
            }
            wakeWriter(&wakeups)
            return .sent(length: 0, endStream: ends)
        default:
            return .dropped
        }
    }

    /// Enqueues one DATA frame with as many bytes of `bytes` as the windows and the peer's
    /// MAX_FRAME_SIZE allow (all of them, with END_STREAM when `endStream`).
    mutating func sendData(
        streamID: HTTP2StreamID, bytes: borrowing ByteBuffer, endStream: Bool, ticket: UInt64? = nil,
        wakeups: inout HTTP2Wakeups
    ) -> StreamStep {
        let needsWindow = bytes.readableBytes > 0
        if let step = admit(ticket, streamID: streamID, needsWindow: needsWindow, wakeups: &wakeups) { return step }
        defer { grantNext(&wakeups) }
        switch handle(.sendData(streamID: streamID, length: bytes.readableBytes, endStream: endStream), wakeups: &wakeups) {
        case .sendData(let length, let ends):
            HTTP2FrameEncoder.encodeDataHeader(streamID: streamID, dataLength: length, endStream: ends, into: &outbound.ordered)
            if length > 0 {
                outbound.ordered.append(ByteView(offset: bytes.readerIndex, length: length), from: bytes)
            }
            wakeWriter(&wakeups)
            return .sent(length: length, endStream: ends)
        case .waitForWindow:
            // `admit` saw both windows open; keep the rule total.
            return .wait(ticket: park(streamID, needsWindow: true, front: true))
        default:
            return .dropped
        }
    }

    // MARK: Fair waiting (#0054)

    /// A stream writer that waits to send.
    struct SendWaiter: Sendable {
        var streamID: UInt32
        /// DATA with payload: needs the connection window, not only queue space.
        var needsWindow: Bool
        /// Set when its turn came (or the stream or connection closed) before it parked.
        var woken = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    /// Decides whether a writer may send now (`nil`) or waits (`.wait`, with a new ticket) or
    /// stops (`.dropped`).
    ///
    /// Writers wait in one of two places:
    /// - a stream whose own send window is not positive waits in ``streamWaiters`` until a
    ///   WINDOW_UPDATE on that stream, or an INITIAL_WINDOW_SIZE change, makes it positive;
    /// - a writer that needs queue space or connection window that is not there, or that finds
    ///   another writer ahead of it, waits at the back of ``fairQueue``.
    ///
    /// ``grantNext(_:)`` hands the turn to the first queued writer that can proceed, one at a
    /// time, and wakes only that one. A writer that sent a frame and comes back while others
    /// wait goes to the back of the queue: streams take turns frame by frame (round robin),
    /// so one large response cannot starve the others, and no change wakes every writer.
    private mutating func admit(
        _ ticket: UInt64?, streamID: HTTP2StreamID, needsWindow: Bool, wakeups: inout HTTP2Wakeups
    ) -> StreamStep? {
        var hadTurn = false
        if let ticket {
            hadTurn = granted == ticket
            removeWaiter(ticket)
        }
        guard isOpen else {
            if hadTurn { grantNext(&wakeups) }
            return .dropped
        }
        // The response stopped (reset, or above the final GOAWAY): the state machine drops it.
        guard machine.sendWindow(of: streamID) != nil else { return nil }
        if needsWindow, let window = machine.sendWindow(of: streamID), window <= 0 {
            if hadTurn { grantNext(&wakeups) }
            return .wait(ticket: park(streamID, needsWindow: true, front: false))
        }
        if canProceed(needsWindow: needsWindow) && (hadTurn || granted == nil) { return nil }
        // A writer that had its turn but lost the resource keeps its place at the front.
        let ticket = park(streamID, needsWindow: needsWindow, front: hadTurn)
        if hadTurn { grantNext(&wakeups) }
        return .wait(ticket: ticket)
    }

    private func canProceed(needsWindow: Bool) -> Bool {
        outbound.hasSpace && (!needsWindow || machine.connectionSendWindow > 0)
    }

    /// Registers a new waiter: in ``streamWaiters`` when its stream window is closed, else in
    /// ``fairQueue``.
    private mutating func park(_ streamID: HTTP2StreamID, needsWindow: Bool, front: Bool) -> UInt64 {
        let ticket = nextWaiterID
        nextWaiterID &+= 1
        sendWaiters[ticket] = SendWaiter(streamID: streamID.rawValue, needsWindow: needsWindow)
        if needsWindow, let window = machine.sendWindow(of: streamID), window <= 0 {
            streamWaiters[streamID.rawValue] = ticket
        } else if front {
            fairQueue.insert(ticket, at: 0)
        } else {
            fairQueue.append(ticket)
        }
        return ticket
    }

    /// Forgets `ticket` wherever it waits. Passing the turn on is the caller's job.
    private mutating func removeWaiter(_ ticket: UInt64) {
        guard let waiter = sendWaiters.removeValue(forKey: ticket) else { return }
        if granted == ticket { granted = nil }
        if streamWaiters[waiter.streamID] == ticket {
            streamWaiters.removeValue(forKey: waiter.streamID)
        } else if let index = fairQueue.firstIndex(of: ticket) {
            fairQueue.remove(at: index)
        }
    }

    /// Resumes `ticket`'s writer (now, or as soon as it parks).
    private mutating func wake(_ ticket: UInt64, _ wakeups: inout HTTP2Wakeups) {
        guard var waiter = sendWaiters[ticket] else { return }
        waiter.woken = true
        if let continuation = waiter.continuation {
            wakeups.waiters.append(continuation)
            waiter.continuation = nil
        }
        sendWaiters[ticket] = waiter
    }

    /// Gives the turn to the first queued writer that can proceed, if nobody has it.
    mutating func grantNext(_ wakeups: inout HTTP2Wakeups) {
        guard granted == nil, !fairQueue.isEmpty, outbound.hasSpace else { return }
        for ticket in fairQueue {
            guard let waiter = sendWaiters[ticket] else { continue }
            if canProceed(needsWindow: waiter.needsWindow) {
                granted = ticket
                wake(ticket, &wakeups)
                return
            }
        }
    }

    /// A WINDOW_UPDATE on `id`, or its reset: wakes its writer when it waits for that stream's
    /// window (it can now send, or must see the stream closed). A writer of a closed stream in
    /// the fair queue is woken too, so it stops at once.
    mutating func wakeStream(_ id: HTTP2StreamID, _ wakeups: inout HTTP2Wakeups) {
        if let ticket = streamWaiters[id.rawValue] {
            if (machine.sendWindow(of: id) ?? 1) > 0 {
                streamWaiters.removeValue(forKey: id.rawValue)
                // Back into the fair queue's order: it still needs queue space and connection
                // window, which `admit` checks when it comes back.
                wake(ticket, &wakeups)
            }
        } else if machine.sendWindow(of: id) == nil,
                  let index = fairQueue.firstIndex(where: { sendWaiters[$0]?.streamID == id.rawValue }) {
            // Out of the queue but still recorded: its retry drops.
            wake(fairQueue.remove(at: index), &wakeups)
        }
    }

    /// INITIAL_WINDOW_SIZE changed: wakes the stream writers whose window is now positive.
    mutating func wakeStreamWaiters(_ wakeups: inout HTTP2Wakeups) {
        for (stream, ticket) in streamWaiters where (machine.sendWindow(of: HTTP2StreamID(stream)) ?? 1) > 0 {
            streamWaiters.removeValue(forKey: stream)
            wake(ticket, &wakeups)
        }
        grantNext(&wakeups)
    }

    /// Wakes every waiting writer (the connection closes).
    mutating func wakeAllWaiters(_ wakeups: inout HTTP2Wakeups) {
        for ticket in sendWaiters.keys { wake(ticket, &wakeups) }
        fairQueue.removeAll(keepingCapacity: true)
        streamWaiters.removeAll(keepingCapacity: true)
        granted = nil
    }

    /// Parks `continuation` for `ticket`. Returns false (and keeps nothing) when the writer
    /// should not wait: its turn already came, it was removed, or the connection is closing.
    mutating func parkWaiter(_ ticket: UInt64, _ continuation: CheckedContinuation<Void, Never>) -> Bool {
        guard isOpen, var waiter = sendWaiters[ticket], !waiter.woken else { return false }
        waiter.continuation = continuation
        sendWaiters[ticket] = waiter
        return true
    }

    /// The writer with `ticket` stops waiting (cancelled): it gives up its place, and its turn
    /// if it had one.
    mutating func cancelWaiter(_ ticket: UInt64, wakeups: inout HTTP2Wakeups) {
        if let continuation = sendWaiters[ticket]?.continuation { wakeups.waiters.append(continuation) }
        let hadTurn = granted == ticket
        removeWaiter(ticket)
        if hadTurn { grantNext(&wakeups) }
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
            grantNext(&wakeups)  // Queue space for the next stream writer.
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
        wakeAllWaiters(&wakeups)
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
        wakeAllWaiters(&wakeups)
        failPings(&wakeups)
    }

    /// A stream task ended. Resets the stream if the peer is still sending, and finishes a
    /// graceful drain after the last stream.
    mutating func streamEnded(_ streamID: HTTP2StreamID, wakeups: inout HTTP2Wakeups) {
        activeStreams -= 1
        if activeStreams == 0 && tracksIdleTime { idleSince = .now }
        // DATA that still arrives has no reader: the reader credits it at once.
        bodies.removeValue(forKey: streamID.rawValue)
        tasks.removeValue(forKey: streamID.rawValue)
        if isOpen { _ = handle(.responseFinished(streamID: streamID), wakeups: &wakeups) }
        if draining && activeStreams == 0 { close(.shutdown, wakeups: &wakeups) }
    }

    /// The stream tasks to cancel when the drain deadline passes.
    var runningTasks: [HTTP2StreamTask] { Array(tasks.values) }

    // MARK: Waiters

    mutating func wakeWriter(_ wakeups: inout HTTP2Wakeups) {
        if let writer {
            wakeups.writer = writer
            self.writer = nil
        }
    }
}
