import Dispatch
import Foundation
import HTTP3
import HTTPCore
import NetworkTransport

/// `sws-bench serve --h3`: HTTP/3 over a QUIC listener (#0101) with the same handler as the
/// HTTP/1.1 `serve` (``ServeHandler``): `POST` echoes the body, `PUT` answers its length, and
/// everything else gets the hello response.
///
/// The TLS identity is a PKCS#12 file imported in memory only (`TLSIdentity`, which uses
/// `kSecImportToMemoryOnly`); the default is the gitignored test identity from
/// `scripts/make-test-identity.sh` (#0072). Nothing touches the keychain (AGENTS.md).
///
/// Prints `listening HOST:PORT` once bound. SIGINT/SIGTERM close the listener and every
/// connection with `H3_NO_ERROR`.
enum H3ServeCommand {
    static let usage = """
        usage: sws-bench serve --h3 [--host HOST] [--port PORT] [--body-size N]
                                    [--max-body-size N] [--identity FILE] [--identity-password PW]

          --host HOST              numeric address to bind (default 127.0.0.1)
          --port PORT              UDP port to bind; 0 picks a free one (default 0)
          --body-size N            answer GET with N bytes of "x" instead of "Hello, World!\\n"
          --max-body-size N        largest POST body echoed (default 10485760)
          --identity FILE          PKCS#12 identity (default .test-identity/server.p12)
          --identity-password PW   its password (default the test identity's)
        """

    static func run(_ argv: [String]) async throws -> Int32 {
        var args = try Arguments(argv, valueOptions: [
            "host", "port", "body-size", "max-body-size", "identity", "identity-password",
        ])
        if args.flag("help") == true { print(usage); return 0 }
        let host = args.string("host") ?? "127.0.0.1"
        let port = try args.int("port") ?? 0
        let bodySize = try args.int("body-size")
        let maxBodySize = try args.int("max-body-size") ?? 10 << 20
        let identityPath = args.string("identity") ?? ".test-identity/server.p12"
        let password = args.string("identity-password") ?? "sws-test-password"
        try args.checkAllConsumed()

        guard let portValue = UInt16(exactly: port) else {
            printError("sws-bench serve --h3: invalid port \(port)")
            return 1
        }
        let listener: QUICListener
        let boundPort: UInt16
        do {
            let identity = try TLSIdentity(pkcs12Path: identityPath, password: password)
            listener = try QUICListener(
                configuration: .init(host: host, port: portValue, quic: QUICConfiguration(alpn: HTTP3.alpnTokens)),
                identity: identity)
            boundPort = try await listener.start()
        } catch {
            printError("sws-bench serve --h3: cannot serve on \(host):\(port): \(describe(error))")
            return 1
        }
        FileHandle.standardOutput.write(Data("listening \(TransportAddress(host: host, port: boundPort))\n".utf8))

        let shutdown = ShutdownSignal()
        let queue = DispatchQueue(label: "sws.serve.h3.signals")
        let sources = [SIGINT, SIGTERM].map { number -> any DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                printError("sws-bench serve --h3: signal \(number), shutting down")
                shutdown.trigger()
            }
            source.resume()
            return source
        }
        defer {
            for source in sources { source.cancel() }
        }

        let handler = ServeHandler(hello: HelloHandler(bodySize: bodySize), maxBodySize: maxBodySize)
        await serve(listener, handler: handler, shutdown: shutdown)
        printError("sws-bench serve --h3: stopped")
        return 0
    }

    static func serve<H: HTTPHandler>(_ listener: QUICListener, handler: H, shutdown: ShutdownSignal) async {
        let http3 = HTTP3()
        await withDiscardingTaskGroup { group in
            group.addTask {
                await shutdown.wait()
                await listener.close()
            }
            do {
                for try await connection in listener.connections {
                    group.addTask {
                        let context = ConnectionContext(info: connection.info, shutdown: shutdown)
                        await http3.run(connection, handler: handler, context: context)
                    }
                }
            } catch {
                printError("sws-bench serve --h3: listener failed: \(describe(error))")
            }
            shutdown.trigger()
        }
    }
}
