import Foundation
import Network
import Security
import AllocCounter

// MARK: - Logging

public let spikeStart = DispatchTime.now()

public func log(_ tag: String, _ message: String) {
    let base = spikeStart.uptimeNanoseconds  // lazily initialised global: read before now()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - base) / 1_000_000
    let line = String(format: "[%9.3f ms] %@ %@\n", ms, tag, message)
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
}

public func elapsedMs(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

// MARK: - Allocation counting (rough, process-wide)

public enum Allocs {
    public static func install() -> Bool { alloc_counter_install() }
    public static var count: UInt64 { alloc_counter_allocations() }
    public static var bytes: UInt64 { alloc_counter_bytes() }
}

// MARK: - Identity

public enum SpikeIdentity {
    /// Loads `identity/identity.p12` created by `make-identity.sh` via SecPKCS12Import.
    public static func load(path: String, password: String = "spike") throws -> SecIdentity {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var items: CFArray?
        // kSecImportToMemoryOnly (macOS 15+) is essential: without it SecPKCS12Import on macOS adds
        // the key to the login keychain, and the first TLS signature then blocks on a
        // SecurityAgent "allow access" prompt, so the QUIC handshake silently never completes.
        let options = [kSecImportExportPassphrase as String: password,
                       kSecImportToMemoryOnly as String: true] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]], let first = array.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "SecPKCS12Import failed: \(status)"])
        }
        // swiftlint:disable:next force_cast
        return identityRef as! SecIdentity
    }
}

// MARK: - Parameters

public struct QUICTuning: Sendable {
    public var initialMaxData: Int?
    public var initialMaxStreamDataBidiRemote: Int?
    public var initialMaxStreamDataBidiLocal: Int?
    public var initialMaxStreamDataUni: Int?
    public var initialMaxStreamsBidi: Int?
    public var initialMaxStreamsUni: Int?
    public var idleTimeoutMs: Int?
    public init() {}
}

public func applyTuning(_ quic: NWProtocolQUIC.Options, _ t: QUICTuning) {
    if let v = t.initialMaxData { quic.initialMaxData = v }
    if let v = t.initialMaxStreamDataBidiRemote { quic.initialMaxStreamDataBidirectionalRemote = v }
    if let v = t.initialMaxStreamDataBidiLocal { quic.initialMaxStreamDataBidirectionalLocal = v }
    if let v = t.initialMaxStreamDataUni { quic.initialMaxStreamDataUnidirectional = v }
    if let v = t.initialMaxStreamsBidi { quic.initialMaxStreamsBidirectional = v }
    if let v = t.initialMaxStreamsUni { quic.initialMaxStreamsUnidirectional = v }
    if let v = t.idleTimeoutMs { quic.idleTimeout = v }
}

public func serverParameters(identity: SecIdentity, alpn: [String], tuning: QUICTuning) -> NWParameters {
    let quic = NWProtocolQUIC.Options(alpn: alpn)
    applyTuning(quic, tuning)
    let secIdentity = sec_identity_create(identity)!
    sec_protocol_options_set_local_identity(quic.securityProtocolOptions, secIdentity)
    let params = NWParameters(quic: quic)
    params.allowLocalEndpointReuse = true
    return params
}

public func clientParameters(alpn: [String], tuning: QUICTuning, earlyData: Bool = false) -> NWParameters {
    let quic = NWProtocolQUIC.Options(alpn: alpn)
    applyTuning(quic, tuning)
    let sec = quic.securityProtocolOptions
    // Trust-everything verify block for the self-signed spike certificate.
    sec_protocol_options_set_verify_block(sec, { _, _, complete in complete(true) }, DispatchQueue.global())
    if earlyData {
        sec_protocol_options_set_tls_resumption_enabled(sec, true)
        sec_protocol_options_set_tls_tickets_enabled(sec, true)
    }
    let params = NWParameters(quic: quic)
    if earlyData && ProcessInfo.processInfo.environment["NO_FAST_OPEN"] != "1" { params.allowFastOpen = true }
    return params
}

public func uniStreamOptions(alpn: [String]) -> NWProtocolQUIC.Options {
    let o = NWProtocolQUIC.Options(alpn: alpn)
    o.direction = .unidirectional
    return o
}

// MARK: - Stream metadata helpers

public func quicMetadata(_ c: NWConnection) -> NWProtocolQUIC.Metadata? {
    c.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
}

public func quicMetadata(_ g: NWConnectionGroup) -> NWProtocolQUIC.Metadata? {
    g.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
}

/// RFC 9000 2.1: bit 0 = initiator (0 client, 1 server), bit 1 = direction (0 bidi, 1 uni).
public func describeStreamID(_ id: UInt64) -> String {
    let initiator = (id & 0x1) == 0 ? "client" : "server"
    let dir = (id & 0x2) == 0 ? "bidi" : "uni"
    return "id=\(id) (\(initiator)-initiated \(dir))"
}

public func describeTLS(_ m: NWProtocolQUIC.Metadata) -> String {
    let sec = m.securityProtocolMetadata
    let early = sec_protocol_metadata_get_early_data_accepted(sec)
    let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(sec)
    let alpn = m.negotiatedALPN ?? "nil"
    return "alpn=\(alpn) tlsVersion=0x\(String(version.rawValue, radix: 16)) earlyDataAccepted=\(early)"
}

// MARK: - Async wrappers over NWConnection callbacks

public final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<T, Never>
    public init(_ c: CheckedContinuation<T, Never>) { cont = c }
    public func resume(_ v: T) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        cont.resume(returning: v)
    }
}

public enum ReadyResult: Sendable { case ready, failed(NWError), cancelled }

