// QUIC spike server (#0071).
//
// usage: quic-server [--port N (default 0 = ephemeral)] [--tcp-same-port] [--identity path]
//                    [--h3-reset CODE | --h3-close CODE]
// Binds to 127.0.0.1 only (requiredLocalEndpoint) so no firewall prompt is triggered.
//
// ALPN "h3": minimal HTTP/3 (control + QPACK encoder/decoder uni streams, fixed response).
// ALPN "sws-echo": command per bidi stream; the first line selects the behaviour.
import Foundation
import Network
import QUICSpikeKit

let echoALPN = "sws-echo"
nonisolated(unsafe) var h3Reset: UInt64? = nil
nonisolated(unsafe) var h3Close: UInt64? = nil
let (port, tcpSamePort, identityPath): (UInt16, Bool, String) = {
    var port: UInt16 = 0
    var tcpSamePort = false
    var identityPath = "identity/identity.p12"
    var args = CommandLine.arguments.dropFirst()
    while let a = args.popFirst() {
        switch a {
        case "--port": port = UInt16(args.popFirst()!)!
        case "--tcp-same-port": tcpSamePort = true
        case "--identity": identityPath = args.popFirst()!
        case "--h3-reset": h3Reset = UInt64(args.popFirst()!, radix: 16)!
        case "--h3-close": h3Close = UInt64(args.popFirst()!, radix: 16)!
        default: fatalError("unknown arg \(a)")
        }
    }
    return (port, tcpSamePort, identityPath)
}()

if ProcessInfo.processInfo.environment["QUIC_SPIKE_ALLOCS"] == "1" { _ = Allocs.install() }
let queue = DispatchQueue(label: "quic-spike.server")
let identity = try SpikeIdentity.load(path: identityPath)

let tuning: QUICTuning = {
    var tuning = QUICTuning()
    tuning.initialMaxStreamsBidi = 200
    tuning.initialMaxStreamsUni = 16
    tuning.initialMaxData = 1 << 20                  // 1 MiB connection window
    tuning.initialMaxStreamDataBidiRemote = 128 << 10 // 128 KiB per client-opened bidi stream
    tuning.initialMaxStreamDataBidiLocal = 128 << 10
    tuning.initialMaxStreamDataUni = 64 << 10
    tuning.idleTimeoutMs = 30_000
    return tuning
}()

let params = serverParameters(identity: identity, alpn: ["h3", echoALPN], tuning: tuning)
params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
let listener = try NWListener(using: params)

final class Stats: @unchecked Sendable {
    let lock = NSLock()
    var streamsAccepted = 0
    var pingsServed = 0
    func inc(_ kp: ReferenceWritableKeyPath<Stats, Int>) { lock.lock(); self[keyPath: kp] += 1; lock.unlock() }
    func get(_ kp: KeyPath<Stats, Int>) -> Int { lock.lock(); defer { lock.unlock() }; return self[keyPath: kp] }
}
let stats = Stats()

listener.stateUpdateHandler = { state in
    log("listener", "state \(state) port=\(listener.port.map { "\($0)" } ?? "?")")
    if case .ready = state, tcpSamePort, let p = listener.port { startTCP(on: p) }
}

listener.newConnectionGroupHandler = { group in
    let gid = UUID().uuidString.prefix(4)
    let tag = "group[\(gid)]"
    log(tag, "new group descriptor=\(type(of: group.descriptor)) \(group.descriptor)")

    group.newConnectionHandler = { stream in
        stats.inc(\.streamsAccepted)
        registry.add(stream, to: group)
        if ProcessInfo.processInfo.environment["BUMP_MAX_STREAMS"] == "1", let gm = quicMetadata(group) {
            // Raise the peer's bidi stream credit (MAX_STREAMS) ourselves.
            let n = stats.get(\.streamsAccepted)
            if gm.localMaxStreamsBidirectional < n + 100 { gm.localMaxStreamsBidirectional = n + 200 }
        }
        Task { await handleInboundStream(stream, group: group, groupTag: tag) }
    }
    Task {
        let r = await startAndWait(group, queue: queue, tag: tag)
        guard case .ready = r else { return }
        guard let m = quicMetadata(group) else { log(tag, "no QUIC metadata on group"); return }
        log(tag, "ready: \(describeTLS(m)) remoteIdleTimeout=\(m.remoteIdleTimeout) remoteMaxStreamsBidi=\(m.remoteMaxStreamsBidirectional) remoteMaxStreamsUni=\(m.remoteMaxStreamsUnidirectional)")
        if m.negotiatedALPN == "h3" && ProcessInfo.processInfo.environment["H3_NO_CONTROL"] != "1" {
            // Q3/HTTP3: open control, QPACK encoder, QPACK decoder streams.
            let prefaces: [(String, [UInt8])] = [("control", H3.controlStreamPreface), ("qpack-enc", H3.varint(0x02)), ("qpack-dec", H3.varint(0x03))]
            for (name, bytes) in prefaces {
                Task { await openUni(group: group, groupTag: tag, name: name, bytes: bytes, fin: false, alpn: ["h3"]) }
            }
        }
    }
}

