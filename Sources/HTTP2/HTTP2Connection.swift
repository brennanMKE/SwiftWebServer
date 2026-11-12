/// The connection-level state machine of an HTTP/2 server connection (RFC 9113 §3.4, §5, §6).
///
/// A value type with no I/O and no `await` (docs/ROADMAP.md §5.4): every frame the reader
/// parses, every frame a stream task wants to send, and every timer goes through
/// ``handle(_:)``, which returns one ``Action``. The runtime (`HTTP2ConnectionDriver`) keeps it
/// in a `Mutex` next to the HPACK encoder and the outbound queue, so a decision and the frames
/// it produces are enqueued in one critical section.
///
/// It owns:
/// - the SETTINGS exchange (§6.5): ``Event/start`` sends ours; the peer's are validated by the
///   frame parser, applied and acknowledged; ours apply only once acknowledged
///   (``Action/applyLocalSettings(_:)``), and ``Event/settingsTimeout`` before that is
///   `GOAWAY(SETTINGS_TIMEOUT)`;
/// - "the first frame after the preface is SETTINGS" (§3.4): anything else is `PROTOCOL_ERROR`;
/// - the ``HTTP2StreamTable`` (stream states and identifier rules);
/// - connection-level receive accounting: DATA beyond the receive window is
///   `FLOW_CONTROL_ERROR`. Padding and DATA that is not delivered (ignored or refused streams)
///   are credited back at once; DATA delivered to a request body is credited when the handler
///   consumes it (``Event/bodyConsumed(streamID:length:streamIncrement:)``). Credit goes back
///   with a connection WINDOW_UPDATE once half the window is pending;
/// - send windows (§6.9): the connection window and one window per stream with a response in
///   progress, moved by WINDOW_UPDATE and by changes to the peer's INITIAL_WINDOW_SIZE;
/// - PING replies, GOAWAY on connection errors (once), and the graceful GOAWAY.
///
/// After a connection error everything is ignored and every local send is dropped.
public struct HTTP2Connection: Sendable {
    public struct Configuration: Hashable, Sendable {
        /// The SETTINGS frame sent first.
        public var localSettings: HTTP2Settings
        /// The connection receive window; the server raises it from 65,535 after its SETTINGS.
        public var connectionWindowSize: UInt32
        /// Stream table limits; `maxConcurrentStreams` should match the advertised setting.
        public var streams: HTTP2StreamTable.Configuration

        public init(
            localSettings: HTTP2Settings = HTTP2Settings(),
            connectionWindowSize: UInt32 = HTTP2Connection.defaultWindowSize,
            streams: HTTP2StreamTable.Configuration = .init()
        ) {
            precondition(connectionWindowSize >= HTTP2Connection.defaultWindowSize
                         && connectionWindowSize <= HTTP2Settings.maxWindowSize,
                         "connectionWindowSize is 65,535 through 2^31-1")
            self.localSettings = localSettings
            self.connectionWindowSize = connectionWindowSize
            self.streams = streams
        }
    }

    /// The initial flow-control window of the connection and of every stream (§6.9.2).
    public static let defaultWindowSize: UInt32 = 65_535
    /// The SETTINGS_HEADER_TABLE_SIZE every peer starts with (§6.5.2).
    public static let defaultHeaderTableSize: UInt32 = 4_096

