import AccessLog
import Dispatch
import Foundation
import HTTP1
import HTTPCore
import HTTPServer
import NetworkTransport
import StaticFiles

/// `sws-bench serve`: the new stack's server entry point (#0079) until the shipped
/// `SwiftWebServer` executable moves off Legacy (#0086).
///
/// Runs a ``Server`` over a `TCPListener` speaking HTTP/1.1 (#0080) with a built-in handler:
/// a `POST` gets its body echoed back, a `PUT` gets the length of its body (read in bounded
/// chunks, so any size works up to `--max-body-size`), and every other request gets `200` with
/// `Hello, World!\n`, or with `--body-size` bytes of `x` (#0081).
/// SIGINT and SIGTERM start a graceful shutdown through `DispatchSource` signal sources, the
/// one place `DispatchQueue` is allowed outside NetworkTransport. No handler calls `exit()`
/// and nothing calls `dispatchMain()`: the command returns its status after `run()` returns.
///
/// Exit status: 0 after a clean shutdown, 1 on a configuration or startup error (with a
/// message on stderr), 2 on a usage error.
enum ServeCommand {
    static let usage = """
        usage: sws-bench serve [--config FILE] [--host HOST] [--port PORT] [--transport nw|bsd]
                               [--max-connections N] [--drain-timeout SECONDS] [--body-size N]
                               [--max-body-size N] [--root DIR]
                               [--access-log PATH|-] [--access-log-format F] [--metrics]

          --config FILE        JSON object with any of "host", "port", "transport",
                               "maxConnections", "drainTimeout" (seconds); flags override it
          --host HOST          numeric address to bind (default 127.0.0.1)
          --transport T        bsd: POSIX sockets + kqueue (BSDSocketListener, default);
                               nw: Network.framework (TCPListener)
          --port PORT          port to bind; 0 picks a free one (default 0)
          --max-connections N  connections served at once (default 1024)
          --drain-timeout S    grace period for open connections on shutdown (default 10)
          --body-size N        answer with N bytes of "x" instead of "Hello, World!\n"
          --max-body-size N    largest request body accepted; larger gets 413 (default 10485760)
          --root DIR           serve the files under DIR with StaticFiles (#0084) instead of
                               the built-in handler
          --access-log PATH    append an access log line per request to PATH (O_APPEND);
                               `-` writes to stdout (#0090)
          --access-log-format F  common (default), combined or json
          --metrics            serve request metrics at GET /metrics (Prometheus text)

        Serves HTTP/1.1 (keep-alive, pipelining). POST echoes the request body, PUT answers
        with the body's length, anything else gets 200 text/plain. With --root, every request
        goes to StaticFiles (GET and HEAD only; other methods get 405).

        Prints "listening HOST:PORT" on stdout once bound. SIGINT/SIGTERM shut down gracefully.

        With --h3, serves HTTP/3 over QUIC instead (`sws-bench serve --h3 --help`).
        """

    struct Settings: Equatable {
        var host = "127.0.0.1"
        var port: UInt16 = 0
        var transport = TransportKind.bsd
        var maxConnections = 1024
        var drainTimeout = 10.0
        var bodySize: Int?
        var maxBodySize = HTTP1Configuration.defaultMaxBodySize
        var root: String?
        /// `-` for stdout.
        var accessLog: String?
        var accessLogFormat = AccessLogFormat.common
        var metrics = false
    }

    struct ConfigError: Error, CustomStringConvertible {
        var description: String
    }

