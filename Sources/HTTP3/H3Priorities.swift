import HTTPCore
import Synchronization

/// One request stream's current RFC 9218 priority (#0107). The `priority` request field sets
/// it, a PRIORITY_UPDATE or the handler's `priority` response field changes it, and the
/// connection's ``H3SendBudget`` reads it whenever it picks the next waiting send.
final class H3StreamPriority: Sendable {
    let streamID: UInt64
    /// `urgency << 1 | incremental`.
    private let packed: Atomic<UInt8>

    init(streamID: UInt64, _ priority: HTTPPriority = .default) {
        self.streamID = streamID
        packed = Atomic(Self.pack(priority))
    }

    var value: HTTPPriority {
        let bits = packed.load(ordering: .relaxed)
        return HTTPPriority(urgency: bits >> 1, incremental: bits & 1 == 1)
    }

    func set(_ priority: HTTPPriority) { packed.store(Self.pack(priority), ordering: .relaxed) }

    /// Applies a handler's `priority` response field (RFC 9218 §5) on top of the current value.
    func apply(from fields: some HTTPFieldCollection) {
        var priority = value
        if priority.apply(from: fields) { set(priority) }
    }

    var schedulingKey: (UInt8, UInt8, UInt64) { value.schedulingKey(streamID: streamID) }

    private static func pack(_ priority: HTTPPriority) -> UInt8 {
        priority.urgency << 1 | (priority.incremental ? 1 : 0)
    }
}

/// The priorities of a connection's request streams, and PRIORITY_UPDATEs that arrived before
/// their stream (RFC 9218 §7.2; at most ``maxEarly`` of them are kept, later ones ignored).
final class H3Priorities: Sendable {
    struct State {
        var streams: [UInt64: H3StreamPriority] = [:]
        var early: [UInt64: HTTPPriority] = [:]
        /// The highest request stream ID served so far.
        var highest: UInt64?
    }

    let maxEarly: Int
    private let state = Mutex(State())

    init(maxEarly: Int) { self.maxEarly = Swift.max(maxEarly, 1) }

    /// A request stream starts with the priority its `priority` field signals; an update that
    /// arrived before it wins.
    func open(_ streamID: UInt64, requested: HTTPPriority) -> H3StreamPriority {
        state.withLock { state in
            let cell = H3StreamPriority(streamID: streamID, state.early.removeValue(forKey: streamID) ?? requested)
            state.streams[streamID] = cell
            state.highest = Swift.max(state.highest ?? 0, streamID)
            return cell
        }
    }

    func close(_ streamID: UInt64) {
        state.withLock { state in
            _ = state.streams.removeValue(forKey: streamID)
            // Updates kept for streams below this one that never arrived (rejected) are stale.
            if !state.early.isEmpty {
                for id in state.early.keys where id < streamID { state.early.removeValue(forKey: id) }
            }
        }
    }

    /// A PRIORITY_UPDATE for request stream `streamID` (already validated as a client
    /// bidirectional stream). An invalid field value is ignored; so is an update for a stream
    /// that already ended (not open, at or below the highest one served). Request streams can
    /// arrive out of order in QUIC, so an update for a lower stream that has not arrived yet
    /// is treated as closed: a documented imprecision.
    func update(_ streamID: UInt64, field: UnsafeRawBufferPointer) {
        var priority = HTTPPriority()
        guard priority.apply(field) else { return }
        state.withLock { state in
            if let cell = state.streams[streamID] {
                cell.set(priority)
            } else if streamID > (state.highest ?? 0) || state.highest == nil {
                if state.early[streamID] != nil || state.early.count < maxEarly { state.early[streamID] = priority }
            }
        }
    }

    /// Updates kept for streams not opened yet (for tests).
    var earlyCount: Int { state.withLock { $0.early.count } }
}