    /// What happened.
    public enum Event: Hashable, Sendable {
        /// The connection starts: send the server preface (our SETTINGS).
        case start
        /// The peer's SETTINGS (validated by ``HTTP2FrameParser``).
        case settings(HTTP2Settings)
        /// The peer acknowledged our SETTINGS.
        case settingsAck
        /// The settings timer fired.
        case settingsTimeout
        case ping(ack: Bool, opaqueData: UInt64)
        case goaway(lastStreamID: HTTP2StreamID, HTTP2ErrorCode)
        case windowUpdate(streamID: HTTP2StreamID, increment: UInt32)
        case rstStream(streamID: HTTP2StreamID, HTTP2ErrorCode)
        case priority(streamID: HTTP2StreamID)
        /// A complete header block (HEADERS and its CONTINUATIONs). `trailers` when it is the
        /// stream's second block (``HeaderBlockAssembler/Kind/trailers``).
        case headers(streamID: HTTP2StreamID, endStream: Bool, trailers: Bool)
        /// The start of a DATA frame: `dataLength` payload bytes; `flowControlledLength`
        /// includes padding.
        case data(streamID: HTTP2StreamID, dataLength: Int, flowControlledLength: Int, endStream: Bool)
        /// `length` bytes of DATA that ``Action/acceptData(connectionIncrement:)`` delivered were
        /// consumed by the handler (or discarded). Their connection credit is returned; the
        /// body also hands back `streamIncrement` of stream credit, sent while the peer may
        /// still send on the stream. The body's `next()` is the pull signal #0053 builds on.
        case bodyConsumed(streamID: HTTP2StreamID, length: Int, streamIncrement: UInt32?)
        /// A frame of an unknown type (ignored, but it is still "a frame" for §3.4).
        case unknownFrame
        /// A frame-level stream error reported by the parser.
        case streamError(HTTP2Error)
        /// A connection error found outside this machine (frame parser, header block
        /// assembler, HPACK, an invalid preface, the control-frame flood limit).
        case connectionError(HTTP2Error)

        /// A stream task is about to send its response HEADERS.
        case sendHeaders(streamID: HTTP2StreamID, endStream: Bool)
        /// A stream task wants to send up to `length` bytes of DATA (`length` may be 0 with
        /// `endStream`). The grant is capped by both send windows and the peer's
        /// MAX_FRAME_SIZE.
        case sendData(streamID: HTTP2StreamID, length: Int, endStream: Bool)
        /// A stream task resets its stream (for example, its body failed after HEADERS).
        case sendReset(streamID: HTTP2StreamID, HTTP2ErrorCode)
        /// A stream task finished its response. If the peer is still sending the request,
        /// the stream is reset with `NO_ERROR` (§8.1) so its DATA stops.
        case responseFinished(streamID: HTTP2StreamID)
        /// The server drains (or the connection was idle): send the first GOAWAY(NO_ERROR) with
        /// the largest stream identifier (§6.8), so the client stops opening streams while
        /// streams already in flight are still accepted. The runtime then waits for a PING
        /// round trip and sends ``finishShutdown``.
        case shutdown
        /// Send the final GOAWAY(NO_ERROR) with the last stream processed; streams above it
        /// are refused from now on.
        case finishShutdown
        /// Send a PING (for a round-trip measurement or the graceful shutdown) whose ACK must
        /// echo `opaqueData`.
        case sendPing(opaqueData: UInt64)
        /// The PING with `opaqueData` will not be awaited any more (timed out or cancelled).
        case pingAbandoned(opaqueData: UInt64)
    }

    /// What the runtime does. Exactly one per event.
    public enum Action: Hashable, Sendable {
        /// Nothing to send.
        case none
        /// Send our SETTINGS, then a connection WINDOW_UPDATE when `windowIncrement` is set.
        case sendPreface(HTTP2Settings, windowIncrement: UInt32?)
        /// Apply the peer's HEADER_TABLE_SIZE (if present) to the HPACK encoder and send a
        /// SETTINGS ACK, in one critical section. Send windows may have grown: wake writers.
        case acknowledgeSettings(headerTableSize: UInt32?)
        /// The peer acknowledged our SETTINGS: they are in force now. Apply the frame size and
        /// header table limits to the frame parser and HPACK decoder.
        case applyLocalSettings(HTTP2Settings)
        case sendPingAck(opaqueData: UInt64)
        /// Send a PING (not an ACK) with `opaqueData`.
        case sendPing(opaqueData: UInt64)
        /// The peer acknowledged our PING with `opaqueData`.
        case pingAcknowledged(opaqueData: UInt64)
        /// Send a connection WINDOW_UPDATE of `connectionIncrement` and a WINDOW_UPDATE of
        /// `streamIncrement` on `streamID`, each when set.
        case sendWindowUpdate(connectionIncrement: UInt32?, streamID: HTTP2StreamID, streamIncrement: UInt32?)
        /// The DATA frame's payload belongs to the stream's request body: deliver it, and
        /// report it with ``Event/bodyConsumed(streamID:length:streamIncrement:)`` once
        /// consumed or discarded. `connectionIncrement` is credit to return now (padding).
        case acceptData(connectionIncrement: UInt32?)
        /// A trailer section completed the stream's request: decode it for the body.
        case acceptTrailers(streamID: HTTP2StreamID)
        /// A request head is complete on a new stream: decode it and serve it.
        case dispatch(streamID: HTTP2StreamID, endStream: Bool)
        /// Send RST_STREAM. `windowIncrement`, when set, is connection credit to return with a
        /// WINDOW_UPDATE at the same time (the frame was DATA).
        case resetStream(streamID: HTTP2StreamID, HTTP2ErrorCode, windowIncrement: UInt32?)
        /// A send window grew or a stream with a response in progress closed: wake writers
        /// waiting for window.
        case windowChanged
        /// Send GOAWAY for a connection error, then close the connection.
        case goaway(lastStreamID: HTTP2StreamID, HTTP2Error)
        /// Send GOAWAY(NO_ERROR) and keep serving the streams at or below `lastStreamID`. When
        /// `final`, close once the last of them ends; otherwise (the first of a graceful
        /// shutdown's two GOAWAYs) streams are still accepted.
        case gracefulGoaway(lastStreamID: HTTP2StreamID, final: Bool)
        /// A local HEADERS or RST_STREAM may be sent.
        case send
        /// Send DATA of `length` bytes with END_STREAM when `endStream`.
        case sendData(length: Int, endStream: Bool)
        /// No window for DATA: wait for ``windowChanged`` and ask again.
        case waitForWindow
        /// The stream (or the connection) is closed: do not send the frame, and stop writing
        /// the response.
        case drop
    }

