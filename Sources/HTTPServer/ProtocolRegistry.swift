public import HTTPCore
import Synchronization

/// The protocols a server speaks, and the once-per-connection choice between them
/// (docs/ROADMAP.md §5.1, §5.2).
///
/// Selection, in order:
/// 1. A TLS connection with a negotiated ALPN token uses the first protocol listing it.
/// 2. With a single protocol, it serves every connection; nothing is read ahead.
/// 3. Otherwise the first bytes are sniffed: each protocol's
///    ``ConnectionProtocol/matchesCleartextPreface(_:)`` is asked in registration order and the
///    first ``SniffResult/match`` wins. The sniffed bytes are replayed to the chosen protocol.
///
/// A connection no protocol accepts is closed with ``CloseReason/protocolError``.
public struct ProtocolRegistry: Sendable {
    /// The registered protocols, in priority order.
    public let protocols: [any ConnectionProtocol]
    /// Most bytes read while sniffing before giving up.
    public let sniffLimit: Int

    public init(_ protocols: [any ConnectionProtocol], sniffLimit: Int = 64) {
        precondition(sniffLimit > 0, "sniffLimit must be positive")
        self.protocols = protocols
        self.sniffLimit = sniffLimit
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
    public func select(alpn: String?, preface: borrowing ByteBuffer) -> Selection {
        if let alpn {
            for (index, proto) in protocols.enumerated() where type(of: proto).alpnTokens.contains(alpn) {
                return .selected(index: index)
            }
            return .unsupported
        }
        if protocols.count == 1 { return .selected(index: 0) }
        var undecided = false
        for (index, proto) in protocols.enumerated() {
            switch type(of: proto).matchesCleartextPreface(preface) {
            case .match: return .selected(index: index)
            case .needMoreBytes: undecided = true
            case .noMatch: break
            }
        }
        return undecided ? .needMoreBytes : .unsupported
    }

    /// Picks the protocol for `transport` and runs it until the connection ends.
    public func serve<T: ByteStreamTransport, H: HTTPHandler>(
        _ transport: T, handler: H, context: ConnectionContext
    ) async {
        let alpn = transport.info.negotiatedALPN
        let empty = ByteBuffer()
        switch select(alpn: alpn, preface: empty) {
        case .selected(let index):
            await Self.run(protocols[index], transport, handler: handler, context: context)
            return
        case .unsupported:
            await transport.close(.protocolError)
            return
        case .needMoreBytes:
            break
        }

        var preface = ByteBuffer(capacity: sniffLimit)
        while preface.readableBytes < sniffLimit {
            let received: Int
            do {
                received = try await transport.receive(into: &preface, maxLength: sniffLimit - preface.readableBytes)
            } catch {
                await transport.close(.abort)
                return
            }
            if received == 0 { break }
            switch select(alpn: nil, preface: preface) {
            case .selected(let index):
                let replaying = PrefixedTransport(base: transport, prefix: preface)
                await Self.run(protocols[index], replaying, handler: handler, context: context)
                return
            case .unsupported:
                await transport.close(.protocolError)
                return
            case .needMoreBytes:
                continue
            }
        }
        await transport.close(.protocolError)
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
