// WebSocket and Upgrade passthrough for ReverseProxy (#0123).
//
// HTTP/1.1 downstream: a request with `Connection: upgrade` and an `Upgrade` token the mount
// allows (`websocket` when the mount opts in, or a token in
// `ProxyTunnelConfiguration.allowedUpgradeProtocols`) is sent upstream on a dedicated
// connection with its `Upgrade`/`Connection` fields. A `101` answer becomes a `101` with a
// `.tunnel` body that splices the two byte streams; any other answer is proxied normally.
//
// HTTP/2 (RFC 8441) and HTTP/3 (RFC 9220) downstream: an extended CONNECT with
// `:protocol websocket` becomes an HTTP/1.1 `GET` with `Upgrade: websocket` and a generated
// `Sec-WebSocket-Key` upstream. A `101` whose `Sec-WebSocket-Accept` matches becomes a `200`
// with a `.tunnel` body over the request stream.
//
// Upgraded connections never go back to the pool.
import CryptoKit
import Darwin
public import HTTPCore
import NetworkTransport
import Synchronization

/// Settings for upgraded (tunnelled) proxy connections (#0123).
public struct ProxyTunnelConfiguration: Sendable {
    /// Bound on connecting to the upstream and reading its answer to the upgrade request.
    public var handshakeTimeout: Duration
    /// The tunnel closes when no byte moves in either direction for this long; `nil` for no
    /// limit.
    public var idleTimeout: Duration?
    /// After one direction ends (a half-close), how long the other direction may continue
    /// before both are closed.
    public var halfCloseTimeout: Duration
    /// HTTP/1.1 `Upgrade` tokens besides `websocket` that are passed through (lowercased,
    /// without a version, e.g. `"tls"`). `websocket` is controlled per mount by
    /// ``ProxyMount/websocket``. Other tokens are stripped, as hop-by-hop fields.
    public var allowedUpgradeProtocols: Set<String>
    /// Bytes read from one side per receive.
    public var bufferSize: Int

    public init(handshakeTimeout: Duration = .seconds(30), idleTimeout: Duration? = .seconds(300),
                halfCloseTimeout: Duration = .seconds(30), allowedUpgradeProtocols: Set<String> = [],
                bufferSize: Int = 16 * 1024) {
        self.handshakeTimeout = handshakeTimeout
        self.idleTimeout = idleTimeout
        self.halfCloseTimeout = halfCloseTimeout
        self.allowedUpgradeProtocols = allowedUpgradeProtocols
        self.bufferSize = bufferSize
    }
}

extension ReverseProxy: ExtendedConnectProvider {
    /// `websocket` when any mount opts in, so HTTP/2 and HTTP/3 advertise
    /// `SETTINGS_ENABLE_CONNECT_PROTOCOL`.
    public var extendedConnectProtocols: [String] {
        mounts.contains { $0.config.websocket } ? ["websocket"] : []
    }
}

enum ProxyUpgradeKind: Equatable {
    /// An HTTP/1.1 `Upgrade` to `token`, passed through as is.
    case http1(token: String)
    /// An extended CONNECT for `websocket`, mapped to an HTTP/1.1 WebSocket handshake.
    case extendedConnect
}

enum ProxyUpgradeDecision: Equatable {
    /// Not an upgrade: proxy normally.
    case none
    /// An extended CONNECT this mount does not tunnel.
    case refuse
    case upgrade(ProxyUpgradeKind)
}

extension ReverseProxy {
    /// Classifies `request` for `mount`.
    func upgradeDecision(_ request: HTTPRequest, mount: ProxyMount) -> ProxyUpgradeDecision {
        if request.method == .connect && request.connectProtocol.length > 0 {
            let token = request.string(of: request.connectProtocol).lowercased()
            return token == "websocket" && mount.websocket ? .upgrade(.extendedConnect) : .refuse
        }
        guard request.version >= .http1_1 else { return .none }
        let connection = ReverseProxyHeaders.connectionTokens(request.headers)
        guard connection.contains("upgrade") else { return .none }
        for i in 0..<request.headers.count where request.headers.nameString(at: i).lowercased() == "upgrade" {
            for offered in request.headers.valueString(at: i).split(separator: ",") {
                let token = offered.trimmingSpaces()
                let name = token.split(separator: "/").first.map { String($0).lowercased() } ?? ""
                if name == "websocket" ? mount.websocket : tunnel.allowedUpgradeProtocols.contains(name) {
                    return .upgrade(.http1(token: token))
                }
            }
        }
        return .none
    }

