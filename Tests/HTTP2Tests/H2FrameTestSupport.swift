import HTTP2
import HTTPCore

/// A parser event with payload bytes copied out, so runs over different input splits can be
/// compared. Consecutive DATA chunks are merged.
enum ParsedFrame: Hashable {
    case dataHeader(HTTP2FrameParser.DataFrame)
    case data([UInt8])
    case headers(stream: UInt32, endStream: Bool, endHeaders: Bool, priority: HTTP2Priority?, [UInt8])
    case priority(stream: UInt32, HTTP2Priority)
    case rstStream(stream: UInt32, HTTP2ErrorCode)
    case settings(HTTP2Settings)
    case settingsAck
    case pushPromise(stream: UInt32, promised: UInt32, endHeaders: Bool, [UInt8])
    case ping(ack: Bool, UInt64)
    case goaway(last: UInt32, HTTP2ErrorCode, [UInt8])
    case windowUpdate(stream: UInt32, UInt32)
    case continuation(stream: UInt32, endHeaders: Bool, [UInt8])
    case priorityUpdate(prioritized: UInt32, [UInt8])
    case unknown(HTTP2FrameHeader)
    /// A stream error event: the stream and code.
    case streamError(stream: UInt32, HTTP2ErrorCode)
    /// A thrown connection error: its code.
    case connectionError(HTTP2ErrorCode)
    /// Input ended inside a frame.
    case unfinished

}

/// How a parse run used the parser's zero-copy path.
struct ParseRun {
    var frames: [ParsedFrame] = []
    var inPlacePayloads = 0
    var bufferedPayloads = 0
}

/// Feeds `chunks` to one parser in order, then checks for a frame boundary.
func parse(_ chunks: [[UInt8]], configuration: HTTP2FrameParser.Configuration = .init()) -> ParseRun {
    var parser = HTTP2FrameParser(configuration: configuration)
    var run = ParseRun()

    func append(_ frame: ParsedFrame) {
        if case .data(let more) = frame, case .data(let earlier)? = run.frames.last {
            run.frames[run.frames.count - 1] = .data(earlier + more)
        } else {
            run.frames.append(frame)
        }
    }

    func copy(_ location: HTTP2FrameParser.PayloadLocation, _ input: UnsafeRawBufferPointer) -> [UInt8] {
        switch location {
        case .input: run.inPlacePayloads += 1
        case .buffered: run.bufferedPayloads += 1
        }
        return parser.withPayload(location, in: input) { Array($0) }
    }

    for chunk in chunks {
        let failed: Bool = chunk.withUnsafeBytes { input in
            var offset = 0
            while true {
                let rest = UnsafeRawBufferPointer(rebasing: input[offset...])
                let output: HTTP2FrameParser.Output
                do throws(HTTP2Error) {
                    output = try parser.parse(rest)
                } catch {
                    precondition(error.isConnectionError, "the parser throws only connection errors")
                    append(.connectionError(error.code))
                    return true
                }
                switch output.event {
                case .needsMoreData:
                    precondition(output.consumed == rest.count, "needsMoreData must consume all input")
                    return false
                case .dataHeader(let frame): append(.dataHeader(frame))
                case .data(let range):
                    precondition(!range.isEmpty, "data events are non-empty")
                    append(.data(Array(rest[range])))
                case .headers(let stream, let endStream, let endHeaders, let priority, let fragment):
                    append(.headers(
                        stream: stream.rawValue, endStream: endStream, endHeaders: endHeaders, priority: priority,
                        copy(fragment, rest)))
                case .priority(let stream, let priority): append(.priority(stream: stream.rawValue, priority))
                case .rstStream(let stream, let code): append(.rstStream(stream: stream.rawValue, code))
                case .settings(let settings): append(.settings(settings))
                case .settingsAck: append(.settingsAck)
                case .pushPromise(let stream, let promised, let endHeaders, let fragment):
                    append(.pushPromise(
                        stream: stream.rawValue, promised: promised.rawValue, endHeaders: endHeaders,
                        copy(fragment, rest)))
                case .ping(let ack, let data): append(.ping(ack: ack, data))
                case .goaway(let last, let code, let debug): append(.goaway(last: last.rawValue, code, copy(debug, rest)))
                case .windowUpdate(let stream, let increment): append(.windowUpdate(stream: stream.rawValue, increment))
                case .continuation(let stream, let endHeaders, let fragment):
                    append(.continuation(stream: stream.rawValue, endHeaders: endHeaders, copy(fragment, rest)))
                case .priorityUpdate(let id, let field):
                    append(.priorityUpdate(prioritized: id.rawValue, copy(field, rest)))
                case .unknown(let header): append(.unknown(header))
                case .streamError(let error):
                    precondition(!error.isConnectionError, "stream error events carry stream errors")
                    append(.streamError(stream: error.streamID!.rawValue, error.code))
                }
                precondition(output.consumed > 0, "a reportable event must consume input")
                offset += output.consumed
            }
        }
        if failed { return run }
    }
    if !parser.isAtFrameBoundary { append(.unfinished) }
    return run
}

/// Every way of feeding `bytes` that the split-invariance tests compare: whole, one byte at
/// a time, and two chunks split at every offset.
func everySplit(of bytes: [UInt8]) -> [[[UInt8]]] {
    var splits: [[[UInt8]]] = [[bytes], bytes.map { [$0] }]
    for cut in 0...bytes.count {
        splits.append([Array(bytes[..<cut]), Array(bytes[cut...])])
    }
    return splits
}

/// Builds frame bytes with the encoder.
struct FrameBuilder {
    var buffer = ByteBuffer()

    var bytes: [UInt8] { buffer.withUnsafeReadableBytes { Array($0) } }

    mutating func with(_ payload: [UInt8], _ body: (UnsafeRawBufferPointer, inout ByteBuffer) -> Void) {
        payload.withUnsafeBytes { body($0, &buffer) }
    }

    mutating func raw(_ more: [UInt8]) { buffer.append(contentsOf: more) }

    /// A raw frame header followed by `payload`, bypassing the encoder's checks.
    mutating func rawFrame(type: UInt8, flags: UInt8 = 0, stream: UInt32, _ payload: [UInt8]) {
        let length = payload.count
        raw([UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff), type, flags])
        buffer.append(bigEndian: stream)
        raw(payload)
    }
}

extension HTTP2StreamID {
    static func s(_ value: UInt32) -> HTTP2StreamID { HTTP2StreamID(value) }
}
