// QUIC spike client (#0071): Network.framework QUIC client scenarios + URLSession HTTP/3 probe.
//
// usage: quic-client <test> [--port N] [--host H] [args...]
//   tests: echo | uni3 | reset | peerreset | close | stall | bulk | loop N C | zerortt | urlsession | all
import Foundation
import Network
import Security
import QUICSpikeKit

let echoALPN = "sws-echo"
let (port, host, positional): (UInt16, String, [String]) = {
    var port: UInt16 = 4433
    var host = "127.0.0.1"
    var positional: [String] = []
    var args = CommandLine.arguments.dropFirst()
    while let a = args.popFirst() {
        switch a {
        case "--port": port = UInt16(args.popFirst()!)!
        case "--host": host = args.popFirst()!
        default: positional.append(a)
        }
    }
    return (port, host, positional)
}()
let test = positional.first ?? "all"
let queue = DispatchQueue(label: "quic-spike.client")
if ProcessInfo.processInfo.environment["QUIC_SPIKE_ALLOCS"] == "1" { _ = Allocs.install() }

let tuning: QUICTuning = {
    var tuning = QUICTuning()
    tuning.initialMaxStreamsUni = 16
    tuning.initialMaxStreamsBidi = 16
    tuning.initialMaxData = 1 << 20
    tuning.initialMaxStreamDataBidiLocal = 128 << 10   // our window for data the server sends on our bidi streams
    tuning.initialMaxStreamDataBidiRemote = 128 << 10
    tuning.initialMaxStreamDataUni = 64 << 10
    return tuning
}()

final class Inbound: @unchecked Sendable {
    let lock = NSLock(); var streams: [NWConnection] = []
    func add(_ c: NWConnection) { lock.lock(); streams.append(c); lock.unlock() }
    var all: [NWConnection] { lock.lock(); defer { lock.unlock() }; return streams }
}

func connect(tag: String, alpn: [String] = [echoALPN], params: NWParameters? = nil, inbound: Inbound? = nil,
             onState: (@Sendable (NWConnectionGroup.State) -> Void)? = nil) async -> (NWConnectionGroup, NWConnection)? {
    let p = params ?? clientParameters(alpn: alpn, tuning: tuning)
    let group = NWConnectionGroup(with: NWMultiplexGroup(to: .hostPort(host: .init(host), port: .init(rawValue: port)!)), using: p)
    group.newConnectionHandler = { c in
        log(tag, "server-initiated stream arrived")
        inbound?.add(c)
    }
    let r = await startAndWait(group, queue: queue, tag: tag, onLaterState: onState)
    guard case .ready = r else { log(tag, "group not ready: \(r)"); return nil }
    guard let first = await openStream(group, tag: tag) else { log(tag, "connect failed"); return nil }
    if let m = quicMetadata(group) { log(tag, "connected: \(describeTLS(m)) group.state=\(group.state)") }
    return (group, first)
}

func openStream(_ group: NWConnectionGroup, tag: String) async -> NWConnection? {
    guard let s = NWConnection(from: group) else { log(tag, "NWConnection(from:) nil"); return nil }
    let r = await startAndWait(s, queue: queue, tag: tag)
    guard case .ready = r else { return nil }
    if !quietStreams, let m = quicMetadata(s) { log(tag, "outbound stream \(describeStreamID(m.streamIdentifier))") }
    return s
}

// MARK: - Scenarios

func testEcho() async {
    let tag = "echo"
    guard let (g, s) = await connect(tag: tag) else { return }
    let e0 = await send(s, Data("echo\nhello ".utf8), fin: false)
    log(tag, "sent 'echo\\nhello ' (no FIN) completion error=\(String(describing: e0))")
    await sleepMs(50)
    log(tag, "slept")
    let err = await send(s, Data("world".utf8), fin: true)
    log(tag, "sent 'world' with .finalMessage isComplete=true error=\(String(describing: err))")
    let (data, end) = await receiveAll(s, tag: tag)
    log(tag, "RESULT echoed='\(String(decoding: data, as: UTF8.self))' peerFIN(isComplete)=\(end.isComplete) error=\(String(describing: end.error))")
    g.cancel()
}