    static func run(_ argv: [String]) async throws -> Int32 {
        if argv.contains("--h3") { return try await H3ServeCommand.run(argv.filter { $0 != "--h3" }) }
        var args = try Arguments(argv, valueOptions: ["config", "host", "port", "transport", "max-connections", "drain-timeout", "body-size", "max-body-size", "root", "access-log", "access-log-format"])
        if args.flag("help") == true { print(usage); return 0 }
        let configPath = args.string("config")
        let host = args.string("host")
        let port = try args.int("port")
        let transport = try args.string("transport").map { argument throws(Arguments.Failure) in try TransportKind(argument: argument) }
        let maxConnections = try args.int("max-connections")
        let drainTimeout = try args.seconds("drain-timeout")
        let bodySize = try args.int("body-size")
        let maxBodySize = try args.int("max-body-size")
        let root = args.string("root")
        let accessLog = args.string("access-log")
        let accessLogFormat = args.string("access-log-format")
        let metrics = args.flag("metrics") ?? false
        try args.checkAllConsumed()

        var settings = Settings()
        do {
            if let configPath { settings = try loadConfig(path: configPath) }
        } catch {
            printError("sws-bench serve: \(error)")
            return 1
        }
        if let host { settings.host = host }
        if let port {
            guard let value = UInt16(exactly: port) else {
                printError("sws-bench serve: invalid port \(port)")
                return 1
            }
            settings.port = value
        }
        if let transport { settings.transport = transport }
        if let maxConnections { settings.maxConnections = maxConnections }
        if let drainTimeout { settings.drainTimeout = drainTimeout }
        if let bodySize {
            guard bodySize >= 0 else {
                printError("sws-bench serve: invalid body size \(bodySize)")
                return 1
            }
            settings.bodySize = bodySize
        }
        if let maxBodySize {
            guard maxBodySize >= 0 else {
                printError("sws-bench serve: invalid max body size \(maxBodySize)")
                return 1
            }
            settings.maxBodySize = maxBodySize
        }
        if let root { settings.root = root }
        if let accessLog { settings.accessLog = accessLog }
        if let accessLogFormat {
            switch accessLogFormat {
            case "common": settings.accessLogFormat = .common
            case "combined": settings.accessLogFormat = .combined
            case "json": settings.accessLogFormat = .json
            default:
                printError("sws-bench serve: invalid access log format \(accessLogFormat) (common, combined or json)")
                return 2
            }
        }
        settings.metrics = metrics
        return await serve(settings)
    }

    static func loadConfig(path: String) throws -> Settings {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ConfigError(description: "cannot read config file \(path): \(error.localizedDescription)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError(description: "config file \(path) is not a JSON object")
        }
        var settings = Settings()
        for (key, value) in object {
            switch (key, value) {
            case ("host", let text as String):
                settings.host = text
            case ("port", let number as NSNumber) where UInt16(exactly: number.doubleValue) != nil:
                settings.port = UInt16(number.doubleValue)
            case ("transport", let text as String) where TransportKind(rawValue: text) != nil:
                settings.transport = TransportKind(rawValue: text)!
            case ("maxConnections", let number as NSNumber) where Int(exactly: number.doubleValue) != nil:
                settings.maxConnections = Int(number.doubleValue)
            case ("drainTimeout", let number as NSNumber) where number.doubleValue >= 0:
                settings.drainTimeout = number.doubleValue
            case ("host", _), ("port", _), ("transport", _), ("maxConnections", _), ("drainTimeout", _):
                throw ConfigError(description: "config file \(path): invalid value for \"\(key)\"")
            default:
                throw ConfigError(description: "config file \(path): unknown key \"\(key)\"")
            }
        }
        return settings
    }

    static func serve(_ settings: Settings) async -> Int32 {
        let configuration = ServerConfiguration(
            maxConnections: settings.maxConnections,
            drainTimeout: .milliseconds(Int64((settings.drainTimeout * 1000).rounded())))
        do {
            try configuration.validate()
            // Cleartext TCP: POSIX sockets by default, Network.framework on request (#0113).
            // TLS and QUIC listeners stay on Network.framework.
            let tcp = TCPConfiguration(allowLocalEndpointReuse: false)
            switch settings.transport {
            case .bsd:
                let listener = try BSDSocketListener(configuration: .init(host: settings.host, port: settings.port, tcp: tcp))
                return await serve(settings, configuration: configuration, listener: listener)
            case .nw:
                let listener = try TCPListener(configuration: .init(host: settings.host, port: settings.port, tcp: tcp))
                return await serve(settings, configuration: configuration, listener: listener)
            }
        } catch {
            printError("sws-bench serve: \(error)")
            return 1
        }
    }

    static func serve<L: TransportListener>(_ settings: Settings, configuration: ServerConfiguration, listener: L) async -> Int32 {
        let protocols = [HTTP1(configuration: HTTP1Configuration(maxBodySize: settings.maxBodySize))]
        if let root = settings.root {
            let files: StaticFiles
            do {
                files = try StaticFiles(root: root)
            } catch {
                printError("sws-bench serve: cannot serve root \(root): \(error)")
                return 1
            }
            return await serve(settings, configuration: configuration, listener: listener, protocols: protocols,
                               handler: files)
        }
        return await serve(settings, configuration: configuration, listener: listener, protocols: protocols,
                           handler: ServeHandler(hello: HelloHandler(bodySize: settings.bodySize),
                                                 maxBodySize: settings.maxBodySize))
    }

