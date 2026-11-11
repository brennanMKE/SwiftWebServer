/// A server connection's streams and the stream-identifier rules (RFC 9113 §5.1.1, §5.1.2,
/// §6.8).
///
/// A value type with no I/O (docs/ROADMAP.md §5.4). Every stream-level frame the connection
/// sends or receives goes through ``handle(_:)``, which finds or creates the stream's
/// ``HTTP2Stream``, applies the identifier rules, and returns one ``HTTP2Stream/Action``.
///
/// Identifier rules, for a server (which never pushes, so it opens no streams):
/// - Clients open odd streams with increasing identifiers. A HEADERS frame that opens a stream
///   must use an identifier above every stream the client opened before; a lower or reused one
///   is a connection `PROTOCOL_ERROR`. Opening a stream implicitly closes every lower idle
///   stream (§5.1.1).
/// - Frames other than HEADERS and PRIORITY on an idle stream, and a HEADERS frame on an even
///   (server-initiated) stream, are connection `PROTOCOL_ERROR`s.
/// - A HEADERS frame that would exceed ``Configuration/maxConcurrentStreams`` is refused with
///   a `REFUSED_STREAM` stream error; the identifier is still used up (§5.1.2).
/// - After ``Event/goawaySent(lastStreamID:)``, frames on streams above the last stream
///   identifier are ignored (§6.8).
///
/// Storage is bounded and allocated once. Live streams and recently closed ones share one
/// open-addressed table keyed by stream identifier, sized from
/// ``Configuration/maxConcurrentStreams`` and ``Configuration/recentlyClosedCapacity``.
/// Closed streams are kept, oldest first, until `recentlyClosedCapacity` newer streams have
/// closed. While kept, late frames follow their close reason (frames in flight after this
/// endpoint's RST_STREAM are ignored, §5.1). A stream at or below the highest identifier that
/// is not in the table either closed long ago or was never opened (implicitly closed by a
/// higher stream). Both are treated strictly: HEADERS is a connection `PROTOCOL_ERROR`
/// (identifier reuse), DATA a stream `STREAM_CLOSED` error, and WINDOW_UPDATE and RST_STREAM
/// are ignored.
public struct HTTP2StreamTable: Sendable {
    public struct Configuration: Hashable, Sendable {
        /// The advertised SETTINGS_MAX_CONCURRENT_STREAMS (docs/HTTP2.md default 100). Fixes
        /// the table's capacity, so it is bounded by ``maxSupportedConcurrentStreams``.
        public var maxConcurrentStreams: Int
        /// How many closed streams are remembered, oldest evicted first. Defaults to
        /// `maxConcurrentStreams`. Must be at least 1.
        public var recentlyClosedCapacity: Int

        /// The largest supported `maxConcurrentStreams`.
        public static let maxSupportedConcurrentStreams = 1 << 16

        public init(maxConcurrentStreams: Int = 100, recentlyClosedCapacity: Int? = nil) {
            precondition(
                (0...Self.maxSupportedConcurrentStreams).contains(maxConcurrentStreams),
                "maxConcurrentStreams must be 0 through \(Self.maxSupportedConcurrentStreams)")
            let closed = recentlyClosedCapacity ?? Swift.max(maxConcurrentStreams, 1)
            precondition(
                (1...Self.maxSupportedConcurrentStreams).contains(closed),
                "recentlyClosedCapacity must be 1 through \(Self.maxSupportedConcurrentStreams)")
            self.maxConcurrentStreams = maxConcurrentStreams
            self.recentlyClosedCapacity = closed
        }
    }

    public enum Event: Hashable, Sendable {
        /// The peer sent a stream-level frame on `streamID`.
        case received(HTTP2StreamID, HTTP2Stream.Frame)
        /// This endpoint is about to send a stream-level frame on `streamID`.
        case sent(HTTP2StreamID, HTTP2Stream.Frame)
        /// This endpoint sent GOAWAY. A later GOAWAY can only lower the bound (§6.8). Streams
        /// above it were never processed; they are closed and their frames ignored.
        case goawaySent(lastStreamID: HTTP2StreamID)
    }

    public typealias Action = HTTP2Stream.Action

