import HTTPCore
import WebSockets

/// permessage-deflate microbenchmarks (#0110). Select with `sws-bench micro --filter WebSocket`.
///
/// The stream is `WebSocketFixture.messages`: 1,000 JSON messages of a market-data and chat
/// feed (about 190 bytes each, the same keys every time, values that drift), the shape most
/// WebSocket APIs send. One op compresses (or inflates) one message, cycling through the
/// stream, so context takeover sees a realistic history. The compression ratio of each
/// configuration is printed to stderr when its benchmark first runs.
func registerWebSocketBenchmarks() {
    let messages = WebSocketFixture.messages
    func deflate(_ name: String, _ parameters: PerMessageDeflate.Parameters) {
        var state: (PerMessageDeflate.Deflater, ByteBuffer, Int)?
        Benchmark.register(name: name) {
            if state == nil {
                WebSocketFixture.reportRatio(name, parameters)
                state = (PerMessageDeflate.Deflater(parameters)!, ByteBuffer(capacity: 1024), 0)
            }
            let index = state!.2
            state!.2 = (index + 1) % messages.count
            blackHole(state!.0.compress(messages[index], into: &state!.1))
        }
    }
    deflate("WebSocket.deflate JSON message, level 1, context takeover",
            PerMessageDeflate.Parameters(compressionLevel: 1))
    deflate("WebSocket.deflate JSON message, level 6 (default), context takeover",
            PerMessageDeflate.Parameters())
    deflate("WebSocket.deflate JSON message, level 9, context takeover",
            PerMessageDeflate.Parameters(compressionLevel: 9))
    deflate("WebSocket.deflate JSON message, level 6, no context takeover",
            PerMessageDeflate.Parameters(serverNoContextTakeover: true))
    deflate("WebSocket.deflate JSON message, level 6, window 2^10, context takeover",
            PerMessageDeflate.Parameters(serverMaxWindowBits: 10))

    for takeover in [true, false] {
        let parameters = PerMessageDeflate.Parameters(serverNoContextTakeover: !takeover, clientNoContextTakeover: !takeover)
        var state: (PerMessageDeflate.Inflater, [ByteBuffer], ByteBuffer, Int)?
        Benchmark.register(name: "WebSocket.inflate JSON message, \(takeover ? "context takeover" : "no context takeover")") {
            if state == nil {
                // The peer's compressed stream, made once with the same parameters.
                let deflater = PerMessageDeflate.Deflater(parameters)!
                var output = ByteBuffer()
                let compressed = messages.map { message -> ByteBuffer in
                    let length = deflater.compress(message, into: &output)!
                    var copy = ByteBuffer(capacity: length)
                    copy.append(ByteView(offset: output.readerIndex, length: length), from: output)
                    return copy
                }
                state = (PerMessageDeflate.Inflater(parameters)!, compressed, ByteBuffer(capacity: 1024), 0)
            }
            let index = state!.3
            if index == 0 {
                // Each pass over the stream starts a fresh peer stream.
                state!.0 = PerMessageDeflate.Inflater(parameters)!
            }
            state!.3 = (index + 1) % messages.count
            state!.2.clear()
            let inflater = state!.0
            try! state!.1[index].withUnsafeReadableBytes { (bytes) throws(PerMessageDeflate.InflateError) in
                try inflater.inflate(bytes, into: &state!.2, limit: 1 << 20)
            }
            try! inflater.finishMessage(into: &state!.2, limit: 1 << 20)
            blackHole(state!.2.readableBytes)
        }
    }
}

enum WebSocketFixture {
    /// 1,000 JSON messages from a fixed pseudo-random sequence: quotes, trades and chat lines.
    static let messages: [ByteBuffer] = {
        var seed: UInt64 = 0x5EED_CAFE
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let symbols = ["AAPL", "MSFT", "GOOG", "AMZN", "NVDA", "TSLA", "META", "ORCL"]
        let venues = ["XNAS", "XNYS", "BATS", "ARCX"]
        let users = ["ana", "bo", "chen", "dmitri", "eve", "farah"]
        let words = ["ok", "sounds good", "see the chart", "buying more", "too volatile", "lunch?",
                     "earnings tomorrow", "nice fill", "spread is wide", "closing out"]
        var price = [Int](repeating: 20_000, count: symbols.count)
        var sequence = 1_731_340_800_000
        return (0..<1000).map { i in
            sequence += 1 + next(250)
            let s = next(symbols.count)
            price[s] += next(41) - 20
            let text: String
            switch next(10) {
            case 0..<5:
                let bid = price[s]
                text = #"{"type":"quote","seq":\#(i),"ts":\#(sequence),"symbol":"\#(symbols[s])","bid":\#(bid / 100).\#(bid % 100),"ask":\#((bid + 3) / 100).\#((bid + 3) % 100),"bidSize":\#(100 * (1 + next(50))),"askSize":\#(100 * (1 + next(50))),"venue":"\#(venues[next(venues.count)])"}"#
            case 5..<8:
                text = #"{"type":"trade","seq":\#(i),"ts":\#(sequence),"symbol":"\#(symbols[s])","price":\#(price[s] / 100).\#(price[s] % 100),"size":\#(1 + next(900)),"side":"\#(next(2) == 0 ? "buy" : "sell")","conditions":["@","F"]}"#
            default:
                text = #"{"type":"chat","seq":\#(i),"ts":\#(sequence),"room":"desk-\#(1 + next(3))","user":"\#(users[next(users.count)])","text":"\#(words[next(words.count)])","mentions":[]}"#
            }
            return ByteBuffer(bytes: Array(text.utf8))
        }
    }()

    static var totalBytes: Int { messages.reduce(0) { $0 + $1.readableBytes } }

    /// Prints the stream's compressed size with `parameters` (frame payload bytes, so
    /// messages left uncompressed count at full size).
    static func reportRatio(_ name: String, _ parameters: PerMessageDeflate.Parameters) {
        let deflater = PerMessageDeflate.Deflater(parameters)!
        var output = ByteBuffer()
        var compressed = 0
        for message in messages {
            compressed += deflater.compress(message, into: &output) ?? message.readableBytes
        }
        let total = totalBytes
        let ratio = Double(compressed) / Double(total)
        printError("\(name): \(messages.count) messages, \(total) → \(compressed) bytes, ratio \(String(format3: ratio))")
    }
}

extension String {
    /// Three decimals without Foundation.
    init(format3 value: Double) {
        let thousandths = Int((value * 1000).rounded())
        let fraction = String(thousandths % 1000)
        self = "\(thousandths / 1000)." + String(repeating: "0", count: 3 - fraction.count) + fraction
    }
}
