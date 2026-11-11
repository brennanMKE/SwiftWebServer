import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Time limits for the phases of an HTTP/1.1 connection (#0082, legacy #0012). `nil` turns a
/// limit off.
///
/// | Limit | Runs while | When it passes |
/// |---|---|---|
/// | ``header`` | a request head is incomplete, from its first byte | `408` + close |
/// | ``idle`` | no byte of the next head has arrived (also before the first request) | silent close |
/// | ``body`` | the handler (or the drain) waits for request body bytes; restarts on progress | `408` + close |
/// | ``send`` | one send waits for the client to accept bytes; restarts per send | reset (abort) |
/// | ``linger`` | the lingering close reads and discards input after the final response | close |
///
/// The header limit is not renewed by progress, so a client that trickles a head one byte at a
/// time (slowloris) is closed when it passes. Handler time is never limited.
public struct HTTP1Timeouts: Sendable, Hashable {
    public var header: Duration?
    public var idle: Duration?
    public var body: Duration?
    public var send: Duration?
    /// Lingering close: when the connection closes with request bytes possibly unread (an
    /// error response, an unread body, pipelined requests dropped by a drain), the output is
    /// half-closed and input is read and discarded for at most this long (and at most
    /// ``HTTP1Configuration/maxLingerSize`` bytes) before closing, so the client reads the
    /// response instead of a reset. `nil` closes at once.
    public var linger: Duration?

    public static let defaultHeader = Duration.seconds(10)
    public static let defaultIdle = Duration.seconds(5)
    public static let defaultBody = Duration.seconds(30)
    public static let defaultSend = Duration.seconds(30)
    public static let defaultLinger = Duration.seconds(2)

    public init(
        header: Duration? = HTTP1Timeouts.defaultHeader,
        idle: Duration? = HTTP1Timeouts.defaultIdle,
        body: Duration? = HTTP1Timeouts.defaultBody,
        send: Duration? = HTTP1Timeouts.defaultSend,
        linger: Duration? = HTTP1Timeouts.defaultLinger
    ) {
        for value in [header, idle, body, send, linger] {
            if let value { precondition(value > .zero, "HTTP1Timeouts values must be positive") }
        }
        self.header = header
        self.idle = idle
        self.body = body
        self.send = send
        self.linger = linger
    }

    /// No limits at all (the behaviour before #0082).
    public static let disabled = HTTP1Timeouts(header: nil, idle: nil, body: nil, send: nil, linger: nil)
}

/// The limits of ``HTTP1Timeouts`` in ``HTTP1Ticks`` (0 = off), converted once per connection.
struct HTTP1TimeoutTicks: Sendable {
    var header: UInt64
    var idle: UInt64
    var body: UInt64
    var send: UInt64
    var linger: UInt64

    init(_ timeouts: HTTP1Timeouts) {
        header = HTTP1Ticks.ticks(timeouts.header)
        idle = HTTP1Ticks.ticks(timeouts.idle)
        body = HTTP1Ticks.ticks(timeouts.body)
        send = HTTP1Ticks.ticks(timeouts.send)
        linger = HTTP1Ticks.ticks(timeouts.linger)
    }

    /// The shortest limit, or 0 when every limit is off: the longest the timer sleeps between
    /// looks, so a phase that starts while it sleeps is still seen before its deadline.
    var shortest: UInt64 {
        [header, idle, body, send, linger].filter { $0 != 0 }.min() ?? 0
    }
}

/// A cheap monotonic clock: `mach_continuous_time` ticks on Darwin (one commpage read, keeps
/// counting through sleep, like `ContinuousClock`), nanoseconds elsewhere.
enum HTTP1Ticks {
    /// Ticks per second as numerator / denominator of nanoseconds per tick.
    static let timebase: (numerator: Double, denominator: Double) = {
        #if canImport(Darwin)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(Swift.max(info.numer, 1)), Double(Swift.max(info.denom, 1)))
        #else
        return (1, 1)
        #endif
    }()

    /// Deadlines are kept in 60 bits; limits are clamped far below that.
    static let maximum: UInt64 = 1 << 52

    @inline(__always)
    static func now() -> UInt64 {
        #if canImport(Darwin)
        mach_continuous_time()
        #else
        var spec = timespec()
        clock_gettime(CLOCK_MONOTONIC, &spec)
        return UInt64(spec.tv_sec) &* 1_000_000_000 &+ UInt64(spec.tv_nsec)
        #endif
    }

    /// `duration` in ticks (at least 1), or 0 for `nil`.
    static func ticks(_ duration: Duration?) -> UInt64 {
        guard let duration else { return 0 }
        let (seconds, attoseconds) = duration.components
        let nanoseconds = Double(seconds) * 1e9 + Double(attoseconds) / 1e9
        let ticks = nanoseconds * timebase.denominator / timebase.numerator
        guard ticks >= 1 else { return 1 }
        return ticks >= Double(maximum) ? maximum : UInt64(ticks)
    }

    static func duration(_ ticks: UInt64) -> Duration {
        .nanoseconds(Int64(Double(ticks) * timebase.numerator / timebase.denominator))
    }
}

/// Who owns a connection's next move, and until when (#0082).
///
/// One per connection, shared by the connection loop (the *driver*) and its supervisor in
/// ``HTTP1/run(_:handler:context:)``. All of it is one atomic word: the phase the driver is
/// in, its deadline, and an *owned* bit.
///
/// - The driver publishes each phase with ``enter(_:deadline:)``: three compare-and-swaps and
///   two clock reads per keep-alive batch, no allocation, no lock, no task.
/// - One timer task per connection sleeps until the published deadline (re-reading the word
///   at least every ``HTTP1TimeoutTicks/shortest`` so a later, earlier deadline is not
///   missed). When a deadline passes it swaps in the owned bit, but only if the word is still
///   the one it saw expire, so a driver that moved on in the meantime is never interrupted.
/// - Once the owned bit is set, the driver's next ``enter(_:deadline:)`` fails: it stops
///   without sending anything, and the supervisor decides the ending (a `408`, a silent close,
///   a reset). Every driver send is preceded by `enter(.send)`, so the supervisor is the only
///   sender from then on.
final class HTTP1Watchdog: Sendable {
    enum Phase: UInt64 {
        /// The handler runs (or the driver is between steps): no limit.
        case none = 0
        case idle = 1
        case head = 2
        case body = 3
        case send = 4
        case linger = 5
        /// The connection left HTTP (a tunnel) or ended: the timer stops.
        case done = 6
    }

    static let phaseMask: UInt64 = 0x7
    static let ownedBit: UInt64 = 0x8
    static let deadlineShift: UInt64 = 4

    let word = Atomic<UInt64>(0)
    /// The tick deadlines are relative to (so they stay small and 0 can mean "none").
    let base: UInt64

    init() {
        base = HTTP1Ticks.now()
    }

    // MARK: Driver side

    /// The deadline `ticks` from now, or 0 (none) when `ticks` is 0 (the limit is off).
    @inline(__always)
    func deadline(after ticks: UInt64) -> UInt64 {
        ticks == 0 ? 0 : HTTP1Ticks.now() &- base &+ ticks
    }

    /// Publishes the driver's phase and deadline. Returns false when the supervisor owns the
    /// connection: the driver must stop without further I/O.
    @inline(__always)
    func enter(_ phase: Phase, deadline: UInt64 = 0) -> Bool {
        let desired = deadline << Self.deadlineShift | phase.rawValue
        var expected = word.load(ordering: .relaxed)
        while expected & Self.ownedBit == 0 {
            let (exchanged, original) = word.compareExchange(
                expected: expected, desired: desired, ordering: .sequentiallyConsistent)
            if exchanged { return true }
            expected = original
        }
        return false
    }

    /// True once the supervisor (or the timer on its behalf) took over.
    var isOwned: Bool { word.load(ordering: .sequentiallyConsistent) & Self.ownedBit != 0 }

    // MARK: Supervisor side

    /// Takes over if the driver is waiting between requests (idle, or with part of a head):
    /// what a drain closes at once. False when an exchange is in flight or it is already owned.
    func takeOverIfBetweenRequests() -> Bool {
        var expected = word.load(ordering: .sequentiallyConsistent)
        while expected & Self.ownedBit == 0 {
            let phase = expected & Self.phaseMask
            guard phase == Phase.idle.rawValue || phase == Phase.head.rawValue else { return false }
            let (exchanged, original) = word.compareExchange(
                expected: expected, desired: phase | Self.ownedBit, ordering: .sequentiallyConsistent)
            if exchanged { return true }
            expected = original
        }
        return false
    }

    /// Records a phase the supervisor itself is in (sending the `408`, lingering) with its
    /// deadline, for the timer to enforce.
    func own(_ phase: Phase, deadline: UInt64) {
        word.store(deadline << Self.deadlineShift | Self.ownedBit | phase.rawValue, ordering: .sequentiallyConsistent)
    }

    /// The timer task: returns the word whose deadline passed (after marking it owned), or
    /// `nil` when cancelled or the connection is done.
    func runTimer(tick: UInt64) async -> UInt64? {
        precondition(tick > 0, "the timer needs a tick")
        while !Task.isCancelled {
            let observed = word.load(ordering: .acquiring)
            if observed & Self.phaseMask == Phase.done.rawValue { return nil }
            let deadline = observed >> Self.deadlineShift
            var sleep = tick
            if deadline != 0 {
                let now = HTTP1Ticks.now() &- base
                if now >= deadline {
                    let fired = observed & (Self.phaseMask | Self.ownedBit) | Self.ownedBit
                    if word.compareExchange(expected: observed, desired: fired, ordering: .sequentiallyConsistent).exchanged {
                        return observed
                    }
                    continue   // the word changed: look again
                }
                sleep = Swift.min(deadline &- now, tick)
            }
            do {
                try await Task.sleep(for: HTTP1Ticks.duration(sleep))
            } catch {
                return nil
            }
        }
        return nil
    }

    static func phase(of word: UInt64) -> Phase {
        Phase(rawValue: word & phaseMask) ?? .none
    }

    static func isOwned(_ word: UInt64) -> Bool { word & ownedBit != 0 }
}
