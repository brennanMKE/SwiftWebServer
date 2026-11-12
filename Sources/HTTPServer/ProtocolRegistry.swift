public import HTTPCore
import Synchronization

/// The protocols a server speaks, and the once-per-connection choice between them
/// (docs/ROADMAP.md §5.1, §5.2).
///
/// Selection, in order:
/// 1. A TLS connection with a negotiated ALPN token uses the first protocol listing it (#0088).
/// 2. A TLS connection without one (the client offered no ALPN) or with a token no protocol
///    lists uses the first protocol listing `http/1.1`, the TLS default (RFC 7301 §3.2 leaves
///    the choice to the server).
/// 3. With a single protocol, it serves every connection; nothing is read ahead.
/// 4. Otherwise the first bytes are sniffed: each protocol's
///    ``ConnectionProtocol/matchesCleartextPreface(_:)`` is asked in registration order, and
///    the first one that has not ruled the bytes out decides: ``SniffResult/match`` selects it,
///    ``SniffResult/needMoreBytes`` reads more (even if a later protocol already matches). So
///    `[HTTP2(), HTTP1()]` routes a preface split anywhere to HTTP/2. The sniffed bytes are
///    replayed to the chosen protocol.
///    A client that sends too little within ``sniffTimeout`` is closed.
///
/// A connection no protocol accepts is closed with ``CloseReason/protocolError``.
///
/// ``alpnTokens`` is what a TLS listener should offer: `TLSConfiguration(alpn:)` in
/// NetworkTransport. `h2` is offered when `HTTP2` is registered (#0042).
public struct ProtocolRegistry: Sendable {
    /// The registered protocols, in priority order.
    public let protocols: [any ConnectionProtocol]
    /// Most bytes read while sniffing before giving up.
    public let sniffLimit: Int
    /// How long sniffing may wait for the first bytes before the connection is closed
    /// (`nil` waits indefinitely). Defaults to the HTTP/1.1 header timeout (#0082), so a client
    /// that connects and sends nothing is closed as promptly as one that stalls in a head.
    public let sniffTimeout: Duration?

    /// The ALPN token TLS connections fall back to when none was negotiated.
    public static let defaultALPN = "http/1.1"

    public init(_ protocols: [any ConnectionProtocol], sniffLimit: Int = 64, sniffTimeout: Duration? = .seconds(10)) {
        precondition(sniffLimit > 0, "sniffLimit must be positive")
        self.protocols = protocols
        self.sniffLimit = sniffLimit
        self.sniffTimeout = sniffTimeout
    }

    /// The ALPN tokens of every registered protocol, in registration (preference) order,
    /// without duplicates.
    public var alpnTokens: [String] {
        var tokens: [String] = []
        for proto in protocols {
            for token in type(of: proto).alpnTokens where !tokens.contains(token) {
                tokens.append(token)
            }
        }
        return tokens
    }

    /// The outcome of ``select(alpn:preface:)``.
    public enum Selection: Sendable, Hashable {
        /// Serve with `protocols[index]`.
        case selected(index: Int)
        /// Read more bytes and ask again.
        case needMoreBytes
        /// No protocol accepts the connection.
        case unsupported
    }

    /// Chooses a protocol from the negotiated ALPN token or the bytes read so far. Pure.
    ///
    /// `secure` marks a TLS connection: an absent or unknown token then falls back to the
    /// `http/1.1` protocol instead of sniffing. Without `secure`, an unknown token is
    /// ``Selection/unsupported``.
    public func select(alpn: String?, secure: Bool = false, preface: borrowing ByteBuffer) -> Selection {
        if let alpn {
            if let index = index(forALPN: alpn) { return .selected(index: index) }
            if !secure { return .unsupported }
        }
        if secure, let index = index(forALPN: Self.defaultALPN) { return .selected(index: index) }
        if protocols.count == 1 { return .selected(index: 0) }
        for (index, proto) in protocols.enumerated() {
            switch type(of: proto).matchesCleartextPreface(preface) {
            case .match: return .selected(index: index)
            // An earlier protocol may still match: it has priority over later ones that
            // already do (HTTP/1.1 matches `PRI ` long before the HTTP/2 preface is complete).
            case .needMoreBytes: return .needMoreBytes
            case .noMatch: continue
            }
        }
        return .unsupported
    }

    private func index(forALPN token: String) -> Int? {
        protocols.firstIndex { type(of: $0).alpnTokens.contains(token) }
    }

