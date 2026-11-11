public import HTTPCore

/// The HTTP/1.1 connection state machine (docs/ROADMAP.md §5.4): which exchange the
/// connection is in, whether it persists after the current response (RFC 9112 §9.3), and what
/// the runner does next.
///
/// A pure value type: ``handle(_:)`` takes one ``Event`` and returns one ``Action``, with no I/O
/// and no `await`. The runner (``HTTP1``) owns the transport, the buffers, the parser and the
/// serializer, reports what happened as events, and performs the returned actions.
///
/// ```
///           ┌──────── needMoreBytes ───────┐
///           ▼                              │
///   idle ──bytes──▶ readingHead ──head──▶ handling ──response──▶ writing ──sent──▶ idle
///     │                 │                    │                      │
///     │            parse error          handler throws          close / tunnel
///     ▼                 ▼                    ▼                      ▼
///   closing ◀───────────┴────────────────────┘            closing / tunnelled
/// ```
///
/// - ``State/readingBody(_:)`` is the hook for request bodies (#0081). Until then a request
///   with a body is answered with ``bodyNotSupportedStatus(for:)`` and the connection closes.
/// - ``State/tunnelled`` is the hook for protocol switches (#0108): after a `.tunnel` response
///   the byte stream belongs to the tunnel closure and no more HTTP is read.
public struct HTTP1Connection: Sendable, Hashable {
    /// Where the connection is.
    public enum State: Sendable, Hashable {
        /// Between requests, with no byte of the next head buffered.
        case idle
        /// Part of a request head is buffered.
        case readingHead
        /// The handler is producing the response to `exchange`.
        case handling(Exchange)
        /// The handler is reading the request body (#0081). Not entered yet.
        case readingBody(Exchange)
        /// The response to `exchange` is being serialized and sent.
        case writing(Exchange)
        /// The connection ends with `reason` once buffered output is flushed.
        case closing(CloseReason)
        /// The byte stream belongs to a `.tunnel` closure; no more HTTP.
        case tunnelled
    }

    /// One request/response exchange.
    public struct Exchange: Sendable, Hashable {
        public var method: HTTPMethod
        public var version: HTTP1Version
        /// What the response will say about the connection. Decided from the request when
        /// the head arrives, and possibly downgraded to ``HTTP1ResponseContext/Persistence/close``
        /// by the response or by draining.
        public var persistence: HTTP1ResponseContext.Persistence
        /// True when the response hands the byte stream to a tunnel.
        public var isTunnel: Bool

        @inlinable
        public init(method: HTTPMethod, version: HTTP1Version,
                    persistence: HTTP1ResponseContext.Persistence, isTunnel: Bool = false) {
            self.method = method
            self.version = version
            self.persistence = persistence
            self.isTunnel = isTunnel
        }
    }

    /// The facts about a request head that the connection decides on.
    public struct RequestSummary: Sendable, Hashable {
        public var method: HTTPMethod
        public var version: HTTP1Version
        public var framing: HTTP1RequestFraming
        /// The `Connection` field lists `close`.
        public var connectionClose: Bool
        /// The `Connection` field lists `keep-alive` (the HTTP/1.0 opt-in).
        public var connectionKeepAlive: Bool

        @inlinable
        public init(method: HTTPMethod = .get, version: HTTP1Version = .http1_1,
                    framing: HTTP1RequestFraming = .none,
                    connectionClose: Bool = false, connectionKeepAlive: Bool = false) {
            self.method = method
            self.version = version
            self.framing = framing
            self.connectionClose = connectionClose
            self.connectionKeepAlive = connectionKeepAlive
        }

        /// Summarizes a parsed head and its fields.
        @inlinable
        public init(head: HTTP1RequestHead, fields: some HTTPFieldCollection) {
            var close = false
            var keepAlive = false
            if fields.contains(.connection) {
                close = fields.containsListElement("close", in: .connection)
                keepAlive = fields.containsListElement("keep-alive", in: .connection)
            }
            self.init(method: head.method, version: head.version, framing: head.framing,
                      connectionClose: close, connectionKeepAlive: keepAlive)
        }

        /// Whether the client asks for the connection to persist (RFC 9112 §9.3): `close`
        /// ends it; otherwise HTTP/1.1 persists by default and HTTP/1.0 only with `keep-alive`.
        @inlinable
        public var wantsPersistence: Bool {
            if connectionClose { return false }
            switch version {
            case .http1_1: return true
            case .http1_0: return connectionKeepAlive
            }
        }

        /// True when the head announces content (#0081 reads it).
        @inlinable
        public var hasBody: Bool {
            switch framing {
            case .none: false
            case .contentLength(let length): length > 0
            case .chunked: true
            }
        }
    }

    /// How the handler's response is delimited, as far as persistence is concerned.
    public enum ResponseKind: Sendable, Hashable {
        /// The length is known (empty, bytes, file, or a stream with a length).
        case delimited
        /// A stream of unknown length: chunked for HTTP/1.1. HTTP/1.0 has no chunked coding,
        /// so there the body is delimited by closing the connection.
        case unknownLength
        /// A `.tunnel` body: the byte stream is handed over after the head.
        case tunnel
    }

    /// Something that happened on the connection.
    public enum Event: Sendable, Hashable {
        /// The parser needs more bytes; `headStarted` is true when part of a head is buffered.
        case needMoreBytes(headStarted: Bool)
        /// A complete head arrived.
        case head(RequestSummary)
        /// The buffered head is invalid.
        case parseError(HTTP1ParseError)
        /// The handler returned a response of this kind.
        case response(ResponseKind)
        /// The handler threw, or returned a response this connection cannot send.
        case handlerFailed
        /// The response (or error response) is in the output buffer or sent.
        case responseWritten
        /// The peer finished sending (receive returned 0).
        case endOfStream
        /// A receive threw.
        case receiveFailed
        /// A send threw.
        case sendFailed
        /// The server started draining.
        case shutdown
    }