    @usableFromInline
    struct Slot: Sendable {
        /// 0 marks an empty slot; stream 0 is never stored.
        var id: UInt32
        var stream: HTTP2Stream
    }

    public let configuration: Configuration

    /// Power-of-two open-addressed table with linear probing and backward-shift deletion.
    @usableFromInline var slots: [Slot]
    @usableFromInline let mask: Int
    @usableFromInline let shift: Int

    /// Identifiers of closed streams still in ``slots``, in closing order (a ring).
    var closedRing: [UInt32]
    var closedHead = 0
    var closedCount = 0

    /// Streams counting toward SETTINGS_MAX_CONCURRENT_STREAMS.
    public private(set) var activeCount = 0
    /// The highest stream identifier the client has opened (or had refused). This is the
    /// last-stream-ID for a GOAWAY sent now.
    public private(set) var highestClientStreamID = HTTP2StreamID.connection
    /// The last-stream-ID of the lowest GOAWAY sent, if any.
    public private(set) var goawayLastStreamID: HTTP2StreamID?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        let entries = configuration.maxConcurrentStreams + configuration.recentlyClosedCapacity
        // At most half full.
        var capacity = 8
        while capacity < entries * 2 { capacity <<= 1 }
        slots = Array(repeating: Slot(id: 0, stream: HTTP2Stream()), count: capacity)
        mask = capacity - 1
        shift = 64 - capacity.trailingZeroBitCount
        closedRing = Array(repeating: 0, count: configuration.recentlyClosedCapacity)
    }

    /// The stream with `id`, if it is live or recently closed.
    public func stream(_ id: HTTP2StreamID) -> HTTP2Stream? {
        guard let index = find(id.rawValue) else { return nil }
        return slots[index].stream
    }

    /// The number of streams in the table, live and recently closed.
    public var count: Int { activeCount + closedCount }

    public mutating func handle(_ event: Event) -> Action {
        switch event {
        case .received(let id, let frame): return receive(frame, on: id)
        case .sent(let id, let frame): return send(frame, on: id)
        case .goawaySent(let last): return goaway(last)
        }
    }

    // MARK: Events

    private mutating func receive(_ frame: HTTP2Stream.Frame, on id: HTTP2StreamID) -> Action {
        // The frame parser rejects stream-level frames on stream 0; keep the rule total.
        guard !id.isConnection else { return .connectionError(.protocolError) }
        // A server never accepts PUSH_PROMISE (§8.4).
        if case .pushPromise = frame { return .connectionError(.protocolError) }

        if let goaway = goawayLastStreamID, id > goaway, id.isClientInitiated {
            // Never processed (§6.8). Keep the identifier ordering intact.
            if id > highestClientStreamID, case .headers = frame { highestClientStreamID = id }
            return .ignore
        }

        if let index = find(id.rawValue) {
            return apply(.received(frame), at: index)
        }

        if id.isClientInitiated && id > highestClientStreamID {
            // An idle stream.
            switch frame {
            case .headers:
                highestClientStreamID = id
                if activeCount >= configuration.maxConcurrentStreams {
                    // The block must still be decoded; frames the client sends after it are
                    // in flight and ignored.
                    insert(id.rawValue, HTTP2Stream(state: .closed(.resetSent)))
                    return .streamError(.refusedStream)
                }
                var stream = HTTP2Stream()
                let action = stream.handle(.received(frame))
                insert(id.rawValue, stream)
                return action
            case .priority:
                return .proceed  // PRIORITY does not open a stream (§5.1).
            case .data, .rstStream, .windowUpdate, .pushPromise:
                return .connectionError(.protocolError)
            }
        }

        if id.isServerInitiated {
            // A server without push has no even streams; they are all idle.
            switch frame {
            case .priority: return .proceed
            default: return .connectionError(.protocolError)
            }
        }

        // A client stream at or below the highest: closed long ago, or never opened and
        // implicitly closed (§5.1.1).
        switch frame {
        case .headers:
            return .connectionError(.protocolError)
        case .data:
            insert(id.rawValue, HTTP2Stream(state: .closed(.resetSent)))
            return .streamError(.streamClosed)
        case .priority:
            return .proceed
        case .rstStream, .windowUpdate, .pushPromise:
            return .ignore
        }
    }

    private mutating func send(_ frame: HTTP2Stream.Frame, on id: HTTP2StreamID) -> Action {
        if case .priority = frame { return .proceed }
        if let index = find(id.rawValue) {
            return apply(.sent(frame), at: index)
        }
        if id.isClientInitiated && id <= highestClientStreamID {
            return .ignore  // Already closed and forgotten.
        }
        // This endpoint opens no streams.
        return .connectionError(.internalError)
    }

    private mutating func goaway(_ last: HTTP2StreamID) -> Action {
        let bound = goawayLastStreamID.map { Swift.min($0, last) } ?? last
        goawayLastStreamID = bound
        // Streams above the bound are not processed; close them. Collect first: recording a
        // close can evict an entry, and backward-shift deletion moves others. GOAWAY is rare,
        // so the allocation is off the hot path.
        var abandoned: [UInt32] = []
        for slot in slots where slot.id > bound.rawValue && !slot.stream.state.isClosed {
            abandoned.append(slot.id)
        }
        abandoned.sort()  // Close in identifier order, so eviction order is deterministic.
        for id in abandoned {
            guard let index = find(id) else { continue }
            if slots[index].stream.state.isActive { activeCount -= 1 }
            slots[index].stream = HTTP2Stream(state: .closed(.resetSent))
            appendClosed(id)
        }
        return .proceed
    }

    /// Applies `event` to the stream in `index` and keeps the bookkeeping in step.
    private mutating func apply(_ event: HTTP2Stream.Event, at index: Int) -> Action {
        let wasActive = slots[index].stream.state.isActive
        let wasClosed = slots[index].stream.state.isClosed
        let action = slots[index].stream.handle(event)
        let state = slots[index].stream.state
        if wasActive && !state.isActive { activeCount -= 1 }
        if !wasActive && state.isActive { activeCount += 1 }
        if !wasClosed && state.isClosed { appendClosed(slots[index].id) }
        return action
    }

    // MARK: Storage

    @inline(__always)
    private func home(_ id: UInt32) -> Int {
        // Fibonacci hashing: consecutive odd identifiers spread across the table.
        Int(truncatingIfNeeded: (UInt64(id) &* 0x9E37_79B9_7F4A_7C15) >> UInt64(shift))
    }

    private func find(_ id: UInt32) -> Int? {
        var index = home(id)
        while true {
            let slotID = slots[index].id
            if slotID == id { return index }
            if slotID == 0 { return nil }
            index = (index + 1) & mask
        }
    }

    /// Inserts a stream that is not in the table yet.
    private mutating func insert(_ id: UInt32, _ stream: HTTP2Stream) {
        var index = home(id)
        while slots[index].id != 0 { index = (index + 1) & mask }
        slots[index] = Slot(id: id, stream: stream)
        if stream.state.isActive { activeCount += 1 }
        if stream.state.isClosed { appendClosed(id) }
    }

    /// Records that the stream `id` closed, evicting the oldest closed stream when full.
    private mutating func appendClosed(_ id: UInt32) {
        let capacity = closedRing.count
        if closedCount == capacity {
            remove(closedRing[closedHead])
            closedRing[closedHead] = id
            closedHead = (closedHead + 1) % capacity
        } else {
            closedRing[(closedHead + closedCount) % capacity] = id
            closedCount += 1
        }
    }

    /// Removes `id` with backward-shift deletion, so lookups never need tombstones.
    private mutating func remove(_ id: UInt32) {
        guard var hole = find(id) else { return }
        slots[hole].id = 0
        var index = (hole + 1) & mask
        while slots[index].id != 0 {
            let wanted = home(slots[index].id)
            // Move the entry into the hole unless its home lies cyclically in (hole, index].
            let distanceToIndex = (index - wanted) & mask
            let distanceToHole = (hole - wanted) & mask
            if distanceToHole < distanceToIndex {
                slots[hole] = slots[index]
                slots[index].id = 0
                hole = index
            }
            index = (index + 1) & mask
        }
    }
}