/// Set QUIC_SPIKE_QUIET=1 to suppress per-stream state logging (for the Q9 loop).
public let quietStreams = ProcessInfo.processInfo.environment["QUIC_SPIKE_QUIET"] == "1"

public func startAndWait(_ c: NWConnection, queue: DispatchQueue, tag: String) async -> ReadyResult {
    await withCheckedContinuation { cont in
        let once = Once(cont)
        c.stateUpdateHandler = { state in
            if !quietStreams { log(tag, "state \(state)") }
            switch state {
            case .ready: once.resume(.ready)
            case .failed(let e): once.resume(.failed(e))
            case .cancelled: once.resume(.cancelled)
            default: break
            }
        }
        c.start(queue: queue)
    }
}

public func startAndWait(_ g: NWConnectionGroup, queue: DispatchQueue, tag: String,
                         onLaterState: (@Sendable (NWConnectionGroup.State) -> Void)? = nil) async -> ReadyResult {
    await withCheckedContinuation { cont in
        let once = Once(cont)
        g.stateUpdateHandler = { state in
            log(tag, "group state \(state)")
            onLaterState?(state)
            switch state {
            case .ready: once.resume(.ready)
            case .failed(let e): once.resume(.failed(e))
            case .cancelled: once.resume(.cancelled)
            default: break
            }
        }
        g.start(queue: queue)
    }
}

public struct ReceiveResult: Sendable {
    public var data: Data?
    public var isComplete: Bool
    public var error: NWError?
    public var contextIsFinal: Bool
}

public func receive(_ c: NWConnection, max: Int = 65536) async -> ReceiveResult {
    await withCheckedContinuation { cont in
        c.receive(minimumIncompleteLength: 1, maximumLength: max) { data, ctx, complete, error in
            cont.resume(returning: ReceiveResult(data: data, isComplete: complete, error: error,
                                                 contextIsFinal: ctx?.isFinal ?? false))
        }
    }
}

/// Reads until FIN or error. Returns all bytes and the terminating result.
public func receiveAll(_ c: NWConnection, tag: String, verbose: Bool = true) async -> (Data, ReceiveResult) {
    var all = Data()
    while true {
        let r = await receive(c)
        if let d = r.data { all.append(d) }
        if verbose {
            log(tag, "receive bytes=\(r.data?.count ?? 0) isComplete=\(r.isComplete) ctx.isFinal=\(r.contextIsFinal) error=\(String(describing: r.error))")
        }
        if r.isComplete || r.error != nil { return (all, r) }
        if r.data == nil || r.data!.isEmpty { return (all, r) }
    }
}

/// Gotcha: every send must use `isComplete: true`. Sending `.defaultMessage` with
/// `isComplete: false` leaves that message open, and a later send with a different context
/// (e.g. `.finalMessage`) is queued behind it forever: no bytes, no FIN, no completion.
/// Non-final chunks: `.defaultMessage` + `isComplete: true` (no FIN on a stream).
/// Final chunk: `.finalMessage` + `isComplete: true` (FIN).
public func send(_ c: NWConnection, _ data: Data?, fin: Bool) async -> NWError? {
    await withCheckedContinuation { cont in
        c.send(content: data, contentContext: fin ? .finalMessage : .defaultMessage, isComplete: true,
               completion: .contentProcessed { error in cont.resume(returning: error) })
    }
}

public func sleepMs(_ ms: Int) async { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }

// MARK: - HTTP/3 minimal encoding

public enum H3 {
    public static func varint(_ v: UInt64) -> [UInt8] {
        switch v {
        case 0..<64: return [UInt8(v)]
        case 64..<16384: return [UInt8(0x40 | (v >> 8)), UInt8(v & 0xff)]
        case 16384..<1_073_741_824:
            return [UInt8(0x80 | (v >> 24)), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        default:
            var out = [UInt8](repeating: 0, count: 8)
            for i in 0..<8 { out[i] = UInt8((v >> (UInt64(7 - i) * 8)) & 0xff) }
            out[0] |= 0xC0
            return out
        }
    }

    public static func frame(type: UInt64, payload: [UInt8]) -> [UInt8] {
        varint(type) + varint(UInt64(payload.count)) + payload
    }

    /// Control stream: stream type 0x00 + SETTINGS(QPACK_MAX_TABLE_CAPACITY=0, QPACK_BLOCKED_STREAMS=0).
    public static var controlStreamPreface: [UInt8] {
        varint(0x00) + frame(type: 0x04, payload: varint(0x01) + varint(0) + varint(0x07) + varint(0))
    }

    /// Response: HEADERS with QPACK prefix (RIC=0, base=0), static indexed `:status 200` (25)
    /// and `content-type: text/plain;charset=utf-8` (53), then a DATA frame.
    public static func response(body: [UInt8]) -> [UInt8] {
        let fieldSection: [UInt8] = [0x00, 0x00, 0xC0 | 25, 0xC0 | 53]
        return frame(type: 0x01, payload: fieldSection) + frame(type: 0x00, payload: body)
    }

    /// Decodes the frame types present in a buffer (best effort, for logging).
    public static func frameTypes(_ bytes: [UInt8]) -> [UInt64] {
        var i = 0
        var types: [UInt64] = []
        func readVarint() -> UInt64? {
            guard i < bytes.count else { return nil }
            let len = 1 << (bytes[i] >> 6)
            guard i + len <= bytes.count else { return nil }
            var v = UInt64(bytes[i] & 0x3f)
            for j in 1..<len { v = (v << 8) | UInt64(bytes[i + j]) }
            i += len
            return v
        }
        while let t = readVarint(), let l = readVarint() {
            types.append(t)
            i += Int(l)
        }
        return types
    }
}