    public let configuration: Configuration
    public private(set) var streams: HTTP2StreamTable

    /// Whether the peer's first SETTINGS frame arrived.
    public private(set) var receivedPeerSettings = false
    /// Whether our SETTINGS were sent and are waiting for the ACK.
    public private(set) var awaitingSettingsAck = false
    /// The local settings in force: protocol defaults until the peer acknowledged ours.
    public private(set) var appliedLocalSettings = HTTP2Settings()

    /// The peer's settings in force.
    public private(set) var peerInitialWindowSize = Int(HTTP2Connection.defaultWindowSize)
    public private(set) var peerMaxFrameSize = HTTP2Settings.defaultMaxFrameSize
    public private(set) var peerMaxHeaderListSize: UInt32?
    public private(set) var peerHeaderTableSize = HTTP2Connection.defaultHeaderTableSize

    /// Bytes the peer may still send on the connection before a WINDOW_UPDATE.
    public private(set) var connectionReceiveWindow = Int(HTTP2Connection.defaultWindowSize)
    /// Received DATA bytes not yet credited back.
    public private(set) var pendingReceiveCredit = 0
    /// Bytes this endpoint may still send on the connection.
    public private(set) var connectionSendWindow = Int(HTTP2Connection.defaultWindowSize)
    /// Send windows of streams with a response in progress.
    var sendWindows: [UInt32: Int] = [:]