    /// The upgrade hook called from ``handle(_:context:next:)``: a response when the request
    /// is an upgrade this mount handles (or refuses), `nil` to proxy it normally.
    func proxyUpgradeIfRequested(_ request: HTTPRequest, decodedPath: String, mount: CompiledMount,
                                 target: UpstreamTarget, clientHost: String?,
                                 context: RequestContext) async throws -> HTTPResponse? {
        let kind: ProxyUpgradeKind
        switch upgradeDecision(request, mount: mount.config) {
        case .none: return nil
        case .refuse: return HTTPResponse(status: .notImplemented)
        case .upgrade(let k): kind = k
        }
        var upstreamRequest = makeUpstreamRequest(request, decodedPath: decodedPath, mount: mount, target: target,
                                                  clientHost: clientHost, context: context)
        var key: String?
        switch kind {
        case .http1(let token):
            upstreamRequest.headers.append(name: "Upgrade", value: token)
        case .extendedConnect:
            upstreamRequest.method = .get
            var headers = HTTPFields()
            let fields = upstreamRequest.headers
            for i in 0..<fields.count where fields.nameString(at: i).lowercased() != "sec-websocket-key" {
                headers.append(name: fields.nameString(at: i), value: fields.valueString(at: i))
            }
            let generated = ProxyWebSocketKey.generate()
            key = generated
            headers.append(name: "Upgrade", value: "websocket")
            headers.append(name: "Sec-WebSocket-Key", value: generated)
            upstreamRequest.headers = headers
        }
        upstreamRequest.headers.append(name: "Connection", value: "Upgrade")

        let connection: UpstreamConnection
        let head: UpstreamResponseHead
        do {
            let request = upstreamRequest
            (connection, head) = try await Self.withTimeout(tunnel.handshakeTimeout) {
                try await UpstreamTunnel.open(request, address: target.address)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as UpstreamError {
            if error == .cancelled { throw CancellationError() }
            return HTTPResponse(status: error == .timeout ? .gatewayTimeout : .badGateway)
        } catch {
            return HTTPResponse(status: .badGateway)
        }

        if head.status.code == 101 {
            var headers = ReverseProxyHeaders.stripHopByHop(head.headers)
            // #0122: an explicitly configured `timeouts.idle` also bounds the tunnel; `.zero`
            // turns the tunnel's idle limit off (#0128).
            let configuration = mount.config.policy.tunnelIdleTimeout.map { idle in
                var c = tunnel
                c.idleTimeout = idle == .zero ? nil : idle
                return c
            } ?? tunnel
            let pending = connection.pending
            connection.pending = []
            switch kind {
            case .http1(let token):
                let upgrade = Self.values(head.headers, "upgrade").first ?? token
                headers.append(name: "Upgrade", value: upgrade)
                headers.append(name: "Connection", value: "Upgrade")
                return HTTPResponse(status: .switchingProtocols, headers: headers, body: .tunnel { downstream, tunnelContext in
                    await UpstreamTunnel.splice(downstream, upstream: connection.transport, prefix: pending,
                                                context: tunnelContext, configuration: configuration)
                })
            case .extendedConnect:
                let expected = ProxyWebSocketKey.accept(forKey: key ?? "")
                let accepts = Self.values(head.headers, "sec-websocket-accept")
                guard accepts == [expected],
                      Self.values(head.headers, "upgrade").contains(where: { $0.lowercased() == "websocket" }) else {
                    await connection.close()
                    return HTTPResponse(status: .badGateway)
                }
                var out = HTTPFields()
                for i in 0..<headers.count where headers.nameString(at: i).lowercased() != "sec-websocket-accept" {
                    out.append(name: headers.nameString(at: i), value: headers.valueString(at: i))
                }
                return HTTPResponse(status: .ok, headers: out, body: .tunnel { downstream, tunnelContext in
                    await UpstreamTunnel.splice(downstream, upstream: connection.transport, prefix: pending,
                                                context: tunnelContext, configuration: configuration)
                })
            }
        }
        // An extended CONNECT answered 2xx without switching cannot be relayed as a tunnel.
        if kind == .extendedConnect && (200..<300).contains(head.status.code) {
            await connection.close()
            return HTTPResponse(status: .badGateway)
        }
        // Not upgraded: relay the answer and close the dedicated connection after it.
        return mapResponse(UpstreamTunnel.response(head, connection: connection), mount: mount, target: target,
                           clientHost: clientHost, secure: context.connection.isSecure)
    }

    static func values(_ fields: HTTPFields, _ lowercasedName: String) -> [String] {
        (0..<fields.count).filter { fields.nameString(at: $0).lowercased() == lowercasedName }
            .map { fields.valueString(at: $0) }
    }

    /// Runs `body`, throwing ``UpstreamError/timeout`` when it takes longer than `limit`.
    static func withTimeout<R: Sendable>(_ limit: Duration,
                                         _ body: @escaping @Sendable () async throws -> R) async throws -> R {
        try await withThrowingTaskGroup(of: R?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else { throw UpstreamError.timeout }
            return value
        }
    }
}

/// Dedicated upstream connections for upgrades, and the byte splice (#0123).
enum UpstreamTunnel {
    /// Connects, sends the upgrade request head and reads the final response head (skipping
    /// interim 1xx other than 101). Bytes after the head stay in the connection's `pending`.
    static func open(_ request: UpstreamRequest, address: UpstreamAddress) async throws -> (UpstreamConnection, UpstreamResponseHead) {
        let connection = try await connect(address)
        do {
            try await connection.transport.send(serializeHead(request), endOfStream: false)
            let parser = UpstreamResponseParser()
            while true {
                if let (head, used) = try parser.parseHead(connection.pending, requestMethod: request.method) {
                    connection.pending.removeFirst(used)
                    if (100..<200).contains(head.status.code) && head.status.code != 101 { continue }
                    return (connection, head)
                }
                guard try await connection.fill() else { throw UpstreamError.closedEarly }
            }
        } catch {
            await connection.close()
            if let e = error as? UpstreamError { throw e }
            if error is CancellationError { throw UpstreamError.cancelled }
            throw UpstreamError.closedEarly
        }
    }

    static func connect(_ address: UpstreamAddress) async throws -> UpstreamConnection {
        do {
            switch address {
            case .tcp(let host, let port):
                return UpstreamConnection(transport: try await BSDSocketTransport.connect(host: host, port: port))
            case .unix(let path):
                return UpstreamConnection(transport: try await BSDSocketTransport.connect(unixPath: path))
            }
        } catch is CancellationError {
            throw UpstreamError.cancelled
        } catch {
            throw UpstreamError.connectFailed("\(error)")
        }
    }

    /// The request head; the target already carries the base path. Bodies are not sent.
    static func serializeHead(_ request: UpstreamRequest) -> ByteBuffer {
        var buffer = ByteBuffer(capacity: 512)
        UpstreamHTTP1Client.writeHead(request, framing: .none, keepConnection: true, into: &buffer)
        return buffer
    }

    /// A non-101 answer as an ``UpstreamResponse`` whose body closes the connection after it.
    static func response(_ head: UpstreamResponseHead, connection: UpstreamConnection) -> UpstreamResponse {
        let reader = BodyReader(framing: head.framing, connection: connection, reusable: false) { conn, _ in
            await conn.close()
        }
        let knownLength: Int? = switch head.framing {
        case .none: 0
        case .length(let n): n
        default: nil
        }
        return UpstreamResponse(status: head.status, headers: head.headers,
                                body: UpstreamResponseBody(knownLength: knownLength,
                                                           next: { try await reader.next() },
                                                           discard: { await reader.finish(reuse: false) }))
    }

    // MARK: Splice

    /// Why one child of the splice ended.
    enum End: Sendable {
        /// The direction reached end of stream and forwarded it (half-close).
        case finished
        /// A receive or send failed.
        case failed
        case idle
        case halfCloseExpired
        case drain
        /// A timer or signal child was cancelled; ignore.
        case cancelled
    }

    final class Activity: Sendable {
        let last = Atomic<UInt64>(now())
        let halfClosedAt = Atomic<UInt64>(0)
        func touch() { last.store(Self.now(), ordering: .relaxed) }
        static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    }

    /// Copies bytes both ways between `downstream` and `upstream` until both directions end,
    /// one fails, the idle or half-close timer fires, or the server drains; then closes both.
    /// Each side is read only after the previous chunk was accepted by the other side, so a
    /// slow reader applies backpressure end to end.
    static func splice<D: ByteStreamTransport, U: ByteStreamTransport>(
        _ downstream: D, upstream: U, prefix: [UInt8], context: TunnelContext,
        configuration: ProxyTunnelConfiguration
    ) async {
        let activity = Activity()
        let size = max(configuration.bufferSize, 1024)
        var reason = CloseReason.normal
        await withTaskGroup(of: End.self) { group in
            group.addTask {
                if !prefix.isEmpty {
                    do { try await downstream.send(ByteBuffer(bytes: prefix), endOfStream: false) } catch { return .failed }
                }
                return await pump(from: upstream, to: downstream, size: size, activity: activity)
            }
            group.addTask { await pump(from: downstream, to: upstream, size: size, activity: activity) }
            group.addTask {
                await context.shutdown.wait()
                return context.shutdown.isTriggered ? .drain : .cancelled
            }
            group.addTask { await watchdog(activity, configuration: configuration) }
            var finished = 0
            loop: while let end = await group.next() {
                switch end {
                case .finished:
                    finished += 1
                    if finished == 2 { break loop }
                    activity.halfClosedAt.store(Activity.now(), ordering: .relaxed)
                case .cancelled:
                    continue
                case .failed:
                    reason = .abort
                    break loop
                case .idle, .halfCloseExpired, .drain:
                    break loop
                }
            }
            group.cancelAll()
            await downstream.close(reason)
            await upstream.close(reason)
        }
    }

    static func pump<S: ByteStreamTransport, D: ByteStreamTransport>(
        from source: S, to destination: D, size: Int, activity: Activity
    ) async -> End {
        var buffer = ByteBuffer(capacity: size)
        do {
            while true {
                buffer.clear()
                let n = try await source.receive(into: &buffer, maxLength: size)
                if n == 0 {
                    try await destination.send(ByteBuffer(), endOfStream: true)
                    return .finished
                }
                activity.touch()
                try await destination.send(buffer, endOfStream: false)
                activity.touch()
            }
        } catch {
            return .failed
        }
    }

    static func watchdog(_ activity: Activity, configuration: ProxyTunnelConfiguration) async -> End {
        let idle = configuration.idleTimeout.map(nanoseconds)
        let halfClose = nanoseconds(configuration.halfCloseTimeout)
        var tick = min(configuration.idleTimeout ?? .seconds(1), configuration.halfCloseTimeout, .seconds(1)) / 4
        if tick < .milliseconds(5) { tick = .milliseconds(5) }
        while true {
            do { try await Task.sleep(for: tick) } catch { return .cancelled }
            let now = Activity.now()
            if let idle, now &- activity.last.load(ordering: .relaxed) > idle { return .idle }
            let halfClosedAt = activity.halfClosedAt.load(ordering: .relaxed)
            if halfClosedAt != 0, now &- halfClosedAt > halfClose { return .halfCloseExpired }
        }
    }

    static func nanoseconds(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(max(seconds, 0)) * 1_000_000_000 + UInt64(max(attoseconds, 0) / 1_000_000_000)
    }
}

/// `Sec-WebSocket-Key` generation and `Sec-WebSocket-Accept` computation (RFC 6455 §4).
enum ProxyWebSocketKey {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Base64 of 16 random bytes.
    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    static func accept(forKey key: String) -> String {
        base64(Array(Insecure.SHA1.hash(data: Array((key + guid).utf8))))
    }

    static func base64(_ bytes: [UInt8]) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        var out: [UInt8] = []
        out.reserveCapacity((bytes.count + 2) / 3 * 4)
        var i = 0
        while i < bytes.count {
            let b0 = bytes[i]
            let b1 = i + 1 < bytes.count ? bytes[i + 1] : 0
            let b2 = i + 2 < bytes.count ? bytes[i + 2] : 0
            out.append(alphabet[Int(b0 >> 2)])
            out.append(alphabet[Int((b0 & 0x03) << 4 | b1 >> 4)])
            out.append(i + 1 < bytes.count ? alphabet[Int((b1 & 0x0F) << 2 | b2 >> 6)] : UInt8(ascii: "="))
            out.append(i + 2 < bytes.count ? alphabet[Int(b2 & 0x3F)] : UInt8(ascii: "="))
            i += 3
        }
        return String(decoding: out, as: UTF8.self)
    }
}
