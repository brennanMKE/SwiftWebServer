import Testing
import HPACK
@testable import HTTP2

private func id(_ value: UInt32) -> HTTP2StreamID { HTTP2StreamID(value) }

/// RFC 7541 C.3.1: GET http://www.example.com/, adds `:authority` to the dynamic table.
private let requestC31: [UInt8] = [
    0x82, 0x86, 0x84, 0x41, 0x0f, 0x77, 0x77, 0x77, 0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x63,
    0x6f, 0x6d,
]
/// RFC 7541 C.3.2: refers to the entry C.3.1 added (index 62) and adds `cache-control`.
private let requestC32: [UInt8] = [0x82, 0x86, 0x84, 0xbe, 0x58, 0x08, 0x6e, 0x6f, 0x2d, 0x63, 0x61, 0x63, 0x68, 0x65]

private let fieldsC31 = [
    Field(":method", "GET"), Field(":scheme", "http"), Field(":path", "/"), Field(":authority", "www.example.com"),
]

struct Field: Hashable, CustomStringConvertible {
    var name: String
    var value: String
    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
    var description: String { "\(name): \(value)" }
}

struct FieldCollector: HPACKFieldSink {
    var fields: [Field] = []
    mutating func field(name: Span<UInt8>, value: Span<UInt8>, representation: HPACKRepresentation) {
        func string(_ span: Span<UInt8>) -> String {
            var bytes: [UInt8] = []
            for i in span.indices { bytes.append(span[i]) }
            return String(decoding: bytes, as: UTF8.self)
        }
        fields.append(Field(string(name), string(value)))
    }
}

/// One frame for the assembler, with its fragment bytes owned by the test.
enum TestFrame {
    case headers(UInt32, endStream: Bool = false, endHeaders: Bool, [UInt8])
    case pushPromise(UInt32, promised: UInt32, endHeaders: Bool, [UInt8])
    case continuation(UInt32, endHeaders: Bool, [UInt8])
    case other(HTTP2FrameType, UInt32)

    var bytes: [UInt8] {
        switch self {
        case .headers(_, _, _, let b), .pushPromise(_, _, _, let b), .continuation(_, _, let b): b
        case .other: []
        }
    }
}

/// Feeds `frame`; when the block completes, decodes it with `decoder` (if given) while the
/// fragment is still alive, and returns the decoded fields and the raw block bytes.
@discardableResult
private func feed(
    _ assembler: inout HeaderBlockAssembler, _ frame: TestFrame, decoder: UnsafeMutablePointer<HPACKDecoder>? = nil,
    fields: UnsafeMutablePointer<[Field]>? = nil, block: UnsafeMutablePointer<[UInt8]>? = nil
) -> HeaderBlockAssembler.Action {
    frame.bytes.withUnsafeBytes { fragment in
        let event: HeaderBlockAssembler.Event =
            switch frame {
            case .headers(let s, let es, let eh, _):
                .headers(streamID: id(s), endStream: es, endHeaders: eh, priority: nil, fragment: fragment)
            case .pushPromise(let s, let p, let eh, _):
                .pushPromise(streamID: id(s), promisedStreamID: id(p), endHeaders: eh, fragment: fragment)
            case .continuation(let s, let eh, _):
                .continuation(streamID: id(s), endHeaders: eh, fragment: fragment)
            case .other(let type, let s):
                .otherFrame(type, streamID: id(s))
            }
        let action = assembler.handle(event)
        if case .decode(let header) = action {
            if let block {
                block.pointee = try! assembler.withBlockBytes(header, fragment: fragment) { bytes in
                    var out: [UInt8] = []
                    for i in bytes.indices { out.append(bytes[i]) }
                    return out
                }
            }
            if let decoder {
                var sink = FieldCollector()
                do {
                    try assembler.decode(header, fragment: fragment, with: &decoder.pointee, into: &sink)
                    fields?.pointee = sink.fields
                } catch {
                    Issue.record("decode failed: \(error)")
                }
            }
        }
        return action
    }
}

