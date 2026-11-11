/// The lifecycle of one HTTP/2 stream (RFC 9113 §5.1).
///
/// A value type with no I/O (docs/ROADMAP.md §5.4). Feed it every stream-level frame the
/// connection sends or receives on the stream, in order, with ``handle(_:)``. Each call
/// returns one ``Action``. ``HTTP2StreamTable`` owns one per live stream and adds the
/// connection-level identifier rules.
///
/// ```
///                          +--------+
///                  send PP |        | recv PP
///                 ,--------+  idle  +--------.
///                /         |        |         \
///               v          +--------+          v
///        +----------+          |           +----------+
///        |          |          | send H /  |          |
/// ,------+ reserved |          | recv H    | reserved +------.
/// |      | (local)  |          |           | (remote) |      |
/// |      +---+------+          v           +------+---+      |
/// |          |             +--------+             |          |
/// |          |     recv ES |        | send ES     |          |
/// |   send H |     ,-------+  open  +-------.     | recv H   |
/// |          |    /        |        |        \    |          |
/// |          v   v         +---+----+         v   v          |
/// |      +----------+          |           +----------+      |
/// |      |   half-  |          |           |   half-  |      |
/// |      |  closed  |          | send R /  |  closed  |      |
/// |      | (remote) |          | recv R    | (local)  |      |
/// |      +----+-----+          |           +-----+----+      |
/// |           |                |                 |           |
/// |           | send ES /      |       recv ES / |           |
/// |           | send R /       v        send R / |           |
/// |           | recv R     +--------+   recv R   |           |
/// | send R /  `----------->|        |<-----------'  send R / |
/// | recv R                 | closed |               recv R   |
/// `----------------------->|        |<-----------------------'
///                          +--------+
/// ```
///
/// CONTINUATION frames are part of the HEADERS or PUSH_PROMISE they follow (§6.10) and are
/// handled by ``HeaderBlockAssembler``; they never reach this machine.
///
/// A ``Action/streamError(_:)`` result means the caller sends RST_STREAM with that code; the
/// stream has already moved to ``State/closed(_:)`` with ``CloseReason/resetSent``, so it
/// does not also report the RST_STREAM as a ``Event/sent(_:)`` frame.
///
/// One message-framing rule is modelled here because it decides the transition: a server
/// receives at most two header blocks on a stream, the request head and the trailers, and the
/// second must carry END_STREAM (RFC 9113 §8.1). Another HEADERS is a stream
/// `PROTOCOL_ERROR`.
public struct HTTP2Stream: Hashable, Sendable {
    /// Why a stream is closed. The rules for late frames depend on it (RFC 9113 §5.1).
    public enum CloseReason: Hashable, Sendable {
        /// Both sides sent END_STREAM. Late WINDOW_UPDATE and RST_STREAM are ignored; DATA or
        /// HEADERS is a connection `STREAM_CLOSED` error.
        case endStream
        /// This endpoint sent RST_STREAM. Frames the peer had in flight are ignored.
        case resetSent
        /// The peer sent RST_STREAM. Late DATA or HEADERS is a stream `STREAM_CLOSED` error;
        /// WINDOW_UPDATE and RST_STREAM are ignored (RST_STREAM is never answered with
        /// RST_STREAM, §5.4.2).
        case resetReceived
    }

    /// The states of RFC 9113 §5.1.
    public enum State: Hashable, Sendable {
        case idle
        /// This endpoint promised the stream with PUSH_PROMISE. A server without push never
        /// enters it.
        case reservedLocal
        /// The peer promised the stream. A server never enters it: clients cannot push.
        case reservedRemote
        case open
        /// This endpoint sent END_STREAM.
        case halfClosedLocal
        /// The peer sent END_STREAM.
        case halfClosedRemote
        case closed(CloseReason)

        /// Whether the stream counts toward SETTINGS_MAX_CONCURRENT_STREAMS (§5.1.2).
        @inlinable
        public var isActive: Bool {
            switch self {
            case .open, .halfClosedLocal, .halfClosedRemote: true
            case .idle, .reservedLocal, .reservedRemote, .closed: false
            }
        }

        @inlinable
        public var isClosed: Bool {
            if case .closed = self { return true }
            return false
        }
    }

    /// A stream-level frame, reduced to what the state machine needs.
    public enum Frame: Hashable, Sendable {
        /// A complete header block (HEADERS and its CONTINUATIONs).
        case headers(endStream: Bool)
        case data(endStream: Bool)
        case priority
        case rstStream
        case windowUpdate
        /// A PUSH_PROMISE that reserves this stream (the promised stream, not the one the
        /// frame is sent on).
        case pushPromise
    }

    public enum Event: Hashable, Sendable {
        /// The peer sent the frame.
        case received(Frame)
        /// This endpoint is about to send the frame.
        case sent(Frame)
    }

    /// What the caller does with the frame.
    public enum Action: Hashable, Sendable {
        /// Process it (deliver or send it).
        case proceed
        /// Drop it: a frame that arrived on a closed stream and is allowed there, or a local
        /// frame for a stream that has already closed (for example a response racing the
        /// peer's RST_STREAM). Received DATA still counts toward connection flow control and
        /// a received header block must still be HPACK-decoded.
        case ignore
        /// Send RST_STREAM with this code (RFC 9113 §5.4.2). The stream is now closed.
        case streamError(HTTP2ErrorCode)
        /// Send GOAWAY with this code and close the connection (RFC 9113 §5.4.1).
        /// `INTERNAL_ERROR` means this endpoint tried to send a frame its state forbids.
        case connectionError(HTTP2ErrorCode)
    }