    /// What the runner does next.
    public enum Action: Sendable {
        /// Keep going: parse the next buffered head, or receive more bytes.
        case proceed
        /// Call the handler with the request.
        case callHandler
        /// Serialize the handler's response with this context.
        case writeResponse(HTTP1ResponseContext)
        /// Serialize an empty response with this status and context (which says `close`),
        /// without calling the handler. Then report ``Event/responseWritten``.
        case writeError(HTTPStatus, HTTP1ResponseContext)
        /// Flush the output, then hand the byte stream to the response's tunnel closure.
        case startTunnel
        /// Flush the output, then close the transport with this reason.
        case close(CloseReason)
    }

    public private(set) var state: State
    /// True once ``Event/shutdown`` arrived: every later response says `close`.
    public private(set) var isDraining: Bool
    /// Request heads accepted so far.
    public private(set) var requestCount: Int

    public init() {
        state = .idle
        isDraining = false
        requestCount = 0
    }

    /// The status answering a request whose body this connection cannot read yet.
    ///
    /// Hook for #0081: request bodies are not read yet, so a `Content-Length` body gets
    /// `413 Content Too Large` and a chunked body `501 Not Implemented`, and the connection
    /// closes (the unread body bytes cannot be skipped safely). #0081 replaces this with
    /// ``State/readingBody(_:)``.
    @inlinable
    public static func bodyNotSupportedStatus(for framing: HTTP1RequestFraming) -> HTTPStatus {
        if case .chunked = framing { return .notImplemented }
        return .contentTooLarge
    }

    public mutating func handle(_ event: Event) -> Action {
        switch event {
        case .needMoreBytes(let headStarted):
            switch state {
            case .idle, .readingHead:
                state = headStarted ? .readingHead : .idle
                return .proceed
            default:
                return unexpected(event)
            }

        case .head(let summary):
            switch state {
            case .idle, .readingHead:
                requestCount &+= 1
                let persistence: HTTP1ResponseContext.Persistence =
                    summary.wantsPersistence && !isDraining ? .keepAlive : .close
                if summary.hasBody {
                    state = .closing(.normal)
                    return .writeError(Self.bodyNotSupportedStatus(for: summary.framing),
                                       HTTP1ResponseContext(requestMethod: summary.method, persistence: .close))
                }
                state = .handling(Exchange(method: summary.method, version: summary.version, persistence: persistence))
                return .callHandler
            default:
                return unexpected(event)
            }

        case .parseError(let error):
            switch state {
            case .idle, .readingHead:
                state = .closing(.protocolError)
                return .writeError(error.status, HTTP1ResponseContext(requestMethod: .get, persistence: .close))
            default:
                return unexpected(event)
            }

        case .response(let kind):
            guard case .handling(var exchange) = state else { return unexpected(event) }
            if isDraining { exchange.persistence = .close }
            switch kind {
            case .delimited:
                break
            case .unknownLength:
                if exchange.version == .http1_0 { exchange.persistence = .close }
            case .tunnel:
                exchange.isTunnel = true
            }
            state = .writing(exchange)
            return .writeResponse(HTTP1ResponseContext(requestMethod: exchange.method, persistence: exchange.persistence))

        case .handlerFailed:
            guard case .handling(let exchange) = state else { return unexpected(event) }
            state = .closing(.normal)
            return .writeError(.internalServerError,
                               HTTP1ResponseContext(requestMethod: exchange.method, persistence: .close))

        case .responseWritten:
            switch state {
            case .writing(let exchange):
                if exchange.isTunnel {
                    state = .tunnelled
                    return .startTunnel
                }
                if exchange.persistence == .close {
                    state = .closing(.normal)
                    return .close(.normal)
                }
                state = .idle
                return .proceed
            case .closing(let reason):
                return .close(reason)
            default:
                return unexpected(event)
            }

        case .endOfStream:
            // At a request boundary or mid-head: nothing to answer, close quietly.
            switch state {
            case .closing(let reason):
                return .close(reason)
            case .tunnelled:
                return unexpected(event)
            default:
                state = .closing(.normal)
                return .close(.normal)
            }

        case .receiveFailed, .sendFailed:
            state = .closing(.abort)
            return .close(.abort)

        case .shutdown:
            isDraining = true
            switch state {
            case .idle:
                state = .closing(.shutdown)
                return .close(.shutdown)
            case .closing(let reason):
                return .close(reason)
            default:
                // The exchange in progress finishes; its response says `close`.
                return .proceed
            }
        }
    }

    /// An event that cannot happen in the current state is a runner bug: debug builds trap,
    /// release builds end the connection.
    mutating func unexpected(_ event: Event) -> Action {
        assertionFailure("HTTP1Connection: \(event) in state \(state)")
        state = .closing(.protocolError)
        return .close(.protocolError)
    }
}

extension HTTP1Connection.Action: Equatable {
    /// Statuses compare by code and reason phrase.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.proceed, .proceed), (.callHandler, .callHandler), (.startTunnel, .startTunnel):
            return true
        case (.writeResponse(let a), .writeResponse(let b)):
            return a == b
        case (.writeError(let s, let a), .writeError(let t, let b)):
            return s.code == t.code && a == b
                && s.withReasonPhrase { x in t.withReasonPhrase { y in x.count == y.count && x.indices.allSatisfy { x[$0] == y[$0] } } }
        case (.close(let a), .close(let b)):
            return a == b
        default:
            return false
        }
    }
}
