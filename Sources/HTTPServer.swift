import Foundation
import Network

enum HTTPServerError: Error {
    case configNotFound
}

final class HTTPServer: Sendable {
    let port: NWEndpoint.Port
    let publicDirectory: URL
    private let config: HTTPConfig
    private let listener: NWListener

    let exitHandler = ExitHandler()

    init(publicDirectory: String) throws {
        let rootPath = ProcessInfo.processInfo.environment["ROOT_PATH"] ?? FileManager.default.currentDirectoryPath
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).appending(path: publicDirectory)
        let config = try HTTPServer.loadConfig(at: rootURL)
        self.config = config

        self.port = NWEndpoint.Port(rawValue: UInt16(config.port))!
        self.publicDirectory = rootURL
        self.listener = try NWListener(using: .tcp, on: self.port)
        monitorListener()

        logger.log("Listening on port http://localhost:\(config.port)/")
    }

    private static func loadConfig(at rootURL: URL) throws -> HTTPConfig {
        let configURL = rootURL.appendingPathComponent("http-config.json")
        guard FileManager.default.fileExists(atPath: configURL.path()) else {
            logger.error("http-config.json not found at \(configURL.absoluteString)")
            throw HTTPServerError.configNotFound
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(HTTPConfig.self, from: data)
    }

    func monitorListener() {
        listener.stateUpdateHandler = { newState in
            switch newState {
            case .failed(let error):
                logger.error("Listener failed: \(error.localizedDescription)")
                Task {
                    await self.terminate()
                }
            case .ready:
                logger.info("Listener is ready on port \(self.port.rawValue)")
            default:
                break
            }
        }
    }

    func run() async throws {
        logger.log("Listening on port \(self.port.rawValue)")

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            self.handle(connection)
        }

        listener.start(queue: .global())
        try await exitHandler.wait()
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        Task {
            var buffer = Data()

            let stream = ConnectionStream(connection: connection)

            for await value in stream.values {
                switch value {
                case .data(let data):
                    buffer.append(data)
                case .error(let error):
                    logger.log("Receive error: \(error)")
                    let response = HTTPResponse(status: .internalServerError)
                    connection.send(content: response.data, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    break
                }

                guard let request = HTTPRequest.parse(from: buffer) else {
                    logger.log("Bad Request")
                    let response = HTTPResponse(status: .badRequest)
                    connection.send(content: response.data, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    break
                }

                logger.log("OK - \(request.method) \(request.path)")
                let response = await self.respond(to: request)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func respond(to request: HTTPRequest) async -> Data {
        guard request.isSupportedMethod else {
            return HTTPResponse(status: .methodNotAllowed).data
        }

        if config.blockList.contains(request.path) {
            return HTTPResponse(status: .forbidden).data
        }

        let relativePath = request.path.removingPercentEncoding ?? request.path
        var fileURL = publicDirectory.appendingPathComponent(relativePath).standardizedFileURL

        guard fileURL.path.hasPrefix(publicDirectory.path) else {
            return HTTPResponse(status: .forbidden).data
        }

        var isDir: ObjCBool = false

        // If the file doesn't exist and it's a directory, try appending the default index file
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
            fileURL.appendPathComponent(config.defaultIndex)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modDate = attributes[.modificationDate] as? Date else {
            return HTTPResponse(status: .notFound).data
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "E, dd MMM yyyy HH:mm:ss z"
        let lastModified = formatter.string(from: modDate)

        // Handle If-Modified-Since header
        if let ifModifiedSince = request.header(named: "If-Modified-Since"),
           let sinceDate = formatter.date(from: ifModifiedSince),
           modDate <= sinceDate {
            return HTTPResponse(
                status: .notModified,
                extraHeaders: ["Last-Modified": lastModified],
                includeBody: request.includeBody
            ).data
        }

        let extraHeaders: [String : String]
        if config.caching.enabled {
            extraHeaders = [
                "Last-Modified": lastModified,
                "Cache-Control": "public, max-age=\(config.caching.maxAge)"
            ]
        } else {
            extraHeaders = ["Last-Modified": lastModified]
        }

        return HTTPResponse(
            status: .ok,
            body: data,
            contentType: mimeType(for: fileURL),
            extraHeaders: extraHeaders,
            includeBody: request.includeBody
        ).data
    }

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        for type in config.mimeTypes {
            if type.pathExtensions.contains(ext) {
                return type.contentType
            }
        }
        return config.defaultMimeType
    }

    static func installSignalHandlers(server: HTTPServer) {
        let signals = [SIGINT, SIGTERM]

        logger.log("Installing signal handlers: \(signals)")

        for sig in signals {
            signal(sig, SIG_IGN) // ignore default C handler

            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Task {
                    switch sig {
                    case SIGINT:
                        logger.warning("Received SIGINT")
                        await server.interrupt()
                    case SIGTERM:
                        logger.warning("Received SIGTERM")
                        await server.terminate()
                    default:
                        logger.warning("Received \(sig)")
                        break
                    }
                }
            }
            source.resume()
        }
    }

    func interrupt() async {
        await exitHandler.interrupt()
    }

    func terminate() async {
        await exitHandler.terminate()
    }
}

enum StreamValue {
    case data(Data)
    case error(Error)
}

struct ConnectionStream {
    let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    var values: AsyncStream<StreamValue> {
        let stream: AsyncStream<StreamValue>
        let continuation: AsyncStream<StreamValue>.Continuation
        (stream, continuation) = AsyncStream.makeStream(of: StreamValue.self, bufferingPolicy: .unbounded)

        Task {
            var isComplete = false
            while !isComplete {
                isComplete = await next(continuation: continuation)
            }
            continuation.finish()
        }

        return stream
    }

    func next(continuation: AsyncStream<StreamValue>.Continuation) async -> Bool {
        await withCheckedContinuation { checkedContinuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error {
                    continuation.yield(.error(error))
                } else if let data {
                    continuation.yield(.data(data))
                }
                checkedContinuation.resume(with: .success(isComplete))
            }
        }
    }
}