func openUni(group: NWConnectionGroup, groupTag: String, name: String, bytes: [UInt8], fin: Bool, alpn: [String]) async {
    let tag = "\(groupTag) uni-out[\(name)]"
    guard let c = NWConnection(from: group, using: uniStreamOptions(alpn: alpn)) else {
        log(tag, "NWConnection(from:using:) returned nil"); return
    }
    let r = await startAndWait(c, queue: queue, tag: tag)
    guard case .ready = r else { return }
    if let m = quicMetadata(c) { log(tag, "opened \(describeStreamID(m.streamIdentifier))") }
    let err = await send(c, Data(bytes), fin: fin)
    log(tag, "sent \(bytes.count) bytes fin=\(fin) error=\(String(describing: err))")
    // Keep non-FIN (critical) streams alive by holding a reference for the group's lifetime.
    if !fin { keepAlive.append(c) }
}

final class Registry: @unchecked Sendable {
    let lock = NSLock(); var map: [ObjectIdentifier: [NWConnection]] = [:]
    func add(_ c: NWConnection, to g: NWConnectionGroup) { lock.lock(); map[ObjectIdentifier(g), default: []].append(c); lock.unlock() }
    func all(_ g: NWConnectionGroup) -> [NWConnection] { lock.lock(); defer { lock.unlock() }; return map[ObjectIdentifier(g)] ?? [] }
}
let registry = Registry()

final class KeepAlive: @unchecked Sendable {
    let lock = NSLock(); var items: [NWConnection] = []
    func append(_ c: NWConnection) { lock.lock(); items.append(c); lock.unlock() }
}
let keepAlive = KeepAlive()

