public import HTTPCore

/// The QUIC connection edge (ROADMAP §5.4): mirrors `NWConnectionGroup` state updates and
/// stream lifecycle into events and decides what the adapter does. No I/O; one action per
/// event.
public struct QUICConnectionState: Sendable {
    public enum Phase: Sendable, Equatable {
        /// Handshake in progress (Network.framework reports `waiting(ENETDOWN)` here first;
        /// that is not a failure, spike gotcha 7).
        case setup
        /// The group is ready, or an inbound stream is (group state can lag behind streams).
        case ready
        /// ``Event/closeRequested`` was handled; waiting for the group to cancel.
        case closing
        /// The group was cancelled after a local close, or ended without an error worth
        /// reporting (peer close).
        case closed
        /// The connection failed with this error.
        case failed(TransportError)
    }

    public enum Event: Sendable, Equatable {
        case groupReady
        case groupFailed(TransportError)
        case groupCancelled
        /// A peer stream became ready (and so has a stream ID).
        case inboundStreamReady
        /// A peer-initiated stream finished (cancelled or failed after it was ready).
        case peerStreamFinished(unidirectional: Bool)
        /// ``QUICConnection/close(applicationError:)``.
        case closeRequested
    }

    public enum Action: Sendable, Equatable {
        case none
        /// The connection is now usable: hand it over and retry waiting stream opens.
        case becomeUsable
        /// Set the cumulative stream limits granted to the peer (MAX_STREAMS).
        case raiseMaxStreams(bidirectional: Int, unidirectional: Int)
        /// Cancel every stream, then the group (spike gotcha 6), and fail waiters with this
        /// error. Inbound iteration then ends (or throws, for ``TransportError/timedOut``).
        case tearDown(TransportError)
        /// Set the application error, cancel every stream, then the group.
        case beginClose
        /// The group is gone: resume close waiters.
        case finish
    }

    public private(set) var phase: Phase = .setup
    /// Peer streams that finished, by kind; each grants one more stream of that kind.
    public private(set) var finishedBidirectional = 0
    public private(set) var finishedUnidirectional = 0
    public let initialMaxStreamsBidirectional: Int
    public let initialMaxStreamsUnidirectional: Int

    public init(initialMaxStreamsBidirectional: Int, initialMaxStreamsUnidirectional: Int) {
        self.initialMaxStreamsBidirectional = initialMaxStreamsBidirectional
        self.initialMaxStreamsUnidirectional = initialMaxStreamsUnidirectional
    }

    /// The cumulative limits the peer should currently have.
    public var maxStreamsBidirectional: Int { initialMaxStreamsBidirectional + finishedBidirectional }
    public var maxStreamsUnidirectional: Int { initialMaxStreamsUnidirectional + finishedUnidirectional }

    var isTerminal: Bool {
        switch phase {
        case .closing, .closed, .failed: true
        case .setup, .ready: false
        }
    }

    public mutating func handle(_ event: Event) -> Action {
        switch event {
        case .groupReady, .inboundStreamReady:
            guard phase == .setup else {
                // A late group `.ready` after a stream made the connection usable: apply any
                // stream credit that could not be set while the group had no metadata.
                if event == .groupReady, phase == .ready, finishedBidirectional + finishedUnidirectional > 0 {
                    return .raiseMaxStreams(bidirectional: maxStreamsBidirectional, unidirectional: maxStreamsUnidirectional)
                }
                return .none
            }
            phase = .ready
            return .becomeUsable

        case .peerStreamFinished(let unidirectional):
            if unidirectional { finishedUnidirectional += 1 } else { finishedBidirectional += 1 }
            guard phase == .ready || phase == .setup else { return .none }
            return .raiseMaxStreams(bidirectional: maxStreamsBidirectional, unidirectional: maxStreamsUnidirectional)

        case .groupFailed(let error):
            switch phase {
            case .setup, .ready:
                phase = .failed(error)
                return .tearDown(error)
            case .closing, .closed, .failed:
                return .none
            }

        case .closeRequested:
            switch phase {
            case .setup, .ready:
                phase = .closing
                return .beginClose
            case .closing, .closed, .failed:
                return .none
            }

        case .groupCancelled:
            switch phase {
            case .setup, .ready:
                // Cancelled without a local close (for example deinit): treat as closed.
                phase = .closed
                return .tearDown(.closed)
            case .closing:
                phase = .closed
                return .finish
            case .closed, .failed:
                return .finish
            }
        }
    }
}

/// The receive side of one QUIC stream (ROADMAP §5.4): maps a Network.framework receive
/// completion (`data`, `isComplete`, `error`) to what the waiting `receive` returns. FIN is
/// `isComplete` (spike Q4); a peer RESET_STREAM arrives as `ECONNRESET` (spike Q5).
public struct QUICStreamState: Sendable {
    public enum Event: Sendable, Equatable {
        case received(byteCount: Int, isComplete: Bool, error: TransportError?)
    }

    public enum Action: Sendable, Equatable {
        /// Return the delivered bytes.
        case deliver
        /// Return 0: the peer finished sending.
        case endOfStream
        /// Throw this error.
        case fail(TransportError)
        /// An empty, incomplete delivery: issue another receive.
        case retry
    }

    /// The peer's FIN was seen; sticky.
    public private(set) var inputEnded = false
    /// An error delivered together with the last bytes; the next receive throws it.
    public private(set) var inputError: TransportError?

    public init() {}

    public mutating func handle(_ event: Event) -> Action {
        switch event {
        case .received(let byteCount, let isComplete, let error):
            if byteCount > 0 {
                if isComplete && error == nil {
                    inputEnded = true
                } else if let error {
                    inputError = error
                }
                return .deliver
            }
            if let error {
                inputError = error
                return .fail(error)
            }
            if isComplete {
                inputEnded = true
                return .endOfStream
            }
            return .retry
        }
    }
}
