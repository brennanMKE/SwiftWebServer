import HTTP3

/// A parser event with payload bytes copied out, so runs over different input splits can be
/// compared. Consecutive DATA chunks are merged.
enum ParsedFrame: Equatable, CustomStringConvertible {
    case dataHeader(UInt64)
    case data([UInt8])
    case headers([UInt8])
    case pushPromise(UInt64, [UInt8])
    case settings(H3Settings)
    case cancelPush(UInt64)
    case goaway(UInt64)
    case maxPushID(UInt64)
    case error(HTTP3Error)
    /// The stream ended inside a frame (``H3FrameParser/finish()`` threw).
    case unfinished(HTTP3Error)

    var description: String {
        switch self {
        case .dataHeader(let length): "dataHeader(\(length))"
        case .data(let bytes): "data(\(bytes.count) bytes)"
        case .headers(let bytes): "headers(\(bytes))"
        case .pushPromise(let id, let bytes): "pushPromise(\(id), \(bytes))"
        case .settings(let settings): "settings(\(settings))"
        case .cancelPush(let id): "cancelPush(\(id))"
        case .goaway(let id): "goaway(\(id))"
        case .maxPushID(let id): "maxPushID(\(id))"
        case .error(let error): "error(\(error.name))"
        case .unfinished(let error): "unfinished(\(error.name))"
        }
    }
}

/// How a parse run used the parser's zero-copy path.
struct ParseRun {
    var frames: [ParsedFrame] = []
    var inPlacePayloads = 0
    var bufferedPayloads = 0
}

/// Feeds `chunks` to one parser in order, then calls `finish()`.
func parse(_ chunks: [[UInt8]], configuration: H3FrameParser.Configuration) -> ParseRun {
    var parser = H3FrameParser(configuration: configuration)
    var run = ParseRun()

    func append(_ frame: ParsedFrame) {
        if case .data(let more) = frame, case .data(let earlier)? = run.frames.last {
            run.frames[run.frames.count - 1] = .data(earlier + more)
        } else {
            run.frames.append(frame)
        }
    }

    func copy(_ location: H3FrameParser.PayloadLocation, _ input: UnsafeRawBufferPointer) -> [UInt8] {
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
                let output: H3FrameParser.Output
                do throws(HTTP3Error) {
                    output = try parser.parse(rest)
                } catch {
                    append(.error(error))
                    return true
                }
                switch output.event {
                case .needsMoreData:
                    precondition(output.consumed == rest.count, "needsMoreData must consume all input")
                    return false
                case .dataHeader(let length): append(.dataHeader(length))
                case .data(let range): append(.data(Array(rest[range])))
                case .headers(let location): append(.headers(copy(location, rest)))
                case .pushPromise(let id, let location): append(.pushPromise(id, copy(location, rest)))
                case .settings(let settings): append(.settings(settings))
                case .cancelPush(let id): append(.cancelPush(id))
                case .goaway(let id): append(.goaway(id))
                case .maxPushID(let id): append(.maxPushID(id))
                }
                precondition(output.consumed > 0 || rest.isEmpty, "a reportable event must consume input")
                offset += output.consumed
            }
        }
        if failed { return run }
    }
    do throws(HTTP3Error) {
        try parser.finish()
    } catch {
        append(.unfinished(error))
    }
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
    var bytes: [UInt8] = []

    mutating func data(_ payload: [UInt8]) throws {
        try payload.withUnsafeBytes { p throws in try H3FrameEncoder.encodeData(p, into: &bytes) }
    }

    mutating func headers(_ fieldSection: [UInt8]) throws {
        try fieldSection.withUnsafeBytes { p throws in try H3FrameEncoder.encodeHeaders(fieldSection: p, into: &bytes) }
    }

    mutating func pushPromise(_ pushID: UInt64, _ fieldSection: [UInt8]) throws {
        try fieldSection.withUnsafeBytes { p throws in
            try H3FrameEncoder.encodePushPromise(pushID: pushID, fieldSection: p, into: &bytes)
        }
    }

    mutating func frame(_ type: H3FrameType, _ payload: [UInt8]) throws {
        try payload.withUnsafeBytes { p throws in try H3FrameEncoder.encodeFrame(type: type, payload: p, into: &bytes) }
    }

    mutating func settings(_ settings: H3Settings, grease: (id: UInt64, value: UInt64)? = nil) throws {
        try H3FrameEncoder.encodeSettings(settings, grease: grease, into: &bytes)
    }

    mutating func raw(_ more: [UInt8]) { bytes += more }
}