func testUni3() async {
    let tag = "uni3"
    let inbound = Inbound()
    guard let (g, s) = await connect(tag: tag, inbound: inbound) else { return }
    _ = await send(s, Data("uni3\n".utf8), fin: true)
    let (reply, _) = await receiveAll(s, tag: tag, verbose: false)
    log(tag, "control reply '\(String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))'")
    await sleepMs(200)
    for (i, c) in inbound.all.enumerated() {
        let r = await startAndWait(c, queue: queue, tag: "\(tag) in#\(i)")
        guard case .ready = r else { continue }
        let id = quicMetadata(c)?.streamIdentifier ?? 999
        let (data, end) = await receiveAll(c, tag: "\(tag) in#\(i)", verbose: false)
        log(tag, "RESULT inbound \(describeStreamID(id)) data='\(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))' FIN=\(end.isComplete)")
    }
    log(tag, "RESULT server-initiated streams received: \(inbound.all.count)")
    g.cancel()
}

func testReset() async {
    let tag = "reset"
    guard let (g, s) = await connect(tag: tag) else { return }
    _ = await send(s, Data("reset 10c\n".utf8), fin: false)
    let m = quicMetadata(s)!
    while true {
        let r = await receive(s)
        log(tag, "receive bytes=\(r.data?.count ?? 0) isComplete=\(r.isComplete) error=\(String(describing: r.error)) streamApplicationErrorCode=0x\(String(m.streamApplicationErrorCode, radix: 16)) state=\(s.state)")
        if r.isComplete || r.error != nil { break }
    }
    // Does a send still work (STOP_SENDING from the peer)?
    let err = await send(s, Data("more".utf8), fin: false)
    log(tag, "RESULT send after peer reset error=\(String(describing: err)) streamApplicationErrorCode=0x\(String(m.streamApplicationErrorCode, radix: 16))")
    g.cancel()
}

func testPeerReset() async {
    let tag = "peerreset"
    guard let (g, s) = await connect(tag: tag) else { return }
    _ = await send(s, Data("peerreset\n".utf8), fin: false)
    let r = await receive(s)
    log(tag, "got '\(String(decoding: r.data ?? Data(), as: UTF8.self).trimmingCharacters(in: .newlines))'")
    _ = await send(s, Data("some-bytes".utf8), fin: false)
    await sleepMs(100)
    quicMetadata(s)!.streamApplicationErrorCode = 0x10b
    log(tag, "client set streamApplicationErrorCode=0x10b then cancel()")
    s.cancel()
    await sleepMs(500)
    g.cancel()
}

func testClose(variant: String) async {
    let tag = "close-\(variant)"
    final class States: @unchecked Sendable { let lock = NSLock(); var s: [String] = [] }
    let states = States()
    guard let (g, s) = await connect(tag: tag, onState: { st in states.lock.lock(); states.s.append("\(st)"); states.lock.unlock() }) else { return }
    _ = await send(s, Data("close 101 \(variant)\n".utf8), fin: false)
    let mon = Task {
        for i in 1...6 {
            await sleepMs(2000)
            let gm = quicMetadata(g)
            log(tag, "monitor t=\(i * 2)s group.state=\(g.state) stream.state=\(s.state) group.applicationError=\(gm.map { "0x" + String($0.applicationError.code, radix: 16) + " " + String(describing: $0.applicationError.reason) } ?? "nil")")
        }
    }
    defer { mon.cancel() }
    while true {
        let r = await receive(s)
        log(tag, "receive bytes=\(r.data?.count ?? 0) isComplete=\(r.isComplete) error=\(String(describing: r.error)) state=\(s.state)")
        if r.isComplete || r.error != nil { break }
    }
    let sm = quicMetadata(s)
    log(tag, "stream-metadata applicationError right after close: \(sm.map { "code=0x\(String($0.applicationError.code, radix: 16)) reason=\(String(describing: $0.applicationError.reason))" } ?? "nil") streamAppErr=\(sm.map { "0x" + String($0.streamApplicationErrorCode, radix: 16) } ?? "nil")")
    let gm0 = quicMetadata(g)
    log(tag, "group-metadata applicationError right after close: \(gm0.map { "code=0x\(String($0.applicationError.code, radix: 16)) reason=\(String(describing: $0.applicationError.reason))" } ?? "nil")")
    await sleepMs(300)
    let gm = quicMetadata(g)
    log(tag, "RESULT group states=\(states.s) group.metadata.applicationError=\(gm.map { "code=0x\(String($0.applicationError.code, radix: 16)) reason=\(String(describing: $0.applicationError.reason))" } ?? "nil (no metadata)") stream state=\(s.state)")
    g.cancel()
}

