import HTTP2

/// A deterministic generator for seeded random tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

typealias StreamState = HTTP2Stream.State
typealias StreamFrame = HTTP2Stream.Frame
typealias StreamAction = HTTP2Stream.Action

/// Every state, as a server reaches it (open and the half-closed states after the client's
/// request head).
let allStreamStates: [StreamState] = [
    .idle, .reservedLocal, .reservedRemote, .open, .halfClosedLocal, .halfClosedRemote,
    .closed(.endStream), .closed(.resetSent), .closed(.resetReceived),
]

let allStreamFrames: [StreamFrame] = [
    .headers(endStream: false), .headers(endStream: true), .data(endStream: false), .data(endStream: true),
    .priority, .rstStream, .windowUpdate, .pushPromise,
]

/// Drives a fresh stream into `state` through legal events.
func makeStream(_ state: StreamState) -> HTTP2Stream {
    var stream = HTTP2Stream()
    let path: [HTTP2Stream.Event]
    switch state {
    case .idle: path = []
    case .reservedLocal: path = [.sent(.pushPromise)]
    case .reservedRemote: path = [.received(.pushPromise)]
    case .open: path = [.received(.headers(endStream: false))]
    case .halfClosedLocal: path = [.received(.headers(endStream: false)), .sent(.data(endStream: true))]
    case .halfClosedRemote: path = [.received(.headers(endStream: true))]
    case .closed(.endStream): path = [.received(.headers(endStream: true)), .sent(.headers(endStream: true))]
    case .closed(.resetSent): path = [.received(.headers(endStream: false)), .sent(.rstStream)]
    case .closed(.resetReceived): path = [.received(.headers(endStream: false)), .received(.rstStream)]
    }
    for event in path { precondition(stream.handle(event) == .proceed) }
    precondition(stream.state == state)
    return stream
}

/// The expected RFC 9113 §5.1 transition, written out as data: the reference for the state
/// machine and for the stream-table model.
struct Transition {
    var action: StreamAction
    /// The state afterwards; `nil` means unchanged.
    var next: StreamState?
}

private let P = Transition(action: .proceed, next: nil)
private let I = Transition(action: .ignore, next: nil)
private func to(_ state: StreamState) -> Transition { Transition(action: .proceed, next: state) }
private func conn(_ code: HTTP2ErrorCode) -> Transition { Transition(action: .connectionError(code), next: nil) }
private func rst(_ code: HTTP2ErrorCode) -> Transition {
    Transition(action: .streamError(code), next: .closed(.resetSent))
}
private let PE = HTTP2ErrorCode.protocolError
private let SC = HTTP2ErrorCode.streamClosed
private let IE = HTTP2ErrorCode.internalError

/// Columns: H, H+ES, D, D+ES, PRIORITY, RST_STREAM, WINDOW_UPDATE, PUSH_PROMISE.
private let receivedTable: [StreamState: [Transition]] = [
    .idle: [to(.open), to(.halfClosedRemote), conn(PE), conn(PE), P, conn(PE), conn(PE), to(.reservedRemote)],
    .reservedLocal: [conn(PE), conn(PE), conn(PE), conn(PE), P, to(.closed(.resetReceived)), P, conn(PE)],
    .reservedRemote: [
        to(.halfClosedLocal), to(.closed(.endStream)), conn(PE), conn(PE), P, to(.closed(.resetReceived)),
        conn(PE), conn(PE),
    ],
    .open: [rst(PE), to(.halfClosedRemote), P, to(.halfClosedRemote), P, to(.closed(.resetReceived)), P, conn(PE)],
    .halfClosedLocal: [
        rst(PE), to(.closed(.endStream)), P, to(.closed(.endStream)), P, to(.closed(.resetReceived)), P, conn(PE),
    ],
    .halfClosedRemote: [rst(SC), rst(SC), rst(SC), rst(SC), P, to(.closed(.resetReceived)), P, conn(PE)],
    .closed(.endStream): [conn(SC), conn(SC), conn(SC), conn(SC), P, I, I, conn(PE)],
    .closed(.resetSent): [I, I, I, I, P, I, I, conn(PE)],
    .closed(.resetReceived): [rst(SC), rst(SC), rst(SC), rst(SC), P, I, I, conn(PE)],
]

