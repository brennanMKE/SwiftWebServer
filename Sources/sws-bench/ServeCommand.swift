import Dispatch
import Foundation
import HTTPCore
import HTTPServer
import NetworkTransport

/// `sws-bench serve`: the new stack's server entry point (#0079) until the shipped
/// `SwiftWebServer` executable moves off Legacy (#0086).
///
/// Runs a ``Server`` over a `TCPListener` with an echo protocol (HTTP/1.1 arrives with #0080).
/// SIGINT and SIGTERM start a graceful shutdown through `DispatchSource` signal sources, the
/// one place `DispatchQueue` is allowed outside NetworkTransport. No handler calls `exit()`
/// and nothing calls `dispatchMain()`: the command returns its status after `run()` returns.
///
/// Exit status: 0 after a clean shutdown, 1 on a configuration or startup error (with a
/// message on stderr), 2 on a usage error.
enum ServeCommand {
    static let usage = """
        usage: sws-bench serve [--config FILE] [--host HOST] [--port PORT]
                               [--max-connections N] [--drain-timeout SECONDS]

          --config FILE        JSON object with any of "host", "port", "maxConnections",
                               "drainTimeout" (seconds); flags override it
          --host HOST          numeric address to bind (default 127.0.0.1)
          --port PORT          port to bind; 0 picks a free one (default 0)
          --max-connections N  connections served at once (default 1024)
          --drain-timeout S    grace period for open connections on shutdown (default 10)

        Prints "listening HOST:PORT" on stdout once bound. SIGINT/SIGTERM shut down gracefully.
        """

    struct Settings: Equatable {
        var host = "127.0.0.1"
        var port: UInt16 = 0
        var maxConnections = 1024
        var drainTimeout = 10.0
    }

    struct ConfigError: Error, CustomStringConvertible {
        var description: String
    }

    static func run(_ argv: [String]) async throws -> Int32 {
        var args = try Arguments(argv, valueOptions: ["config", "host", "port", "max-connections", "drain-timeout"])
        if args.flag("help") == true { print(usage); return 0 }
        let configPath = args.string("config")
        let host = args.string("host")
        let port = try args.int("port")
        let maxConnections = try args.int("max-connections")
        let drainTimeout = try args.seconds("drain-timeout")
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
        if let maxConnections { settings.maxConnections = maxConnections }
        if let drainTimeout { settings.drainTimeout = drainTimeout }
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
            case ("maxConnections", let number as NSNumber) where Int(exactly: number.doubleValue) != nil:
                settings.maxConnections = Int(number.doubleValue)
            case ("drainTimeout", let number as NSNumber) where number.doubleValue >= 0:
                settings.drainTimeout = number.doubleValue
            case ("host", _), ("port", _), ("maxConnections", _), ("drainTimeout", _):
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
        let listener: TCPListener
        do {
            try configuration.validate()
            listener = try TCPListener(configuration: TCPListener.Configuration(
                host: settings.host, port: settings.port,
                tcp: TCPConfiguration(allowLocalEndpointReuse: false)))
        } catch {
            printError("sws-bench serve: \(error)")
            return 1
        }
        let server = Server(configuration: configuration, listeners: [listener],
                            protocols: [EchoProtocol()], handler: EmptyHandler())

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

/// Echoes bytes until end of stream, a shutdown, or cancellation at the drain deadline.
struct EchoProtocol: ConnectionProtocol {
    static var alpnTokens: [String] { [] }

    static func matchesCleartextPreface(_ bytes: borrowing ByteBuffer) -> SniffResult { .match }

    func run<T: ByteStreamTransport, H: HTTPHandler>(_ t: T, handler: H, context: ConnectionContext) async {
        var buffer = ByteBuffer(capacity: 16 * 1024)
        while !context.shutdown.isTriggered {
            buffer.clear()
            guard let count = try? await t.receive(into: &buffer, maxLength: 16 * 1024), count > 0 else { break }
            guard (try? await t.send(buffer, endOfStream: false)) != nil else { break }
        }
        await t.close(.normal)
    }
}

/// Answers every request with `204 No Content` (unused by ``EchoProtocol``).
struct EmptyHandler: HTTPHandler {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        HTTPResponse(status: .noContent)
    }
}
