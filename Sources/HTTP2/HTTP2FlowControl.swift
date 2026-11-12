/// One receive flow-control window (RFC 9113 §5.2, §6.9) with batched credit: the connection's
/// or one stream's (docs/ROADMAP.md §5.4 `FlowControlWindow`).
///
/// A value type with no I/O. ``HTTP2Connection`` keeps one for the connection and one per
/// stream whose peer may still send DATA.
///
/// - ``receive(_:)`` charges a DATA frame (payload and padding). Going below zero is a
///   flow-control error at this window's level.
/// - ``credit(_:)`` returns bytes that were consumed (read by the handler, or discarded). The
///   credit is batched: it becomes a WINDOW_UPDATE increment only once half of ``size`` is
///   pending, so a peer streaming a body gets one WINDOW_UPDATE per half window, not one per
///   DATA frame.
/// - ``resize(to:)`` applies a new initial window (our SETTINGS_INITIAL_WINDOW_SIZE once
///   acknowledged, §6.9.2): the available window moves by the difference and may go negative.
public struct HTTP2ReceiveWindow: Hashable, Sendable {
    /// The window the peer is granted when everything is credited back.
    public private(set) var size: Int
    /// Bytes the peer may still send. Negative only after a shrinking ``resize(to:)``.
    public private(set) var available: Int
    /// Bytes consumed and not yet returned with a WINDOW_UPDATE.
    public private(set) var pending = 0

    public init(size: Int) {
        precondition(size >= 0 && size <= Int(HTTP2Settings.maxWindowSize), "window size is 0 through 2^31-1")
        self.size = size
        available = size
    }

    /// Charges `length` received bytes. Returns `false` when they exceed the window.
    public mutating func receive(_ length: Int) -> Bool {
        available -= length
        return available >= 0
    }

    /// Adds `length` bytes of credit; returns the WINDOW_UPDATE increment once half the window
    /// is pending.
    public mutating func credit(_ length: Int) -> UInt32? {
        pending += length
        guard pending > 0, pending * 2 >= size else { return nil }
        return flush()
    }

    /// Adds `length` bytes of credit that goes back with the next increment (padding).
    public mutating func addDeferredCredit(_ length: Int) {
        pending += length
    }

    /// Returns every pending byte now.
    public mutating func flush() -> UInt32? {
        guard pending > 0 else { return nil }
        let increment = pending
        available += increment
        pending = 0
        return UInt32(increment)
    }

    /// Applies a new window size (§6.9.2): `available` moves by the difference.
    public mutating func resize(to newSize: Int) {
        available += newSize - size
        size = newSize
    }
}