/// Splits `bytes` into a HEADERS frame and CONTINUATIONs at `cuts`.
private func split(_ bytes: [UInt8], stream: UInt32, endStream: Bool = false, cuts: [Int]) -> [TestFrame] {
    let bounds = [0] + cuts + [bytes.count]
    var frames: [TestFrame] = []
    for i in 0..<(bounds.count - 1) {
        let piece = Array(bytes[bounds[i]..<bounds[i + 1]])
        let last = i == bounds.count - 2
        frames.append(
            i == 0
                ? .headers(stream, endStream: endStream, endHeaders: last, piece)
                : .continuation(stream, endHeaders: last, piece))
    }
    return frames
}

@Suite("HeaderBlockAssembler (RFC 9113 §4.3, §6.10)")
struct H2HeaderBlockTests {
    @Test("A single HEADERS frame is decoded in place")
    func singleFrame() {
        var assembler = HeaderBlockAssembler()
        var decoder = HPACKDecoder()
        var fields: [Field] = []
        let action = feed(&assembler, .headers(1, endStream: true, endHeaders: true, requestC31),
                          decoder: &decoder, fields: &fields)
        #expect(action == .decode(.init(
            streamID: id(1), kind: .headers, endStream: true, size: requestC31.count, continuationFrames: 0,
            isAssembled: false)))
        #expect(fields == fieldsC31)
        #expect(!assembler.isAssembling)
    }

    @Test("A block split into a CONTINUATION per byte decodes to the same fields")
    func manyContinuations() {
        var assembler = HeaderBlockAssembler(configuration: .init(maxContinuationFrames: 64))
        var decoder = HPACKDecoder()
        var fields: [Field] = []
        let frames = split(requestC31, stream: 1, endStream: true, cuts: Array(1..<requestC31.count))
        for frame in frames.dropLast() {
            #expect(feed(&assembler, frame) == .needsContinuation)
            #expect(assembler.assemblingStreamID == id(1))
        }
        let action = feed(&assembler, frames.last!, decoder: &decoder, fields: &fields)
        #expect(action == .decode(.init(
            streamID: id(1), kind: .headers, endStream: true, size: requestC31.count,
            continuationFrames: requestC31.count - 1, isAssembled: true)))
        #expect(fields == fieldsC31)
    }

    @Test("Every split of a block assembles the same bytes")
    func everySplitAssembles() {
        let bytes = requestC32
        for mask in 0..<(1 << (bytes.count - 1)) where mask.nonzeroBitCount <= 4 {
            let cuts = (1..<bytes.count).filter { mask & (1 << ($0 - 1)) != 0 }
            var assembler = HeaderBlockAssembler()
            var block: [UInt8] = []
            var last: HeaderBlockAssembler.Action = .proceed
            for frame in split(bytes, stream: 5, cuts: cuts) { last = feed(&assembler, frame, block: &block) }
            guard case .decode(let header) = last else {
                Issue.record("cuts \(cuts): \(last)")
                return
            }
            #expect(block == bytes, "cuts \(cuts)")
            #expect(header.continuationFrames == cuts.count)
            #expect(header.isAssembled == !cuts.isEmpty)
        }
    }

    @Test("Empty fragments are allowed")
    func emptyFragments() {
        var assembler = HeaderBlockAssembler()
        var block: [UInt8] = [0xff]
        #expect(feed(&assembler, .headers(1, endHeaders: false, [])) == .needsContinuation)
        #expect(feed(&assembler, .continuation(1, endHeaders: false, [])) == .needsContinuation)
        guard case .decode(let header) = feed(&assembler, .continuation(1, endHeaders: true, []), block: &block) else {
            Issue.record("expected a block")
            return
        }
        #expect(header.size == 0)
        #expect(block == [])
    }

    @Test("Any frame interleaved in an open block is a connection PROTOCOL_ERROR", arguments: [
        TestFrame.other(.data, 1), .other(.ping, 0), .other(.settings, 0), .other(.priority, 1),
        .other(.rstStream, 1), .other(.windowUpdate, 0), .other(.goaway, 0), .other(HTTP2FrameType(rawValue: 0xfa), 0),
        .headers(1, endHeaders: true, []), .headers(3, endHeaders: true, []),
        .pushPromise(1, promised: 2, endHeaders: true, []), .continuation(3, endHeaders: true, []),
    ])
    func interleaved(_ intruder: TestFrame) {
        var assembler = HeaderBlockAssembler()
        #expect(feed(&assembler, .headers(1, endHeaders: false, [0x82])) == .needsContinuation)
        #expect(feed(&assembler, intruder) == .connectionError(.protocolError))
        // The assembler stays failed.
        #expect(feed(&assembler, .continuation(1, endHeaders: true, [0x86])) == .connectionError(.protocolError))
        #expect(feed(&assembler, .other(.ping, 0)) == .connectionError(.protocolError))
    }

    @Test("CONTINUATION without an open block is a connection PROTOCOL_ERROR")
    func strayContinuation() {
        var assembler = HeaderBlockAssembler()
        #expect(feed(&assembler, .continuation(1, endHeaders: true, [0x82])) == .connectionError(.protocolError))

        var afterBlock = HeaderBlockAssembler()
        if case .decode = feed(&afterBlock, .headers(1, endHeaders: true, [0x82])) {} else { Issue.record("no block") }
        #expect(feed(&afterBlock, .continuation(1, endHeaders: true, [0x86])) == .connectionError(.protocolError))
    }

    @Test("Frames between blocks pass through")
    func otherFramesProceed() {
        var assembler = HeaderBlockAssembler()
        #expect(feed(&assembler, .other(.data, 1)) == .proceed)
        #expect(feed(&assembler, .other(.settings, 0)) == .proceed)
        #expect(feed(&assembler, .other(HTTP2FrameType(rawValue: 0x42), 7)) == .proceed)
    }

    @Test("The block size cap is enforced on the frame that crosses it")
    func sizeCap() {
        let limit = 100
        let config = HeaderBlockAssembler.Configuration(maxBlockSize: limit)

        // Exactly at the limit is fine, in one frame or several.
        var exact = HeaderBlockAssembler(configuration: config)
        if case .decode(let h) = feed(&exact, .headers(1, endHeaders: true, Array(repeating: 0, count: limit))) {
            #expect(h.size == limit)
        } else { Issue.record("expected a block") }
        #expect(feed(&exact, .headers(3, endHeaders: false, Array(repeating: 0, count: 60))) == .needsContinuation)
        if case .decode(let h) = feed(&exact, .continuation(3, endHeaders: true, Array(repeating: 0, count: 40))) {
            #expect(h.size == limit)
        } else { Issue.record("expected a block") }

        // One byte over, in a single HEADERS frame.
        var single = HeaderBlockAssembler(configuration: config)
        #expect(feed(&single, .headers(1, endHeaders: true, Array(repeating: 0, count: limit + 1)))
            == .connectionError(.enhanceYourCalm))

        // Over the limit mid-block, without END_HEADERS: fails fast.
        var split = HeaderBlockAssembler(configuration: config)
        #expect(feed(&split, .headers(1, endHeaders: false, Array(repeating: 0, count: 60))) == .needsContinuation)
        #expect(feed(&split, .continuation(1, endHeaders: false, Array(repeating: 0, count: 41)))
            == .connectionError(.enhanceYourCalm))
        #expect(split.buffer.capacity == 0)  // released
    }

    @Test("A flood of empty CONTINUATION frames is cut off at the frame-count cap")
    func continuationFlood() {
        var assembler = HeaderBlockAssembler(configuration: .init(maxContinuationFrames: 4))
        #expect(feed(&assembler, .headers(1, endHeaders: false, [0x82])) == .needsContinuation)
        for _ in 0..<4 {
            #expect(feed(&assembler, .continuation(1, endHeaders: false, [])) == .needsContinuation)
        }
        #expect(feed(&assembler, .continuation(1, endHeaders: false, [])) == .connectionError(.enhanceYourCalm))
        #expect(feed(&assembler, .continuation(1, endHeaders: true, [])) == .connectionError(.enhanceYourCalm))
    }

    @Test("The assembly buffer is allocated once and reused")
    func bufferReuse() {
        var assembler = HeaderBlockAssembler(configuration: .init(maxBlockSize: 256))
        var capacity = -1
        var stream: UInt32 = 1
        for _ in 0..<100 {
            for frame in split(Array(repeating: 0x82, count: 200), stream: stream, cuts: [50, 100, 150]) {
                feed(&assembler, frame)
            }
            if capacity < 0 { capacity = assembler.buffer.capacity }
            #expect(assembler.buffer.capacity == capacity)
            stream += 2
        }
        #expect(capacity >= 256 && capacity < 512)
    }

    @Test("A second HEADERS block on a stream is recognised as trailers")
    func trailers() {
        var assembler = HeaderBlockAssembler()
        func kind(_ frame: TestFrame) -> HeaderBlockAssembler.Kind? {
            if case .decode(let block) = feed(&assembler, frame) { return block.kind }
            return nil
        }
        #expect(kind(.headers(1, endHeaders: true, [0x82])) == .headers)
        #expect(kind(.headers(3, endHeaders: true, [0x82])) == .headers)
        #expect(kind(.headers(1, endStream: true, endHeaders: true, [0x40])) == .trailers)
        #expect(kind(.headers(5, endStream: true, endHeaders: true, [0x82])) == .headers)
        // Trailers split across CONTINUATIONs.
        #expect(feed(&assembler, .headers(3, endStream: true, endHeaders: false, [0x40])) == .needsContinuation)
        if case .decode(let block) = feed(&assembler, .continuation(3, endHeaders: true, [0x01])) {
            #expect(block.kind == .trailers)
            #expect(block.endStream)
        } else { Issue.record("expected a block") }
        #expect(assembler.highestHeadersStreamID == id(5))
        #expect(kind(.pushPromise(5, promised: 2, endHeaders: true, [0x82])) == .pushPromise(promisedStreamID: id(2)))
    }

    @Test("A block on a refused stream is still decoded and updates the dynamic table")
    func refusedStreamKeepsHPACKInSync() {
        var table = HTTP2StreamTable(configuration: .init(maxConcurrentStreams: 1))
        var assembler = HeaderBlockAssembler()
        var decoder = HPACKDecoder()
        var fields: [Field] = []

        #expect(table.handle(.received(id(1), .headers(endStream: false))) == .proceed)

        // Stream 3 is over the limit: refused, but its block (split in two) is decoded.
        #expect(table.handle(.received(id(3), .headers(endStream: true))) == .streamError(.refusedStream))
        let frames = split(requestC31, stream: 3, endStream: true, cuts: [7])
        #expect(feed(&assembler, frames[0]) == .needsContinuation)
        feed(&assembler, frames[1], decoder: &decoder, fields: &fields)
        #expect(fields == fieldsC31)
        #expect(decoder.dynamicTable.count == 1)

        // The next request indexes the entry the refused one added.
        #expect(table.handle(.sent(id(1), .rstStream)) == .proceed)
        #expect(table.handle(.received(id(5), .headers(endStream: true))) == .proceed)
        feed(&assembler, .headers(5, endStream: true, endHeaders: true, requestC32), decoder: &decoder, fields: &fields)
        #expect(fields == fieldsC31 + [Field("cache-control", "no-cache")])
    }

    @Test("An HPACK failure is a connection COMPRESSION_ERROR")
    func compressionError() {
        var assembler = HeaderBlockAssembler()
        var decoder = HPACKDecoder()
        var sink = FieldCollector()
        let bad: [UInt8] = [0xff, 0xff, 0xff, 0x7f]  // index far past the tables
        bad.withUnsafeBytes { fragment in
            guard case .decode(let block) = assembler.handle(
                .headers(streamID: id(1), endStream: true, endHeaders: true, priority: nil, fragment: fragment))
            else {
                Issue.record("expected a block")
                return
            }
            do throws(HTTP2Error) {
                try assembler.decode(block, fragment: fragment, with: &decoder, into: &sink)
                Issue.record("expected an error")
            } catch {
                #expect(error.code == .compressionError)
                #expect(error.isConnectionError)
            }
        }
    }

    @Test("Seeded random frame sequences match a reference model", arguments: 0..<64)
    func randomSequences(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let config = HeaderBlockAssembler.Configuration(
            maxBlockSize: [8, 32, 100][Int(seed % 3)], maxContinuationFrames: [0, 2, 6][Int(seed / 3 % 3)])
        var assembler = HeaderBlockAssembler(configuration: config)
        var model = AssemblerModel(config: config)
        var stream: UInt32 = 1

        for step in 0..<300 {
            let frame = randomFrame(&rng, model: model, stream: &stream)
            var block: [UInt8] = []
            let actual = feed(&assembler, frame, block: &block)
            let (expected, expectedBlock) = model.handle(frame)
            #expect(actual == expected, "seed \(seed) step \(step): \(frame)")
            if case .decode = actual { #expect(block == expectedBlock, "seed \(seed) step \(step)") }
            if actual != expected { return }
            if case .connectionError = actual {
                // Start a new connection.
                assembler = HeaderBlockAssembler(configuration: config)
                model = AssemblerModel(config: config)
                stream = 1
            }
        }
    }

    private func randomFrame(_ rng: inout SplitMix64, model: AssemblerModel, stream: inout UInt32) -> TestFrame {
        func bytes() -> [UInt8] {
            (0..<Int.random(in: 0...12, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        }
        let endHeaders = Int.random(in: 0..<3, using: &rng) == 0
        let roll = Int.random(in: 0..<100, using: &rng)
        if let open = model.open?.stream, roll < 75 {
            // Mostly well-behaved, sometimes on the wrong stream.
            let target = Int.random(in: 0..<20, using: &rng) == 0 ? open + 2 : open
            return .continuation(target, endHeaders: endHeaders, bytes())
        }
        switch Int.random(in: 0..<10, using: &rng) {
        case 0..<5:
            let target: UInt32
            if Bool.random(using: &rng) {
                stream += 2
                target = stream
            } else {
                target = UInt32.random(in: 0...(stream / 2), using: &rng) * 2 + 1
            }
            return .headers(target, endStream: Bool.random(using: &rng), endHeaders: endHeaders, bytes())
        case 5: return .pushPromise(stream, promised: 2, endHeaders: endHeaders, bytes())
        case 6: return .continuation(stream, endHeaders: endHeaders, bytes())
        default:
            let types: [HTTP2FrameType] = [.data, .ping, .settings, .rstStream, HTTP2FrameType(rawValue: 0x33)]
            return .other(types.randomElement(using: &rng)!, stream)
        }
    }
}

/// A reference model of ``HeaderBlockAssembler``: an optional open block holding its bytes in
/// an array, checked against the limits after each append.
struct AssemblerModel {
    let config: HeaderBlockAssembler.Configuration
    var open: (stream: UInt32, kind: HeaderBlockAssembler.Kind, endStream: Bool, bytes: [UInt8], count: Int)?
    var highest: UInt32 = 0
    var failed: HTTP2ErrorCode?

    init(config: HeaderBlockAssembler.Configuration) { self.config = config }

    mutating func handle(_ frame: TestFrame) -> (HeaderBlockAssembler.Action, [UInt8]) {
        if let failed { return (.connectionError(failed), []) }
        func fail(_ code: HTTP2ErrorCode) -> (HeaderBlockAssembler.Action, [UInt8]) {
            failed = code
            return (.connectionError(code), [])
        }
        func start(
            _ stream: UInt32, _ kind: HeaderBlockAssembler.Kind, _ endStream: Bool, _ endHeaders: Bool, _ bytes: [UInt8]
        ) -> (HeaderBlockAssembler.Action, [UInt8]) {
            if open != nil { return fail(.protocolError) }
            if bytes.count > config.maxBlockSize { return fail(.enhanceYourCalm) }
            if endHeaders {
                return (.decode(.init(
                    streamID: id(stream), kind: kind, endStream: endStream, size: bytes.count, continuationFrames: 0,
                    isAssembled: false)), bytes)
            }
            open = (stream, kind, endStream, bytes, 0)
            return (.needsContinuation, [])
        }
        switch frame {
        case .headers(let s, let es, let eh, let b):
            if open != nil { return fail(.protocolError) }
            let kind: HeaderBlockAssembler.Kind = s > highest ? .headers : .trailers
            highest = max(highest, s)
            return start(s, kind, es, eh, b)
        case .pushPromise(let s, let p, let eh, let b):
            return start(s, .pushPromise(promisedStreamID: id(p)), false, eh, b)
        case .continuation(let s, let eh, let b):
            guard var block = open, block.stream == s else { return fail(.protocolError) }
            block.bytes += b
            block.count += 1
            if block.count > config.maxContinuationFrames || block.bytes.count > config.maxBlockSize {
                return fail(.enhanceYourCalm)
            }
            if !eh {
                open = block
                return (.needsContinuation, [])
            }
            open = nil
            return (.decode(.init(
                streamID: id(s), kind: block.kind, endStream: block.endStream, size: block.bytes.count,
                continuationFrames: block.count, isAssembled: true)), block.bytes)
        case .other:
            return open == nil ? (.proceed, []) : fail(.protocolError)
        }
    }
}