    /// Picks the protocol for `transport` and runs it until the connection ends.
    public func serve<T: ByteStreamTransport, H: HTTPHandler>(
        _ transport: T, handler: H, context: ConnectionContext
    ) async {
        let info = transport.info
        let empty = ByteBuffer()
        switch select(alpn: info.negotiatedALPN, secure: info.isSecure, preface: empty) {
        case .selected(let index):
            await Self.run(protocols[index], transport, handler: handler, context: context)
            return
        case .unsupported:
            await transport.close(.protocolError)
            return
        case .needMoreBytes:
            break
        }

        let outcome: SniffOutcome
        if let sniffTimeout {
            outcome = await sniff(transport, timeout: sniffTimeout)
        } else {
            outcome = await sniff(transport)
        }
        switch outcome {
        case .selected(let index, let preface):
            let replaying = PrefixedTransport(base: transport, prefix: preface)
            await Self.run(protocols[index], replaying, handler: handler, context: context)
        case .unsupported:
            await transport.close(.protocolError)
        case .failed:
            await transport.close(.abort)
        case .timedOut:
            await transport.close(.timeout)
        }
    }

    /// How sniffing ended.
    enum SniffOutcome: Sendable {
        case selected(index: Int, preface: ByteBuffer)
        case unsupported
        case failed
        case timedOut
    }

    /// Sniffs, giving up after `timeout` (#0088; the gap the #0082 report flagged). The timer
    /// is a sibling task that exists only while sniffing, which happens only for cleartext
    /// connections with more than one protocol registered.
    func sniff<T: ByteStreamTransport>(_ transport: T, timeout: Duration) async -> SniffOutcome {
        await withTaskGroup(of: SniffOutcome.self) { group in
            group.addTask { await self.sniff(transport) }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                } catch {
                    return .failed   // cancelled: the sniff finished first
                }
            }
            let first = await group.next() ?? .failed
            group.cancelAll()
            return first
        }
    }

    /// Reads until a protocol matches, none can, `sniffLimit` bytes arrive, or the peer ends.
    func sniff<T: ByteStreamTransport>(_ transport: T) async -> SniffOutcome {
        var preface = ByteBuffer(capacity: sniffLimit)
        while preface.readableBytes < sniffLimit {
            let received: Int
            do {
                received = try await transport.receive(into: &preface, maxLength: sniffLimit - preface.readableBytes)
            } catch {
                return .failed
            }
            if received == 0 { break }
            switch select(alpn: nil, preface: preface) {
            case .selected(let index):
                return .selected(index: index, preface: preface)
            case .unsupported:
                return .unsupported
            case .needMoreBytes:
                continue
            }
        }
        return .unsupported
    }

    private static func run<P: ConnectionProtocol, T: ByteStreamTransport, H: HTTPHandler>(
        _ proto: P, _ transport: T, handler: H, context: ConnectionContext
    ) async {
        await proto.run(transport, handler: handler, context: context)
    }
}

/// A transport that first returns bytes already read from `base` (while sniffing), then reads
/// from `base`.
final class PrefixedTransport<Base: ByteStreamTransport>: ByteStreamTransport {
    let base: Base
    private let prefix: Mutex<ByteBuffer>

    init(base: Base, prefix: ByteBuffer) {
        self.base = base
        self.prefix = Mutex(prefix)
    }

    var info: ConnectionInfo { base.info }

    func receive(into buffer: inout ByteBuffer, maxLength: Int) async throws -> Int {
        precondition(maxLength > 0, "maxLength must be positive")
        let replayed = prefix.withLock { prefix -> Int in
            guard !prefix.isEmpty else { return 0 }
            let count = min(maxLength, prefix.readableBytes)
            buffer.append(ByteView(offset: prefix.readerIndex, length: count), from: prefix)
            prefix.moveReaderIndex(forwardBy: count)
            if prefix.isEmpty { prefix = ByteBuffer() }
            return count
        }
        if replayed > 0 { return replayed }
        return try await base.receive(into: &buffer, maxLength: maxLength)
    }

    func send(_ bytes: ByteBuffer, endOfStream: Bool) async throws {
        try await base.send(bytes, endOfStream: endOfStream)
    }

    func sendFile(_ region: FileRegion) async throws {
        try await base.sendFile(region)
    }

    func close(_ reason: CloseReason) async {
        await base.close(reason)
    }
}