    /// Set once a connection error was answered with GOAWAY: everything after is ignored.
    public private(set) var failed: HTTP2Error?
    /// Set once the final graceful GOAWAY was sent.
    public private(set) var goawaySent: HTTP2StreamID?
    /// Set once the first graceful GOAWAY was sent (or the final one).
    public private(set) var shutdownStarted = false
    /// The peer's GOAWAY, if any.
    public private(set) var peerGoaway: (lastStreamID: HTTP2StreamID, code: HTTP2ErrorCode)?
    /// Opaque data of our PINGs awaiting an ACK.
    public private(set) var outstandingPings: [UInt64] = []
    /// The most PINGs this endpoint has in flight at once.
    public static let maxOutstandingPings = 4

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        streams = HTTP2StreamTable(configuration: configuration.streams)
    }

    /// Whether the connection is closing because of a connection error.
    public var isFailed: Bool { failed != nil }

    /// The send window of `streamID`, if it has a response in progress.
    public func sendWindow(of streamID: HTTP2StreamID) -> Int? { sendWindows[streamID.rawValue] }

    /// The number of streams with a response in progress.
    public var respondingStreams: Int { sendWindows.count }

    public mutating func handle(_ event: Event) -> Action {
        if failed != nil {
            switch event {
            case .sendHeaders, .sendData, .sendReset: return .drop
            default: return .none
            }
        }
        switch event {
        case .start:
            awaitingSettingsAck = true
            let raise = Int(configuration.connectionWindowSize) - connectionReceiveWindow
            connectionReceiveWindow = Int(configuration.connectionWindowSize)
            return .sendPreface(configuration.localSettings, windowIncrement: raise > 0 ? UInt32(raise) : nil)

        case .settings(let settings):
            receivedPeerSettings = true
            return applyPeerSettings(settings)

        case .settingsAck:
            if let error = requirePeerSettings() { return error }
            guard awaitingSettingsAck else { return .none }  // Unsolicited: nothing to apply.
            awaitingSettingsAck = false
            appliedLocalSettings = configuration.localSettings
            return .applyLocalSettings(configuration.localSettings)

        case .settingsTimeout:
            guard awaitingSettingsAck else { return .none }
            return fail(.connection(.settingsTimeout, reason: "SETTINGS not acknowledged in time"))

        case .ping(let ack, let data):
            if let error = requirePeerSettings() { return error }
            guard ack else { return .sendPingAck(opaqueData: data) }
            // An ACK for a PING we did not send (or no longer wait for) is ignored (§6.7).
            guard let index = outstandingPings.firstIndex(of: data) else { return .none }
            outstandingPings.remove(at: index)
            return .pingAcknowledged(opaqueData: data)

        case .sendPing(let data):
            guard outstandingPings.count < Self.maxOutstandingPings, !outstandingPings.contains(data) else { return .none }
            outstandingPings.append(data)
            return .sendPing(opaqueData: data)

        case .pingAbandoned(let data):
            outstandingPings.removeAll { $0 == data }
            return .none

        case .goaway(let last, let code):
            if let error = requirePeerSettings() { return error }
            peerGoaway = (last, code)
            // The peer is closing the connection: answer with our final GOAWAY, refuse new
            // streams, let the ones in flight finish, then close.
            return finishShutdown()

        case .windowUpdate(let id, let increment):
            if let error = requirePeerSettings() { return error }
            return windowUpdate(id, increment)

        case .rstStream(let id, _):
            if let error = requirePeerSettings() { return error }
            switch streams.handle(.received(id, .rstStream)) {
            case .proceed:
                // The response, if any, stops; wake its writer so it sees the closed stream.
                return sendWindows.removeValue(forKey: id.rawValue) != nil ? .windowChanged : .none
            case .ignore: return .none
            case .streamError(let code): return reset(id, code)
            case .connectionError(let code): return fail(.connection(code, reason: "RST_STREAM on stream \(id)"))
            }

        case .priority(let id):
            if let error = requirePeerSettings() { return error }
            switch streams.handle(.received(id, .priority)) {
            case .proceed, .ignore: return .none
            case .streamError(let code): return reset(id, code)
            case .connectionError(let code): return fail(.connection(code, reason: "PRIORITY on stream \(id)"))
            }

        case .headers(let id, let endStream, let trailers):
            if let error = requirePeerSettings() { return error }
            let opensStream = id.isClientInitiated && id > streams.highestClientStreamID
            switch streams.handle(.received(id, .headers(endStream: endStream))) {
            case .proceed:
                if trailers { return .acceptTrailers(streamID: id) }
                sendWindows[id.rawValue] = peerInitialWindowSize
                return .dispatch(streamID: id, endStream: endStream)
            case .ignore:
                // A new stream above our final GOAWAY is not processed (§6.8). Refusing it tells
                // the client it may retry the request on a new connection (§8.7).
                if opensStream, let last = goawaySent, id > last {
                    return .resetStream(streamID: id, .refusedStream, windowIncrement: nil)
                }
                return .none
            case .streamError(let code): return reset(id, code)
            case .connectionError(let code): return fail(.connection(code, reason: "HEADERS on stream \(id)"))
            }

        case .data(let id, let dataLength, let length, let endStream):
            if let error = requirePeerSettings() { return error }
            return data(id, dataLength: dataLength, length: length, endStream: endStream)

        case .bodyConsumed(let id, let length, let streamIncrement):
            let connection = credit(length)
            var stream: UInt32?
            if let streamIncrement, let state = streams.stream(id)?.state, state == .open || state == .halfClosedLocal {
                stream = streamIncrement
            }
            guard connection != nil || stream != nil else { return .none }
            return .sendWindowUpdate(connectionIncrement: connection, streamID: id, streamIncrement: stream)

        case .unknownFrame:
            if let error = requirePeerSettings() { return error }
            return .none

        case .streamError(let error):
            if let error = requirePeerSettings() { return error }
            guard let id = error.streamID else { return fail(error) }
            return reset(id, error.code)

        case .connectionError(let error):
            return fail(error)

        case .sendHeaders(let id, let endStream):
            switch streams.handle(.sent(id, .headers(endStream: endStream))) {
            case .proceed:
                if endStream { sendWindows.removeValue(forKey: id.rawValue) }
                return .send
            case .ignore, .streamError:
                sendWindows.removeValue(forKey: id.rawValue)
                return .drop
            case .connectionError(let code):
                return fail(.connection(code, reason: "local HEADERS on stream \(id) in a forbidden state"))
            }

        case .sendData(let id, let length, let endStream):
            return sendData(id, length: length, endStream: endStream)

        case .sendReset(let id, let code):
            sendWindows.removeValue(forKey: id.rawValue)
            switch streams.handle(.sent(id, .rstStream)) {
            case .proceed: return .resetStream(streamID: id, code, windowIncrement: nil)
            default: return .drop
            }

        case .responseFinished(let id):
            sendWindows.removeValue(forKey: id.rawValue)
            guard streams.stream(id)?.state == .halfClosedLocal else { return .none }
            _ = streams.handle(.sent(id, .rstStream))
            return .resetStream(streamID: id, .noError, windowIncrement: nil)

        case .shutdown:
            guard goawaySent == nil, !shutdownStarted else { return .none }
            shutdownStarted = true
            return .gracefulGoaway(lastStreamID: HTTP2StreamID(HTTP2StreamID.maxValue), final: false)

        case .finishShutdown:
            return finishShutdown()
        }
    }

    // MARK: Shutdown

    /// The final GOAWAY: the last stream processed bounds the streams served.
    private mutating func finishShutdown() -> Action {
        guard goawaySent == nil else { return .none }
        shutdownStarted = true
        let last = streams.highestClientStreamID
        goawaySent = last
        _ = streams.handle(.goawaySent(lastStreamID: last))
        for id in sendWindows.keys where id > last.rawValue { sendWindows.removeValue(forKey: id) }
        return .gracefulGoaway(lastStreamID: last, final: true)
    }

    // MARK: Settings

    /// RFC 9113 §3.4: the first frame from the client is SETTINGS.
    private mutating func requirePeerSettings() -> Action? {
        guard !receivedPeerSettings else { return nil }
        return fail(.connection(.protocolError, reason: "first frame after the preface is not SETTINGS"))
    }

    private mutating func applyPeerSettings(_ settings: HTTP2Settings) -> Action {
        if let size = settings.initialWindowSize {
            // §6.9.2: the change applies to every stream send window, which may go negative but
            // not above 2^31 − 1.
            let delta = Int(size) - peerInitialWindowSize
            if delta != 0 {
                for (id, window) in sendWindows {
                    let updated = window + delta
                    if updated > Int(HTTP2Settings.maxWindowSize) {
                        return fail(.connection(.flowControlError, reason: "INITIAL_WINDOW_SIZE overflows a stream window"))
                    }
                    sendWindows[id] = updated
                }
            }
            peerInitialWindowSize = Int(size)
        }
        if let size = settings.maxFrameSize { peerMaxFrameSize = Int(size) }
        if let size = settings.maxHeaderListSize { peerMaxHeaderListSize = size }
        if let size = settings.headerTableSize { peerHeaderTableSize = size }
        // ENABLE_PUSH 0 or 1 is accepted (the parser rejects anything else); a server never
        // pushes, so its value does not matter. MAX_CONCURRENT_STREAMS limits server pushes only.
        return .acknowledgeSettings(headerTableSize: settings.headerTableSize)
    }

    // MARK: Flow control

    private mutating func windowUpdate(_ id: HTTP2StreamID, _ increment: UInt32) -> Action {
        if id.isConnection {
            let updated = connectionSendWindow + Int(increment)
            guard updated <= Int(HTTP2Settings.maxWindowSize) else {
                return fail(.connection(.flowControlError, reason: "connection send window above 2^31-1"))
            }
            connectionSendWindow = updated
            return .windowChanged
        }
        switch streams.handle(.received(id, .windowUpdate)) {
        case .proceed:
            guard let window = sendWindows[id.rawValue] else { return .none }
            let updated = window + Int(increment)
            guard updated <= Int(HTTP2Settings.maxWindowSize) else {
                sendWindows.removeValue(forKey: id.rawValue)
                _ = streams.handle(.sent(id, .rstStream))
                return .resetStream(streamID: id, .flowControlError, windowIncrement: nil)
            }
            sendWindows[id.rawValue] = updated
            return .windowChanged
        case .ignore: return .none
        case .streamError(let code): return reset(id, code)
        case .connectionError(let code): return fail(.connection(code, reason: "WINDOW_UPDATE on stream \(id)"))
        }
    }

    private mutating func data(_ id: HTTP2StreamID, dataLength: Int, length: Int, endStream: Bool) -> Action {
        // Connection-level accounting applies to every DATA frame, whatever the stream's state.
        connectionReceiveWindow -= length
        guard connectionReceiveWindow >= 0 else {
            return fail(.connection(.flowControlError, reason: "DATA beyond the connection window"))
        }
        switch streams.handle(.received(id, .data(endStream: endStream))) {
        case .proceed:
            // The payload goes to the request body and is credited as it is consumed; the
            // padding is credited now.
            return .acceptData(connectionIncrement: credit(length - dataLength))
        case .ignore:
            guard let increment = credit(length) else { return .none }
            return .sendWindowUpdate(connectionIncrement: increment, streamID: .connection, streamIncrement: nil)
        case .streamError(let code):
            sendWindows.removeValue(forKey: id.rawValue)
            return .resetStream(streamID: id, code, windowIncrement: credit(length))
        case .connectionError(let code):
            return fail(.connection(code, reason: "DATA on stream \(id)"))
        }
    }

    /// Adds `length` bytes of connection credit; returns the WINDOW_UPDATE increment once half
    /// the window is pending.
    private mutating func credit(_ length: Int) -> UInt32? {
        pendingReceiveCredit += length
        guard pendingReceiveCredit > 0, pendingReceiveCredit * 2 >= Int(configuration.connectionWindowSize) else {
            return nil
        }
        let increment = UInt32(pendingReceiveCredit)
        connectionReceiveWindow += pendingReceiveCredit
        pendingReceiveCredit = 0
        return increment
    }

    private mutating func sendData(_ id: HTTP2StreamID, length: Int, endStream: Bool) -> Action {
        precondition(length >= 0, "DATA length must not be negative")
        guard let window = sendWindows[id.rawValue] else { return .drop }
        var grant = 0
        if length > 0 {
            grant = Swift.min(length, peerMaxFrameSize, window, connectionSendWindow)
            guard grant > 0 else { return .waitForWindow }
        }
        let ends = endStream && grant == length
        switch streams.handle(.sent(id, .data(endStream: ends))) {
        case .proceed:
            connectionSendWindow -= grant
            if ends {
                sendWindows.removeValue(forKey: id.rawValue)
            } else {
                sendWindows[id.rawValue] = window - grant
            }
            return .sendData(length: grant, endStream: ends)
        case .ignore, .streamError:
            sendWindows.removeValue(forKey: id.rawValue)
            return .drop
        case .connectionError(let code):
            return fail(.connection(code, reason: "local DATA on stream \(id) in a forbidden state"))
        }
    }

    // MARK: Errors

    /// A stream error: the stream table already moved the stream to closed.
    private mutating func reset(_ id: HTTP2StreamID, _ code: HTTP2ErrorCode) -> Action {
        sendWindows.removeValue(forKey: id.rawValue)
        _ = streams.handle(.sent(id, .rstStream))
        return .resetStream(streamID: id, code, windowIncrement: nil)
    }

    private mutating func fail(_ error: HTTP2Error) -> Action {
        precondition(error.isConnectionError, "fail takes connection errors")
        failed = error
        sendWindows.removeAll()
        let last = Swift.min(streams.highestClientStreamID, goawaySent ?? HTTP2StreamID(HTTP2StreamID.maxValue))
        return .goaway(lastStreamID: last, error)
    }
}