func testStall() async {
    // Q7 client→server: server does not read for 3 s. Measure how much we can send and when completions fire.
    let tag = "stall"
    guard let (g, s) = await connect(tag: tag) else { return }
    _ = await send(s, Data("stall 3000\n".utf8), fin: false)
    let chunk = Data(repeating: 0x62, count: 16 << 10)
    var sent = 0
    let start = DispatchTime.now()
    var last = 0.0
    let target = (positional.count > 1 ? Int(positional[1])! : 1536) << 10
    while sent < target {
        let t0 = DispatchTime.now()
        let err = await send(s, chunk, fin: sent + chunk.count >= target)
        sent += chunk.count
        let dt = elapsedMs(since: t0)
        if dt > 100 || elapsedMs(since: start) - last > 500 || sent % (128 << 10) == 0 {
            last = elapsedMs(since: start)
            log(tag, "sent=\(sent >> 10) KiB completion-latency=\(String(format: "%.1f", dt)) ms (t=\(String(format: "%.0f", elapsedMs(since: start))) ms) error=\(String(describing: err))")
        }
        if err != nil { break }
    }
    let (reply, _) = await receiveAll(s, tag: tag, verbose: false)
    log(tag, "RESULT all \(sent >> 10) KiB completed after \(String(format: "%.0f", elapsedMs(since: start))) ms; server: \(String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .newlines))")
    g.cancel()
}

func testBulk() async {
    // Q7 server→client: we do not read for 3 s; server logs send completions.
    let tag = "bulk"
    guard let (g, s) = await connect(tag: tag) else { return }
    _ = await send(s, Data("bulk 16777216\n".utf8), fin: true)
    log(tag, "not reading for 3000 ms")
    await sleepMs(3000)
    let start = DispatchTime.now()
    let (data, end) = await receiveAll(s, tag: tag, verbose: false)
    log(tag, "RESULT read \(data.count) bytes in \(String(format: "%.1f", elapsedMs(since: start))) ms FIN=\(end.isComplete)")
    g.cancel()
}

func serverStats(_ g: NWConnectionGroup) async -> (UInt64, UInt64) {
    guard let s = await openStream(g, tag: "stats") else { return (0, 0) }
    _ = await send(s, Data("stats\n".utf8), fin: true)
    let (data, _) = await receiveAll(s, tag: "stats", verbose: false)
    let text = String(decoding: data, as: UTF8.self)
    log("stats", "server \(text.trimmingCharacters(in: .newlines))")
    var allocs: UInt64 = 0, bytes: UInt64 = 0
    for part in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
        let kv = part.split(separator: "=")
        if kv[0] == "allocs" { allocs = UInt64(kv[1])! }
        if kv[0] == "bytes" { bytes = UInt64(kv[1])! }
    }
    return (allocs, bytes)
}

func testLoop(n: Int, concurrency: Int) async {
    let tag = "loop"
    guard let (g, first) = await connect(tag: tag) else { return }
    first.cancel()
    // Warm up.
    for _ in 0..<5 { await pingOnce(g) }
    let (a0, b0) = await serverStats(g)
    let ca0 = Allocs.count
    let start = DispatchTime.now()
    await withTaskGroup(of: Void.self) { tg in
        var launched = 0
        for _ in 0..<min(concurrency, n) { tg.addTask { await pingOnce(g) }; launched += 1 }
        while await tg.next() != nil {
            if launched < n { tg.addTask { await pingOnce(g) }; launched += 1 }
        }
    }
    let ms = elapsedMs(since: start)
    let ca1 = Allocs.count
    let (a1, b1) = await serverStats(g)
    // Stats streams themselves add ~1 stream of noise.
    log(tag, String(format: "RESULT n=%d concurrency=%d total=%.1f ms per-stream=%.3f ms (%.0f streams/s)", n, concurrency, ms, ms / Double(n), Double(n) / (ms / 1000)))
    log(tag, "RESULT server allocs/stream≈\(Double(a1 - a0) / Double(n)) (process-wide, includes Network.framework + stats stream)")
    log(tag, "RESULT client allocs/stream≈\(Double(ca1 - ca0) / Double(n)) (process-wide, includes client stream setup)")
    g.cancel()
}

func pingOnce(_ g: NWConnectionGroup) async {
    guard let s = NWConnection(from: g) else { return }
    let r = await withCheckedContinuation { (cont: CheckedContinuation<ReadyResult, Never>) in
        let once = Once(cont)
        s.stateUpdateHandler = { st in
            switch st {
            case .ready: once.resume(.ready)
            case .failed(let e): once.resume(.failed(e))
            case .cancelled: once.resume(.cancelled)
            default: break
            }
        }
        s.start(queue: queue)
    }
    guard case .ready = r else { log("ping", "stream not ready: \(r)"); return }
    _ = await send(s, Data("ping\n".utf8), fin: true)
    let (data, end) = await receiveAll(s, tag: "ping", verbose: false)
    if data.count != 4 || !end.isComplete { log("ping", "unexpected reply \(data.count) bytes fin=\(end.isComplete) err=\(String(describing: end.error))") }
    s.cancel()
}