    public private(set) var state: State
    /// Whether the peer has sent a header block on this stream; the next one is trailers.
    public private(set) var hasReceivedHeaders: Bool

    public init(state: State = .idle) {
        self.state = state
        self.hasReceivedHeaders = false
    }

    public mutating func handle(_ event: Event) -> Action {
        switch event {
        case .received(let frame): return receive(frame)
        case .sent(let frame): return send(frame)
        }
    }

    // MARK: Received frames

    private mutating func receive(_ frame: Frame) -> Action {
        switch state {
        case .idle:
            switch frame {
            case .headers(let endStream):
                hasReceivedHeaders = true
                state = endStream ? .halfClosedRemote : .open
                return .proceed
            case .priority:
                return .proceed
            case .pushPromise:
                state = .reservedRemote
                return .proceed
            case .data, .rstStream, .windowUpdate:
                // §5.1 idle: anything but HEADERS and PRIORITY.
                return .connectionError(.protocolError)
            }

        case .reservedLocal:
            switch frame {
            case .rstStream:
                state = .closed(.resetReceived)
                return .proceed
            case .priority, .windowUpdate:
                return .proceed
            case .headers, .data, .pushPromise:
                return .connectionError(.protocolError)
            }

        case .reservedRemote:
            switch frame {
            case .headers(let endStream):
                hasReceivedHeaders = true
                state = endStream ? .closed(.endStream) : .halfClosedLocal
                return .proceed
            case .rstStream:
                state = .closed(.resetReceived)
                return .proceed
            case .priority:
                return .proceed
            case .data, .windowUpdate, .pushPromise:
                return .connectionError(.protocolError)
            }

        case .open, .halfClosedLocal:
            let local = state == .halfClosedLocal
            switch frame {
            case .headers(let endStream):
                if hasReceivedHeaders && !endStream {
                    // A second header block is trailers and must end the stream (§8.1).
                    return reset(.protocolError)
                }
                hasReceivedHeaders = true
                if endStream { state = local ? .closed(.endStream) : .halfClosedRemote }
                return .proceed
            case .data(let endStream):
                if endStream { state = local ? .closed(.endStream) : .halfClosedRemote }
                return .proceed
            case .rstStream:
                state = .closed(.resetReceived)
                return .proceed
            case .priority, .windowUpdate:
                return .proceed
            case .pushPromise:
                // A promised stream is idle by definition (§8.4).
                return .connectionError(.protocolError)
            }

        case .halfClosedRemote:
            switch frame {
            case .headers, .data:
                return reset(.streamClosed)
            case .rstStream:
                state = .closed(.resetReceived)
                return .proceed
            case .priority, .windowUpdate:
                return .proceed
            case .pushPromise:
                return .connectionError(.protocolError)
            }

        case .closed(let reason):
            switch frame {
            case .priority:
                return .proceed
            case .pushPromise:
                return .connectionError(.protocolError)
            case .rstStream, .windowUpdate:
                return .ignore
            case .headers, .data:
                switch reason {
                case .resetSent: return .ignore
                case .resetReceived: return reset(.streamClosed)
                case .endStream: return .connectionError(.streamClosed)
                }
            }
        }
    }

    /// Moves to closed for an RST_STREAM the caller will send.
    private mutating func reset(_ code: HTTP2ErrorCode) -> Action {
        state = .closed(.resetSent)
        return .streamError(code)
    }

    // MARK: Sent frames

    private mutating func send(_ frame: Frame) -> Action {
        if case .priority = frame { return .proceed }  // Allowed in every state (§5.1).
        switch state {
        case .idle:
            switch frame {
            case .headers(let endStream):
                state = endStream ? .halfClosedLocal : .open
                return .proceed
            case .pushPromise:
                state = .reservedLocal
                return .proceed
            default:
                return .connectionError(.internalError)
            }

        case .reservedLocal:
            switch frame {
            case .headers(let endStream):
                state = endStream ? .closed(.endStream) : .halfClosedRemote
                return .proceed
            case .rstStream:
                state = .closed(.resetSent)
                return .proceed
            default:
                return .connectionError(.internalError)
            }

        case .reservedRemote:
            switch frame {
            case .rstStream:
                state = .closed(.resetSent)
                return .proceed
            case .windowUpdate:
                return .proceed
            default:
                return .connectionError(.internalError)
            }

        case .open, .halfClosedRemote:
            let remote = state == .halfClosedRemote
            switch frame {
            case .headers(let endStream), .data(let endStream):
                if endStream { state = remote ? .closed(.endStream) : .halfClosedLocal }
                return .proceed
            case .rstStream:
                state = .closed(.resetSent)
                return .proceed
            case .windowUpdate:
                return .proceed
            case .pushPromise, .priority:
                return .connectionError(.internalError)
            }

        case .halfClosedLocal:
            switch frame {
            case .rstStream:
                state = .closed(.resetSent)
                return .proceed
            case .windowUpdate:
                return .proceed
            default:
                return .connectionError(.internalError)
            }

        case .closed:
            // Only PRIORITY may be sent on a closed stream. Anything else lost a race with the
            // close (a response after the peer's RST_STREAM) and is dropped.
            return .ignore
        }
    }
}