func handleInboundStream(_ stream: NWConnection, group: NWConnectionGroup, groupTag: String) async {
    let r = await startAndWait(stream, queue: queue, tag: "\(groupTag) stream?")
    guard case .ready = r else { return }
    guard let m = quicMetadata(stream) else { log(groupTag, "stream without QUIC metadata"); return }
    let id = m.streamIdentifier
    let tag = "\(groupTag) stream[\(id)]"
    // Gotcha: inbound streams can become ready before the group's stateUpdateHandler reports
    // .ready (seen with URLSession), and group metadata ALPN is then nil. Prefer stream metadata.
    let alpn = m.negotiatedALPN ?? quicMetadata(group)?.negotiatedALPN
    if !quietStreams { log(tag, "alpn stream=\(m.negotiatedALPN ?? "nil") group=\(quicMetadata(group)?.negotiatedALPN ?? "nil") group.state=\(group.state)") }
    if !quietStreams { log(tag, "inbound ready \(describeStreamID(id)) alpn=\(alpn ?? "nil")") }

    if alpn == "h3" {
        if id & 0x2 != 0 {
            // Client uni stream (control / QPACK). Read and log forever.
            let (data, end) = await receiveAll(stream, tag: tag, verbose: false)
            log(tag, "client uni stream ended bytes=\(data.count) first=\(data.first.map { String($0) } ?? "-") complete=\(end.isComplete) error=\(String(describing: end.error))")
            return
        }
        let (data, end) = await receiveAll(stream, tag: tag, verbose: false)
        log(tag, "h3 request bytes=\(data.count) frames=\(H3.frameTypes([UInt8](data))) fin=\(end.isComplete)")
        if let code = h3Reset {
            m.streamApplicationErrorCode = code
            log(tag, "h3: resetting request stream with 0x\(String(code, radix: 16))")
            stream.cancel()
            return
        }
        let resp = H3.response(body: Array("hello from NWProtocolQUIC h3\n".utf8))
        if let code = h3Close {
            // Close before responding so the client is still waiting and reports the close.
            _ = resp
            if let gm = quicMetadata(group) { gm.applicationError = NWProtocolQUIC.ApplicationError(code: code, reason: "spike h3 close") }
            let streams = registry.all(group) + keepAlive.items
            log(tag, "h3: closing connection with 0x\(String(code, radix: 16)); cancelling \(streams.count) streams then group")
            if ProcessInfo.processInfo.environment["H3_CLOSE_MODE"] == "group-first" {
                group.cancel()
                log(tag, "h3: group.cancel() first; streams cancelled 500 ms later")
                await sleepMs(500)
                for c in streams { c.cancel() }
            } else if ProcessInfo.processInfo.environment["H3_CLOSE_MODE"] == "force" {
                for c in streams { c.forceCancel() }
                group.cancel()
            } else {
                for c in streams { c.cancel() }
                group.cancel()
            }
            return
        }
        let err = await send(stream, Data(resp), fin: true)
        log(tag, "h3 response sent error=\(String(describing: err))")
        if ProcessInfo.processInfo.environment["H3_CLOSE_AFTER"] == "1" {
            // Force the client onto a fresh (resumed) connection for its next request (Q8).
            await sleepMs(200)
            for c in registry.all(group) + keepAlive.items { c.cancel() }
            group.cancel()
        }
        return
    }

    // sws-echo command protocol: first line is the command.
    var buffer = Data()
    var finSeen = false
    while !buffer.contains(0x0a) {
        let rr = await receive(stream)
        if let d = rr.data { buffer.append(d) }
        if rr.isComplete { finSeen = true }
        if rr.error != nil || rr.isComplete { break }
    }
    guard let nl = buffer.firstIndex(of: 0x0a) else { log(tag, "no command; fin=\(finSeen)"); return }
    let command = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
    let rest = buffer[(nl + 1)...]
    let parts = command.split(separator: " ")
    let quiet = command == "ping"
    if !quiet { log(tag, "command '\(command)' leftover=\(rest.count) finSeen=\(finSeen)") }

    switch parts.first.map(String.init) ?? "" {
    case "ping":
        // Q9 loop. Client sends "ping\n" + FIN; respond "pong" + FIN.
        if !finSeen { _ = await receiveAll(stream, tag: tag, verbose: false) }
        _ = await send(stream, Data("pong".utf8), fin: true)
        stats.inc(\.pingsServed)

    case "echo":
        // Q4: echo everything; log isComplete; respond with FIN after the peer's FIN.
        var total = rest.count
        if !rest.isEmpty { _ = await send(stream, Data(rest), fin: false) }
        if !finSeen {
            while true {
                let rr = await receive(stream)
                log(tag, "echo receive bytes=\(rr.data?.count ?? 0) isComplete=\(rr.isComplete) ctx.isFinal=\(rr.contextIsFinal) error=\(String(describing: rr.error))")
                if let d = rr.data, !d.isEmpty { total += d.count; _ = await send(stream, d, fin: false) }
                if rr.isComplete || rr.error != nil { break }
            }
        }
        let err = await send(stream, nil, fin: true)
        log(tag, "echo done total=\(total), sent FIN (nil content, .finalMessage, isComplete=true) error=\(String(describing: err))")

    case "uni3":
        // Q3: open three server-initiated unidirectional streams to the client.
        for i in 1...3 {
            await openUni(group: group, groupTag: groupTag, name: "uni\(i)", bytes: Array("uni stream \(i)\n".utf8), fin: true, alpn: [echoALPN])
        }
        _ = await send(stream, Data("opened 3 uni\n".utf8), fin: true)

    case "reset":
        // Q5 outbound: set an application error code, then cancel → RESET_STREAM/STOP_SENDING?
        let code = parts.count > 1 ? UInt64(parts[1], radix: 16)! : 0x10c
        _ = await send(stream, Data("partial-before-reset\n".utf8), fin: false)
        await sleepMs(100)
        m.streamApplicationErrorCode = code
        log(tag, "setting streamApplicationErrorCode=0x\(String(code, radix: 16)) then cancel()")
        stream.cancel()

    case "peerreset":
        // Q5 inbound: keep reading; the client will reset with its own code.
        _ = await send(stream, Data("ready-for-reset\n".utf8), fin: false)
        while true {
            let rr = await receive(stream)
            log(tag, "peerreset receive bytes=\(rr.data?.count ?? 0) isComplete=\(rr.isComplete) error=\(String(describing: rr.error)) streamAppErr=0x\(String(m.streamApplicationErrorCode, radix: 16))")
            if rr.isComplete || rr.error != nil { break }
        }
        // Also try a send after the peer reset to see how STOP_SENDING surfaces.
        let err = await send(stream, Data("after".utf8), fin: true)
        log(tag, "peerreset send-after error=\(String(describing: err)) streamAppErr=0x\(String(m.streamApplicationErrorCode, radix: 16)) state=\(stream.state)")

    case "close":
        // Q6: close the whole connection with an application error code via group metadata.
        let code = parts.count > 1 ? UInt64(parts[1], radix: 16)! : 0x101
        _ = await send(stream, Data("closing\n".utf8), fin: false)
        await sleepMs(100)
        let variant = parts.count > 2 ? String(parts[2]) : "group"
        switch variant {
        case "group":
            if let gm = quicMetadata(group) {
                gm.applicationError = NWProtocolQUIC.ApplicationError(code: code, reason: "spike close")
                log(tag, "group metadata applicationError set to 0x\(String(code, radix: 16)) (readback 0x\(String(gm.applicationError.code, radix: 16))); calling group.cancel()")
            }
            group.cancel()
        case "stream":
            m.applicationError = NWProtocolQUIC.ApplicationError(code: code, reason: "spike close via stream")
            log(tag, "stream metadata applicationError set to 0x\(String(code, radix: 16)); calling group.cancel()")
            group.cancel()
        case "streamcancel":
            m.applicationError = NWProtocolQUIC.ApplicationError(code: code, reason: "spike close via stream")
            log(tag, "stream metadata applicationError set; calling stream.cancel() then group.cancel()")
            stream.cancel()
            group.cancel()
        case "all":
            // Set the code on group metadata, cancel every stream (inbound + the ones we opened), then the group.
            if let gm = quicMetadata(group) { gm.applicationError = NWProtocolQUIC.ApplicationError(code: code, reason: "spike close all") }
            let streams = registry.all(group)
            log(tag, "applicationError=0x\(String(code, radix: 16)) on group metadata; cancelling \(streams.count) inbound streams (states: \(streams.map { "\($0.state)" })) then group")
            for c in streams { c.cancel() }
            group.cancel()
        case "force":
            if let gm = quicMetadata(group) { gm.applicationError = NWProtocolQUIC.ApplicationError(code: code, reason: "spike close force") }
            let streams = registry.all(group)
            log(tag, "applicationError=0x\(String(code, radix: 16)); forceCancel() \(streams.count) streams then group.cancel()")
            for c in streams { c.forceCancel() }
            group.cancel()
        default:
            log(tag, "plain group.cancel()")
            group.cancel()
        }

    case "stall":
        // Q7: do not call receive for N ms; client measures how far it gets.
        let ms = parts.count > 1 ? Int(parts[1])! : 3000
        log(tag, "stalling reads for \(ms) ms")
        await sleepMs(ms)
        var total = rest.count
        let start = DispatchTime.now()
        while true {
            let rr = await receive(stream)
            total += rr.data?.count ?? 0
            if rr.isComplete || rr.error != nil { break }
        }
        log(tag, "drained \(total) bytes in \(String(format: "%.1f", elapsedMs(since: start))) ms after stall")
        _ = await send(stream, Data("drained \(total)\n".utf8), fin: true)

    case "bulk":
        // Q7 server side: send N bytes in 64 KiB chunks, logging send-completion timing.
        let total = parts.count > 1 ? Int(parts[1])! : (4 << 20)
        let chunk = Data(repeating: 0x61, count: 64 << 10)
        var sent = 0
        let start = DispatchTime.now()
        var lastLog = 0.0
        while sent < total {
            let n = min(chunk.count, total - sent)
            let t0 = DispatchTime.now()
            let err = await send(stream, chunk.prefix(n), fin: sent + n >= total)
            sent += n
            let dt = elapsedMs(since: t0)
            if dt > 50 || elapsedMs(since: start) - lastLog > 250 || err != nil {
                lastLog = elapsedMs(since: start)
                log(tag, "bulk sent=\(sent) completion-latency=\(String(format: "%.1f", dt)) ms error=\(String(describing: err))")
            }
            if err != nil { break }
        }
        log(tag, "bulk finished \(sent) bytes in \(String(format: "%.1f", elapsedMs(since: start))) ms")

    case "stats":
        let reply = "allocs=\(Allocs.count) bytes=\(Allocs.bytes) streams=\(stats.get(\.streamsAccepted)) pings=\(stats.get(\.pingsServed))\n"
        _ = await send(stream, Data(reply.utf8), fin: true)

    default:
        _ = await send(stream, Data("unknown command\n".utf8), fin: true)
    }
}

listener.start(queue: queue)

func startTCP(on p: NWEndpoint.Port) {
    // Q10: TCP listener on the same port number as the UDP/QUIC listener (loopback only).
    do {
        let tcpParams = NWParameters.tcp
        tcpParams.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: p)
        let tcp = try NWListener(using: tcpParams)
        tcp.stateUpdateHandler = { log("tcp-listener", "state \($0) port=\(tcp.port.map { "\($0)" } ?? "?")") }
        tcp.newConnectionHandler = { c in
            c.start(queue: queue)
            c.send(content: Data("HTTP/1.1 200 OK\r\ncontent-length: 4\r\nconnection: close\r\n\r\ntcp\n".utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
        }
        tcp.start(queue: queue)
        keepTCP = tcp
    } catch {
        log("tcp-listener", "init failed: \(error)")
    }
}
nonisolated(unsafe) var keepTCP: NWListener?

dispatchMain()