func testZeroRTT() async {
    // Q8: resumption + early data. Same parameter object for both connections so any session cache is shared.
    let tag = "0rtt"
    let params = clientParameters(alpn: [echoALPN], tuning: tuning, earlyData: true)
    for attempt in 1...3 {
        let group = NWConnectionGroup(with: NWMultiplexGroup(to: .hostPort(host: .init(host), port: .init(rawValue: port)!)), using: params)
        // NWConnection(from: group) returns nil until the group is ready, so idempotent data
        // cannot be queued before the handshake. First check that this is still true, then wait.
        group.stateUpdateHandler = { st in log(tag, "attempt \(attempt) group state \(st)") }
        if ProcessInfo.processInfo.environment["NO_NEWCONN_HANDLER"] != "1" {
            group.newConnectionHandler = { c in c.cancel() }
        }
        group.start(queue: queue)
        if ProcessInfo.processInfo.environment["PROBE_EARLY"] == "1" {
            log(tag, "attempt \(attempt) NWConnection(from:) before ready -> \(NWConnection(from: group) == nil ? "nil" : "non-nil")")
        }
        let t0 = DispatchTime.now()
        while group.state != .ready { await sleepMs(1); if elapsedMs(since: t0) > 3000 { break } }
        log(tag, "attempt \(attempt) group ready after \(String(format: "%.1f", elapsedMs(since: t0))) ms")
        let s = NWConnection(from: group)
        if let s {
            s.stateUpdateHandler = { st in log(tag, "attempt \(attempt) stream state \(st)") }
            s.send(content: Data("ping\n".utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { e in log(tag, "attempt \(attempt) pre-ready send completion error=\(String(describing: e))") })
            s.start(queue: queue)
            let (data, end) = await receiveAll(s, tag: "\(tag) #\(attempt)", verbose: false)
            log(tag, "attempt \(attempt) reply='\(String(decoding: data, as: UTF8.self))' FIN=\(end.isComplete) err=\(String(describing: end.error)) in \(String(format: "%.1f", elapsedMs(since: t0))) ms")
            if let m = quicMetadata(s) { log(tag, "RESULT attempt \(attempt) stream TLS: \(describeTLS(m))") }
        } else {
            log(tag, "attempt \(attempt) NWConnection(from: group) returned nil before group ready")
        }
        if let gm = quicMetadata(group) { log(tag, "RESULT attempt \(attempt) group TLS: \(describeTLS(gm))") }
        group.cancel()
        await sleepMs(300)
    }
}

final class TrustAll: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        for t in metrics.transactionMetrics {
            log("urlsession", "metrics protocol=\(t.networkProtocolName ?? "nil") reusedConnection=\(t.isReusedConnection) proxy=\(t.isProxyConnection) fetchType=\(t.resourceFetchType.rawValue)")
        }
    }
}

func testURLSession() async {
    let tag = "urlsession"
    let delegate = TrustAll()
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    var req = URLRequest(url: URL(string: "https://localhost:\(port)/")!)
    req.assumesHTTP3Capable = true
    req.timeoutInterval = 10
    do {
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        log(tag, "RESULT status=\(http?.statusCode ?? -1) headers=\(http?.allHeaderFields ?? [:]) body='\(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))'")
    } catch {
        log(tag, "RESULT error \(error)")
    }
    await sleepMs(200)
    session.invalidateAndCancel()
}

switch test {
case "echo": await testEcho()
case "uni3": await testUni3()
case "reset": await testReset()
case "peerreset": await testPeerReset()
case "close": await testClose(variant: positional.count > 1 ? positional[1] : "group")
case "stall": await testStall()
case "bulk": await testBulk()
case "loop": await testLoop(n: positional.count > 1 ? Int(positional[1])! : 1000, concurrency: positional.count > 2 ? Int(positional[2])! : 1)
case "zerortt": await testZeroRTT()
case "urlsession": await testURLSession()
case "all":
    for t in [testEcho, testUni3, testReset, testPeerReset, { await testClose(variant: "group") }] { await t(); await sleepMs(300) }
default: print("unknown test \(test)")
}