    /// Serves `handler`, behind the access log and the metrics endpoint when asked for. Each
    /// combination is its own chain type, so what is not asked for is not in the chain (#0090).
    static func serve<L: TransportListener, H: HTTPHandler>(
        _ settings: Settings, configuration: ServerConfiguration, listener: L, protocols: [any ConnectionProtocol],
        handler: H
    ) async -> Int32 {
        let metrics = settings.metrics ? AccessLogMetrics() : nil
        var log: AccessLog?
        if let path = settings.accessLog {
            log = AccessLog(format: settings.accessLogFormat,
                            destination: path == "-" ? .standardOutput : .file(path: path), metrics: metrics)
        } else if let metrics {
            log = AccessLog(metrics: metrics)
        }
        switch (log, metrics) {
        case (let log?, let metrics?):
            return await run(Server(configuration: configuration, listeners: [listener], protocols: protocols) {
                MetricsEndpoint(metrics: metrics)
                log
                handler
            }, settings)
        case (let log?, nil):
            return await run(Server(configuration: configuration, listeners: [listener], protocols: protocols) {
                log
                handler
            }, settings)
        default:
            return await run(Server(configuration: configuration, listeners: [listener], protocols: protocols,
                                    handler: handler), settings)
        }
    }

    /// Runs `server` until SIGINT or SIGTERM has drained it.
    static func run<L: TransportListener, H: HTTPHandler>(_ server: Server<L, H>, _ settings: Settings) async -> Int32 {
        // Ignore the default actions first, so a signal is never fatal, then route both to a
        // graceful shutdown. The sources are kept alive until the server stops (#0003).
        let queue = DispatchQueue(label: "sws.serve.signals")
        let sources = [SIGINT, SIGTERM].map { number -> any DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                printError("sws-bench serve: signal \(number), shutting down")
                server.requestShutdown()
            }
            source.resume()
            return source
        }
        defer {
            for source in sources { source.cancel() }
        }

        do {
            try await withThrowingDiscardingTaskGroup { group in
                group.addTask {
                    let addresses = try await server.waitUntilRunning()
                    for address in addresses {
                        FileHandle.standardOutput.write(Data("listening \(address)\n".utf8))
                    }
                }
                group.addTask { try await server.run() }
            }
        } catch is CancellationError where server.lifecycleState == .stopped {
            // Stopped before it was running; waitUntilRunning reports that as cancellation.
        } catch {
            printError("sws-bench serve: cannot serve on \(settings.host):\(settings.port): \(describe(error))")
            return 1
        }
        printError("sws-bench serve: stopped")
        return 0
    }
}

/// A transport error with its POSIX meaning (`failed(code: 48)` reads "address already in use").
func describe(_ error: any Error) -> String {
    if case TransportError.failed(let code) = error, code > 0 {
        return "\(String(cString: strerror(code))) (errno \(code))"
    }
    return "\(error)"
}

/// Answers every request with one prebuilt `200 text/plain` response. Returning a copy of a
/// stored response retains its buffers and allocates nothing. `sws-bench h1conn` measures the
/// connection loop with it, so it stays free of suspension points.
struct HelloHandler: HTTPHandler {
    let response: HTTPResponse

    init(bodySize: Int? = nil) {
        var body = ByteBuffer()
        if let bodySize {
            body.append(contentsOf: repeatElement(UInt8(ascii: "x"), count: bodySize))
        } else {
            body.append("Hello, World!\n")
        }
        var headers = HTTPFields()
        headers.append(.contentType, "text/plain; charset=utf-8")
        response = HTTPResponse(status: .ok, headers: headers, body: .bytes(body))
    }

    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        response
    }
}

/// The `serve` handler (#0081): `POST` gets its body echoed back (collected up to
/// `maxBodySize`), `PUT` gets its body's length (read chunk by chunk, so memory stays at one
/// receive whatever the size), and everything else goes to ``HelloHandler``.
struct ServeHandler: HTTPHandler {
    let hello: HelloHandler
    let maxBodySize: Int

    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        switch request.method {
        case .post: try await echo(request)
        case .put: try await length(request)
        default: try await hello.handle(request, context: context)
        }
    }

    func echo(_ request: HTTPRequest) async throws -> HTTPResponse {
        var headers = HTTPFields()
        headers.append(.contentType, "application/octet-stream")
        return HTTPResponse(status: .ok, headers: headers, body: .bytes(try await request.body.collect(upTo: maxBodySize)))
    }

    func length(_ request: HTTPRequest) async throws -> HTTPResponse {
        var length = 0
        for try await chunk in request.body { length += chunk.readableBytes }
        var body = ByteBuffer()
        body.append(decimal: length)
        body.append("\n")
        var headers = HTTPFields()
        headers.append(.contentType, "text/plain; charset=utf-8")
        return HTTPResponse(status: .ok, headers: headers, body: .bytes(body))
    }
}