private let sentTable: [StreamState: [Transition]] = [
    .idle: [to(.open), to(.halfClosedLocal), conn(IE), conn(IE), P, conn(IE), conn(IE), to(.reservedLocal)],
    .reservedLocal: [
        to(.halfClosedRemote), to(.closed(.endStream)), conn(IE), conn(IE), P, to(.closed(.resetSent)), conn(IE),
        conn(IE),
    ],
    .reservedRemote: [conn(IE), conn(IE), conn(IE), conn(IE), P, to(.closed(.resetSent)), P, conn(IE)],
    .open: [P, to(.halfClosedLocal), P, to(.halfClosedLocal), P, to(.closed(.resetSent)), P, conn(IE)],
    .halfClosedLocal: [conn(IE), conn(IE), conn(IE), conn(IE), P, to(.closed(.resetSent)), P, conn(IE)],
    .halfClosedRemote: [
        P, to(.closed(.endStream)), P, to(.closed(.endStream)), P, to(.closed(.resetSent)), P, conn(IE),
    ],
    .closed(.endStream): [I, I, I, I, P, I, I, I],
    .closed(.resetSent): [I, I, I, I, P, I, I, I],
    .closed(.resetReceived): [I, I, I, I, P, I, I, I],
]

/// The expected transition for `event` in `state` (server path).
func expectedTransition(_ state: StreamState, _ event: HTTP2Stream.Event) -> Transition {
    switch event {
    case .received(let frame): receivedTable[state]![allStreamFrames.firstIndex(of: frame)!]
    case .sent(let frame): sentTable[state]![allStreamFrames.firstIndex(of: frame)!]
    }
}

/// The number of rows in the expected tables.
var expectedTransitionRowCount: Int {
    (receivedTable.values.map(\.count) + sentTable.values.map(\.count)).reduce(0, +)
}

/// A reference model of ``HTTP2StreamTable``: a dictionary of states, a FIFO of closed
/// identifiers, and the transition table above. Unbounded and slow, but obviously right.
struct StreamTableModel {
    let maxConcurrent: Int
    let recentlyClosed: Int
    var streams: [UInt32: StreamState] = [:]
    var closedOrder: [UInt32] = []
    var highest: UInt32 = 0
    var goaway: UInt32?

    init(maxConcurrent: Int, recentlyClosed: Int) {
        self.maxConcurrent = maxConcurrent
        self.recentlyClosed = recentlyClosed
    }

    var active: Int { streams.values.filter(\.isActive).count }

    private mutating func set(_ id: UInt32, _ state: StreamState) {
        let wasClosed = streams[id]?.isClosed ?? false
        streams[id] = state
        if state.isClosed && !wasClosed {
            closedOrder.append(id)
            if closedOrder.count > recentlyClosed { streams[closedOrder.removeFirst()] = nil }
        }
    }

    mutating func handle(_ event: HTTP2StreamTable.Event) -> StreamAction {
        switch event {
        case .goawaySent(let last):
            let bound = min(goaway ?? last.rawValue, last.rawValue)
            goaway = bound
            for id in streams.keys.sorted() where id > bound && streams[id]?.isClosed == false {
                set(id, .closed(.resetSent))
            }
            return .proceed

        case .received(let streamID, let frame):
            let id = streamID.rawValue
            if id == 0 { return .connectionError(PE) }
            if frame == .pushPromise { return .connectionError(PE) }
            if let goaway, id > goaway, id & 1 == 1 {
                if id > highest, case .headers = frame { highest = id }
                return .ignore
            }
            if let state = streams[id] {
                let t = expectedTransition(state, .received(frame))
                if let next = t.next { set(id, next) }
                return t.action
            }
            if id & 1 == 1 && id > highest {
                switch frame {
                case .headers:
                    highest = id
                    if active >= maxConcurrent {
                        set(id, .closed(.resetSent))
                        return .streamError(.refusedStream)
                    }
                    let t = expectedTransition(.idle, .received(frame))
                    set(id, t.next!)
                    return t.action
                case .priority: return .proceed
                default: return .connectionError(PE)
                }
            }
            if id & 1 == 0 { return frame == .priority ? .proceed : .connectionError(PE) }
            switch frame {
            case .headers: return .connectionError(PE)
            case .data:
                set(id, .closed(.resetSent))
                return .streamError(SC)
            case .priority: return .proceed
            default: return .ignore
            }

        case .sent(let streamID, let frame):
            let id = streamID.rawValue
            if frame == .priority { return .proceed }
            if let state = streams[id] {
                let t = expectedTransition(state, .sent(frame))
                if let next = t.next { set(id, next) }
                return t.action
            }
            if id & 1 == 1 && id <= highest { return .ignore }
            return .connectionError(IE)
        }
    }
}
