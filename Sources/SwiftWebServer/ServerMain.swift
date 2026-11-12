import ConfigFile
import Dispatch
import Foundation
import HTTP1
import HTTPCore
import HTTPServer
import NetworkTransport

/// The shipped server (#0086): `Server` + HTTP/1.1 + `ErrorPages` + `StaticFiles`
/// (with conditional requests), configured by `http-config.json` and the command line.
///
/// Exit status: 0 after a clean shutdown (SIGINT or SIGTERM drains open connections), 1 on a
/// configuration or startup error such as a bad config value or a port in use (#0004), with
/// a message on stderr, 2 on a usage error.
@main
enum ServerMain {
    static let name = "SwiftWebServer"

    static let usage = """
        usage: SwiftWebServer [--config FILE] [--root DIR] [--host HOST] [--port PORT]

          --config FILE   JSON config (see README "Configuration"); every key is optional.
                          Default: $ROOT_PATH/http-config.json when ROOT_PATH is set, else
                          ./http-config.json if it exists, else built-in defaults.
          --root DIR      directory to serve (overrides "root"; relative to the working
                          directory)
          --host HOST     numeric address to bind (overrides "host"; default 127.0.0.1)
          --port PORT     port to bind (overrides "port"; default 8080; 0 picks a free one)

        Relative paths in the config file resolve against the file's directory. Prints
        "listening HOST:PORT" on stdout once bound. SIGINT/SIGTERM shut down gracefully.
        """

    static func main() async {
        exit(await run(Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment))
    }

    /// Command-line overrides.
    struct Options {
        var config: String?
        var root: String?
        var host: String?
        var port: UInt16?
        var help = false
    }

    struct UsageError: Error, CustomStringConvertible {
        var description: String
    }

    static func parse(_ arguments: [String]) throws(UsageError) -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            var argument = arguments[index]
            index += 1
            var value: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                value = String(argument[argument.index(after: equals)...])
                argument = String(argument[..<equals])
            }
            if argument == "--help" || argument == "-h" {
                options.help = true
                continue
            }
            guard ["--config", "--root", "--host", "--port"].contains(argument) else {
                throw UsageError(description: "unknown argument '\(argument)'")
            }
            if value == nil {
                guard index < arguments.count else { throw UsageError(description: "missing value for \(argument)") }
                value = arguments[index]
                index += 1
            }
            let text = value!
            switch argument {
            case "--config": options.config = text
            case "--root": options.root = text
            case "--host": options.host = text
            default:
                guard let port = UInt16(text) else { throw UsageError(description: "invalid port '\(text)'") }
                options.port = port
            }
        }
        return options
    }

    /// The settings: config file, then command-line overrides. Warnings go to stderr.
    static func settings(_ options: Options, environment: [String: String]) throws(ConfigFileError) -> ServerSettings {
        let fileManager = FileManager.default
        var path = options.config
        var defaults = ServerSettings()
        if path == nil {
            // Legacy compatibility: ROOT_PATH is the directory holding http-config.json.
            let base = environment["ROOT_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? fileManager.currentDirectoryPath
            defaults.baseDirectory = base
            let candidate = ServerSettings.resolve("http-config.json", against: base)
            if fileManager.fileExists(atPath: candidate) { path = candidate }
        }
        var settings = defaults
        if let path {
            let file = try ConfigFile.load(path: path, defaults: defaults)
            for warning in file.warnings { printError("\(name): warning: \(warning)") }
            settings = file.settings
        }
        if let root = options.root {
            settings.root = root
            settings.baseDirectory = fileManager.currentDirectoryPath
        }
        if let host = options.host { settings.host = host }
        if let port = options.port { settings.port = port }
        return settings
    }

    static func run(_ arguments: [String], environment: [String: String]) async -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            printError("\(name): \(error)\n\n\(usage)")
            return 2
        }
        if options.help {
            print(usage)
            return 0
        }
        do {
            let settings = try settings(options, environment: environment)
            let handler = try settings.makeHandler()
            let configuration = settings.serverConfiguration
            do {
                try configuration.validate()
            } catch {
                throw ConfigFileError("\(error)")
            }
            printError("\(name): serving \(settings.resolvedRoot)")
            // Cleartext TCP: POSIX sockets by default, Network.framework on request (#0113).
            let tcp = TCPConfiguration(allowLocalEndpointReuse: false)
            switch settings.transport {
            case .bsd:
                let listener = try BSDSocketListener(configuration: .init(host: settings.host, port: settings.port, tcp: tcp))
                return await serve(settings, listener: listener, handler: handler)
            case .nw:
                let listener = try TCPListener(configuration: .init(host: settings.host, port: settings.port, tcp: tcp))
                return await serve(settings, listener: listener, handler: handler)
            }
        } catch {
            printError("\(name): \(error)")
            return 1
        }
    }

    static func serve<L: TransportListener, H: HTTPHandler>(_ settings: ServerSettings, listener: L, handler: H) async -> Int32 {
        let server = Server(configuration: settings.serverConfiguration, listeners: [listener],
                            protocols: [HTTP1(configuration: settings.http1Configuration)],
                            handler: handler)

        // Ignore the default actions first, so a signal is never fatal, then route both to a
        // graceful shutdown (#0003). The sources live until the server stops. A second signal
        // during the drain is harmless (#0005).
        let queue = DispatchQueue(label: "sws.signals")
        let sources = [SIGINT, SIGTERM].map { number -> any DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                printError("\(name): signal \(number), shutting down")
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
            printError("\(name): cannot serve on \(settings.host):\(settings.port): \(describe(error))")
            return 1
        }
        printError("\(name): stopped")
        return 0
    }

    /// A transport error with its POSIX meaning (`failed(code: 48)` reads "address already in use").
    static func describe(_ error: any Error) -> String {
        if case TransportError.failed(let code) = error, code > 0 {
            return "\(String(cString: strerror(code))) (errno \(code))"
        }
        return "\(error)"
    }
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}
