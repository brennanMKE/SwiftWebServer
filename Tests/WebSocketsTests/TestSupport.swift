import HTTPCore
import HTTPTestSupport
import Testing
@testable import WebSockets

/// Builds client (masked) frames.
func clientFrame(_ opcode: WSOpcode, _ payload: [UInt8], fin: Bool = true, rsv: UInt8 = 0,
                 mask: UInt32 = 0x3712_A5C9) -> [UInt8] {
    var buffer = ByteBuffer()
    WSFrameWriter.appendFrame(fin: fin, reservedBits: rsv, opcode: opcode, payload: ByteBuffer(bytes: payload),
                              maskKey: mask, into: &buffer)
    return buffer.bytes
}

func clientFrame(_ opcode: WSOpcode, _ text: String, fin: Bool = true) -> [UInt8] {
    clientFrame(opcode, Array(text.utf8), fin: fin)
}

func closePayload(_ code: UInt16, _ reason: [UInt8] = []) -> [UInt8] {
    [UInt8(code >> 8), UInt8(code & 0xFF)] + reason
}

extension ByteBuffer {
    var bytes: [UInt8] { withUnsafeReadableBytes { Array($0) } }
}

/// A decoded server frame.
struct ServerFrame: Equatable {
    var opcode: WSOpcode
    var fin: Bool
    var payload: [UInt8]

    var closeCode: UInt16? {
        guard opcode == .close, payload.count >= 2 else { return nil }
        return UInt16(payload[0]) << 8 | UInt16(payload[1])
    }
}

/// Parses unmasked server frames from `bytes`; fails the test on a parse error.
func serverFrames(_ bytes: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) -> [ServerFrame] {
    var parser = WSFrameParser(configuration: .init(expectsMaskedFrames: false))
    var input = ByteBuffer(bytes: bytes)
    var frames: [ServerFrame] = []
    var payload = ByteBuffer()
    var header: WSFrameHeader?
    while true {
        switch parser.parse(&input, payloadInto: &payload) {
        case .needMoreBytes:
            return frames
        case .header(let h):
            header = h
            payload.clear()
        case .payload(_, let end):
            if end, let h = header {
                frames.append(ServerFrame(opcode: h.opcode, fin: h.fin, payload: payload.bytes))
                header = nil
            }
        case .error(let code):
            Issue.record("server frame parse error \(code)", sourceLocation: sourceLocation)
            return frames
        }
    }
}

/// Reads server frames from a live in-memory client endpoint until `count` frames or end of
/// stream.
struct FrameReader {
    let transport: InMemoryTransport
    var parser = WSFrameParser(configuration: .init(expectsMaskedFrames: false))
    var input = ByteBuffer()
    var payload = ByteBuffer()
    var header: WSFrameHeader?
    var sawEndOfStream = false

    init(_ transport: InMemoryTransport, prefix: ByteBuffer = ByteBuffer()) {
        self.transport = transport
        input = prefix
    }

    /// The next frame, or `nil` at end of stream.
    mutating func next() async throws -> ServerFrame? {
        while true {
            switch parser.parse(&input, payloadInto: &payload) {
            case .needMoreBytes:
                if sawEndOfStream { return nil }
                input.discardReadBytes()
                let n = try await transport.receive(into: &input, maxLength: 64 * 1024)
                if n == 0 { sawEndOfStream = true }
            case .header(let h):
                header = h
                payload.clear()
            case .payload(_, let end):
                if end, let h = header {
                    header = nil
                    return ServerFrame(opcode: h.opcode, fin: h.fin, payload: payload.bytes)
                }
            case .error(let code):
                Issue.record("server frame parse error \(code)")
                return nil
            }
        }
    }

    /// True once the server's end of stream arrived (after reading everything).
    mutating func readsEndOfStream() async throws -> Bool {
        while let frame = try await next() {
            Issue.record("unexpected frame \(frame)")
        }
        return sawEndOfStream
    }
}

/// Collects the fixed results of a parser over `bytes` split into the given pieces,
/// merging consecutive payload runs so that results compare across splits.
enum ParsedEvent: Equatable {
    case header(WSFrameHeader)
    case payload([UInt8])
    case error(WebSocketCloseCode)
}

func parseAll(_ bytes: [UInt8], splits: [Int], configuration: WSFrameParser.Configuration = .init()) -> [ParsedEvent] {
    var parser = WSFrameParser(configuration: configuration)
    var input = ByteBuffer()
    var events: [ParsedEvent] = []
    var current: [UInt8] = []
    var pieces: [ArraySlice<UInt8>] = []
    var start = 0
    for split in splits.sorted() where split > start && split < bytes.count {
        pieces.append(bytes[start..<split])
        start = split
    }
    pieces.append(bytes[start...])
    var sink = ByteBuffer()
    for piece in pieces {
        input.append(contentsOf: piece)
        loop: while true {
            switch parser.parse(&input, payloadInto: &sink) {
            case .needMoreBytes:
                break loop
            case .header(let header):
                events.append(.header(header))
            case .payload(_, let end):
                current += sink.bytes
                sink.clear()
                if end {
                    events.append(.payload(current))
                    current = []
                }
            case .error(let code):
                events.append(.error(code))
                return events
            }
        }
    }
    return events
}
