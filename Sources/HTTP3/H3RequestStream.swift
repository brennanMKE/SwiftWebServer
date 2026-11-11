/// The frame sequence of one HTTP/3 request stream (RFC 9114 §4.1).
///
/// A request is HEADERS, then zero or more DATA frames, then optionally one trailing HEADERS,
/// then the end of the stream (FIN). A value type with no I/O: the runner parses frames with
/// ``H3FrameParser`` and reports them here; each ``handle(_:)`` returns one ``Action``.
///
/// - A frame out of sequence (DATA before HEADERS, anything after the trailers) is the
///   connection error `H3_FRAME_UNEXPECTED` (§4.1).
/// - A stream that ends before its HEADERS is the stream error `H3_REQUEST_INCOMPLETE`.
/// - DATA beyond the request's `content-length`, or a FIN short of it, is the stream error
///   `H3_MESSAGE_ERROR` (§4.1.2).
///
/// Unknown and reserved frame types never reach it: the parser skips them.
public struct H3RequestStream: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Waiting for the request's HEADERS frame.
        case awaitingHeaders
        /// The head was decoded; DATA or trailers may follow.
        case receivingBody
        /// The trailing HEADERS frame arrived; only FIN may follow.
        case receivedTrailers
        /// FIN arrived after a complete request.
        case finished
        /// A stream or connection error was returned; later events are ignored.
        case failed
    }

    public enum Event: Sendable, Equatable {
        /// A complete HEADERS frame.
        case headers
        /// The request head decoded; `contentLength` is its `content-length`, if any.
        case requestHead(contentLength: UInt64?)
        /// A DATA frame header announcing `length` payload bytes.
        case dataFrame(length: UInt64)
        /// The peer finished the stream (FIN) at a frame boundary.
        case endOfStream
    }

    public enum Action: Sendable, Equatable {
        case none
        /// Decode the HEADERS frame as the request head and validate it.
        case decodeRequestHead
        /// Decode the HEADERS frame as trailers (no pseudo-header fields allowed).
        case decodeTrailers
        /// Deliver the DATA frame's payload to the request body.
        case deliverData
        /// The request body is complete.
        case finishBody
        /// Reset the stream with this code; the connection continues.
        case streamError(HTTP3Error)
        /// Close the connection with this code.
        case connectionError(HTTP3Error)
    }

    public private(set) var state: State = .awaitingHeaders
    /// The declared `content-length`, if any.
    public private(set) var contentLength: UInt64?
    /// DATA payload bytes announced so far.
    public private(set) var receivedLength: UInt64 = 0

    public init() {}

    public mutating func handle(_ event: Event) -> Action {
        switch (state, event) {
        case (.failed, _), (.finished, _):
            return .none

        case (.awaitingHeaders, .headers):
            return .decodeRequestHead
        case (.awaitingHeaders, .requestHead(let length)):
            state = .receivingBody
            contentLength = length
            return .none
        case (.awaitingHeaders, .dataFrame):
            return fail(.connectionError(.frameUnexpected))
        case (.awaitingHeaders, .endOfStream):
            return fail(.streamError(.requestIncomplete))

        case (.receivingBody, .headers):
            state = .receivedTrailers
            return .decodeTrailers
        case (.receivingBody, .dataFrame(let length)):
            let (total, overflow) = receivedLength.addingReportingOverflow(length)
            if overflow { return fail(.streamError(.messageError)) }
            receivedLength = total
            if let contentLength, total > contentLength { return fail(.streamError(.messageError)) }
            return .deliverData
        case (.receivingBody, .endOfStream), (.receivedTrailers, .endOfStream):
            if let contentLength, contentLength != receivedLength { return fail(.streamError(.messageError)) }
            state = .finished
            return .finishBody

        case (.receivedTrailers, .headers), (.receivedTrailers, .dataFrame):
            return fail(.connectionError(.frameUnexpected))

        case (.receivingBody, .requestHead), (.receivedTrailers, .requestHead):
            preconditionFailure("requestHead reported twice")
        }
    }

    /// Marks the stream failed (for errors found outside the state machine, such as a
    /// malformed head) so later events are ignored.
    public mutating func markFailed() {
        state = .failed
    }

    mutating func fail(_ action: Action) -> Action {
        state = .failed
        return action
    }
}
