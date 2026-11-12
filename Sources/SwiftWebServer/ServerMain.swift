import ConfigFile
import Dispatch
import Foundation
import HTTP1
#if HTTP3
import HTTP3
#endif
import HTTPCore
import HTTPServer
import NetworkTransport

/// The shipped server (#0086): `Server` + HTTP/1.1 + `ErrorPages` + `StaticFiles`
/// (with conditional requests), configured by `http-config.json` and the command line.
///
/// Listeners (#0089): cleartext HTTP/1.1 always; HTTPS when the config has `tls`; HTTP/3 over
/// QUIC when it also has `http3` (by default on the TLS port number, UDP). All run under one
/// `Server`: one connection limit, one drain, and SIGTERM sends HTTP/3 GOAWAY too.
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

        Relative paths in the config file resolve against the file's directory. HTTPS and
        HTTP/3 are configured with the "tls" and "http3" keys. Prints "listening HOST:PORT"
        on stdout once bound (then "listening HOST:PORT (https)" and "(h3)" lines for the
        other listeners). SIGINT/SIGTERM shut down gracefully.
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
            try settings.validate()
            let handler = try settings.makeHandler()
            let configuration = settings.serverConfiguration
            do {
                try configuration.validate()
            } catch {
                throw ConfigFileError("\(error)")
            }
            let listeners = try makeListeners(settings, environment: environment)
            printError("\(name): serving \(settings.resolvedRoot)")
            return await serve(settings, listeners: listeners, handler: handler)
        } catch {
            printError("\(name): \(error)")
            return 1
        }
    }

    /// Cleartext first, then TLS, then QUIC: the server binds them in this order, so the QUIC
    /// listener can take the TLS listener's port number when that was 0. The TLS listener
    /// offers the protocol registry's ALPN tokens (#0088).
    static func makeListeners(_ settings: ServerSettings, environment: [String: String]) throws -> [ServerListener] {
        // POSIX sockets by default, Network.framework on request (#0113).
        let tcp = TCPConfiguration(allowLocalEndpointReuse: false)
        let host = settings.host
        var listeners: [ServerListener] = []
        switch settings.transport {
        case .bsd:
            listeners.append(.byteStream(try BSDSocketListener(configuration: .init(host: host, port: settings.port, tcp: tcp)), name: "http"))
        case .nw:
            listeners.append(.byteStream(try TCPListener(configuration: .init(host: host, port: settings.port, tcp: tcp)), name: "http"))
        }
        guard let tls = settings.tls, let path = settings.resolvedIdentityPath,
              let password = try settings.tlsPassword(environment: environment) else { return listeners }

        // In memory only (kSecImportToMemoryOnly): no keychain access (AGENTS.md).
        let identity: TLSIdentity
        do {
            identity = try TLSIdentity(pkcs12Path: path, password: password)
        } catch {
            throw ConfigFileError(key: "tls.identity", "cannot load TLS identity \(path): \(describe(identity: error))")
        }
        listeners.append(.byteStream(name: "https") { bind in
            try TCPListener(configuration: .init(host: host, port: tls.port, tcp: tcp),
                            tls: TLSConfiguration(identity: identity, alpn: bind.alpnTokens))
        })

        if let http3 = settings.http3 {
            #if HTTP3
            let tlsIndex = listeners.count - 1
            // After GOAWAY and the last response, wait for the client to close (curl does at
            // once) for up to the drain timeout instead of the default 1 s: CONNECTION_CLOSE
            // discards response bytes Network.framework still buffers for a slow reader.
            var configuration = H3Configuration()
            configuration.timeouts.closeLinger = max(.seconds(1), settings.drainTimeout ?? .seconds(30))
            listeners.append(.multiplexed(name: "h3", protocol: HTTP3(configuration: configuration)) { bind in
                let port = http3.port ?? bind.boundAddresses[tlsIndex].port
                return try QUICListener(configuration: .init(host: host, port: port, quic: QUICConfiguration(alpn: bind.alpnTokens)),
                                        identity: identity)
            })
            #else
            _ = http3
            throw ConfigFileError(key: "http3", "\"http3\": this build has no HTTP/3 (package trait HTTP3 is off)")
            #endif
        }
        return listeners
    }

    static func serve<H: HTTPHandler>(_ settings: ServerSettings, listeners: [ServerListener], handler: H) async -> Int32 {
        let server = Server(configuration: settings.serverConfiguration, listeners: listeners,
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
                    let names = server.listenerStatistics.map(\.name)
                    for (index, address) in addresses.enumerated() {
                        // The cleartext line stays "listening HOST:PORT" (scripts parse it).
                        let suffix = index == 0 || index >= names.count ? "" : " (\(names[index]))"
                        FileHandle.standardOutput.write(Data("listening \(address)\(suffix)\n".utf8))
                    }
                }
                group.addTask { try await server.run() }
            }
        } catch is CancellationError where server.lifecycleState == .stopped {
            // Stopped before it was running; waitUntilRunning reports that as cancellation.
        } catch {
            printError("\(name): cannot serve on \(settings.host):\(ports(settings)): \(describe(error))")
            return 1
        }
        printError("\(name): stopped")
        return 0
    }

    /// The configured ports, for error messages: `8080`, or `8080, https 8443, h3 8443`.
    static func ports(_ settings: ServerSettings) -> String {
        var text = "\(settings.port)"
        if let tls = settings.tls {
            text += ", https \(tls.port)"
            if let http3 = settings.http3 { text += ", h3 \(http3.port.map(String.init) ?? "\(tls.port)")" }
        }
        return text
    }

    static func describe(identity error: any Error) -> String {
        switch error as? TLSIdentityError {
        case .fileUnreadable?: "the file cannot be read"
        case .importFailed(let status)? where status == -25293: "wrong password (errSecAuthFailed)"
        case .importFailed(let status)?: "PKCS#12 import failed (OSStatus \(status))"
        case .noIdentity?: "the file holds no identity"
        case nil: "\(error)"
        }
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
