import Foundation
import Network
import CryptoKit
import Dispatch
import os.log

enum HTTPServerError: Error {
    case configNotFound
}

public final class HTTPServer: Sendable {
    let port: NWEndpoint.Port
    let publicDirectory: URL
    private let config: HTTPConfig
    private let listener: NWListener

    let exitHandler = ExitHandler()

    public init(publicDirectory: String) throws {
        let rootPath = ProcessInfo.processInfo.environment["ROOT_PATH"] ?? FileManager.default.currentDirectoryPath
        let currentDir = URL(fileURLWithPath: rootPath)
        let rootURL = URL(fileURLWithPath: publicDirectory, relativeTo: currentDir).standardizedFileURL
        let config = try HTTPServer.loadConfig(at: rootURL)
        self.config = config

        self.port = NWEndpoint.Port(rawValue: UInt16(config.port))!
        self.publicDirectory = rootURL
        self.listener = try NWListener(using: .tcp, on: self.port)
        monitorListener()

        logger.log("Listening on port http://localhost:\(config.port)/")
    }

    public func start() async throws {
        logger.log("Listening on port \(self.port.rawValue)")

        listener.newConnectionHandler = { connection in
            logger.debug("New connection accepted from \(String(describing: connection.endpoint))")
            connection.start(queue: .global())
            self.handle(connection)
        }

        logger.debug("Starting listener on port \(self.port.rawValue)")
        listener.start(queue: .global())
        try await exitHandler.wait()
        logger.debug("Listener shutting down")
        listener.cancel()
    }

    public func stop() async {
        logger.log("Stopping server...")
        listener.cancel()
    }

    // MARK: - Private -

    private static func loadConfig(at rootURL: URL) throws -> HTTPConfig {
        let configURL = rootURL.appendingPathComponent("http-config.json")
        guard FileManager.default.fileExists(atPath: configURL.path()) else {
            logger.error("http-config.json not found at \(configURL.path(), privacy: .public)")
            throw HTTPServerError.configNotFound
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(HTTPConfig.self, from: data)
    }

    private func monitorListener() {
        listener.stateUpdateHandler = { newState in
            switch newState {
            case .failed(let error):
                logger.error("Listener failed: \(error.localizedDescription)")
                Task {
                    await self.terminate()
                }
            case .ready:
                logger.info("Listener is ready on port \(self.port.rawValue)")
            case .setup:
                logger.debug("Listener setup")
            case .waiting(let error):
                logger.warning("Listener waiting: \(error, privacy: .public)")
            case .cancelled:
                logger.debug("Listener cancelled")
            default:
                logger.debug("Listener in unknown state: \(String(describing: newState), privacy: .public)")
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        logger.debug("Setting up connection state monitoring for \(String(describing: connection.endpoint), privacy: .public)")

        // Monitor connection state changes
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.debug("Connection is ready: \(String(describing: connection.endpoint), privacy: .public)")
            case .waiting(let error):
                logger.warning("Connection is waiting: \(error, privacy: .public)")
            case .failed(let error):
                logger.error("Connection failed: \(error, privacy: .public)")
            case .setup:
                logger.debug("Connection is setting up")
            case .preparing:
                logger.debug("Connection is preparing")
            case .cancelled:
                logger.debug("Connection was cancelled")
            default:
                logger.debug("Connection is in unknown state: \(String(describing: state), privacy: .public)")
            }
        }

        Task {
            logger.debug("Starting to handle connection from \(String(describing: connection.endpoint))")
            var buffer = Data()

            let stream = ConnectionStream(connection: connection)

            for await value in stream.values {
                switch value {
                case .data(let data):
                    logger.debug("Received \(data.count) bytes of data")
                    buffer.append(data)
                case .error(let error):
                    logger.error("Receive error: \(error)")
                    let response = HTTPResponse(status: .internalServerError)
                    connection.send(content: response.data, completion: .contentProcessed { _ in
                        logger.debug("Connection closed due to error")
                        connection.cancel()
                    })
                    break
                }

                guard let request = HTTPRequest.parse(from: buffer) else {
                    logger.error("Failed to parse request from buffer of size \(buffer.count)")
                    let response = HTTPResponse(status: .badRequest)
                    connection.send(content: response.data, completion: .contentProcessed { _ in
                        logger.debug("Connection closed after bad request")
                        connection.cancel()
                    })
                    break
                }

                logger.debug("Received request: \(request.method) \(request.path) with headers: \(request.headers)")

                // Check for WebSocket upgrade request
                if request.isWebSocketUpgrade {
                    logger.debug("WebSocket upgrade request received for path: \(request.path)")
                    if WebSocketUpgrade.validateUpgradeRequest(request) {
                        logger.debug("WebSocket upgrade request is valid, creating upgrade response")
                        let response = WebSocketUpgrade.createUpgradeResponse(request)
                        connection.send(content: response.data, completion: .contentProcessed { error in
                            if let error = error {
                                logger.error("Failed to send WebSocket upgrade response: \(error)")
                                connection.cancel()
                                return
                            }

                            logger.debug("WebSocket handshake completed successfully")
                            let webSocket = WebSocketConnection(connection: connection)
                            Task {
                                logger.debug("Starting WebSocket connection")
                                await webSocket.start()
                            }
                        })
                    } else {
                        logger.error("Invalid WebSocket upgrade request: missing required headers")
                        let response = HTTPResponse(status: .badRequest)
                        connection.send(content: response.data, completion: .contentProcessed { _ in
                            logger.debug("Connection closed after invalid WebSocket upgrade request")
                            connection.cancel()
                        })
                    }
                    return
                }

                // Handle regular HTTP request
                logger.debug("Processing regular HTTP request for path: \(request.path)")
                let response = await self.respond(to: request)
                let httpResponse = HTTPResponse(status: .ok, headers: [:], body: response)
                logger.debug("Sending response for \(request.path) with status: \(httpResponse.statusText) and headers: \(httpResponse.headers)")
                connection.send(content: httpResponse.data, completion: .contentProcessed { _ in
                    logger.debug("Connection closed after response")
                    connection.cancel()
                })
            }

            logger.debug("Connection handling completed for \(String(describing: connection.endpoint))")
        }
    }

    private func respond(to request: HTTPRequest) async -> Data {
        logger.debug("Responding to request: \(request.method) \(request.path)")

        guard request.isSupportedMethod else {
            logger.error("Unsupported method: \(request.method)")
            return HTTPResponse(status: .methodNotAllowed).data
        }

        if config.blockList.contains(request.path) {
            logger.error("Blocked path: \(request.path)")
            return HTTPResponse(status: .forbidden).data
        }

        let relativePath = request.path.removingPercentEncoding ?? request.path
        var fileURL = publicDirectory.appendingPathComponent(relativePath).standardizedFileURL

        logger.debug("Mapped path \(request.path) to file URL: \(fileURL.path)")

        guard fileURL.path.hasPrefix(publicDirectory.path) else {
            logger.error("Path traversal attempt detected: \(fileURL.path)")
            return HTTPResponse(status: .forbidden).data
        }

        var isDir: ObjCBool = false

        // If the file doesn't exist and it's a directory, try appending the default index file
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
            fileURL.appendPathComponent(config.defaultIndex)
            logger.debug("Directory requested, using default index file: \(fileURL.path)")
        }

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modDate = attributes[.modificationDate] as? Date else {
            logger.error("File not found or unable to read: \(fileURL.path)")
            return HTTPResponse(status: .notFound).data
        }

        logger.debug("File found: \(fileURL.path), size: \(data.count) bytes, last modified: \(modDate)")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "E, dd MMM yyyy HH:mm:ss z"
        let lastModified = formatter.string(from: modDate)
        let etag = generateETag(for: data, modDate: modDate)

        // Handle If-None-Match header
        if let ifNoneMatch = request.header(named: "If-None-Match") {
            // Remove quotes and W/ prefix if present
            let cleanIfNoneMatch = ifNoneMatch.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let cleanETag = etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            if cleanIfNoneMatch == cleanETag {
                return HTTPResponse(
                    status: .notModified,
                    headers: [
                        "Last-Modified": lastModified,
                        "ETag": etag
                    ]
                ).data
            }
        }

        // Handle If-Modified-Since header
        if let ifModifiedSince = request.header(named: "If-Modified-Since"),
           let sinceDate = formatter.date(from: ifModifiedSince),
           modDate <= sinceDate {
            return HTTPResponse(
                status: .notModified,
                headers: [
                    "Last-Modified": lastModified
                ]
            ).data
        }

        let extraHeaders: [String : String]
        if config.caching.enabled {
            extraHeaders = [
                "Last-Modified": lastModified,
                "ETag": etag,
                "Cache-Control": "public, max-age=\(config.caching.maxAge)"
            ]
        } else {
            extraHeaders = [
                "Last-Modified": lastModified,
                "ETag": etag
            ]
        }

        return HTTPResponse(
            status: .ok,
            headers: extraHeaders.merging([
                "Content-Type": mimeType(for: fileURL)
            ]) { current, _ in current },
            body: data
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

    private func generateETag(for data: Data, modDate: Date) -> String {
        // Create a hash of the file content and modification date
        var hasher = SHA256()

        // Add file content to hash
        hasher.update(data: data)

        // Add modification date to hash
        let dateData = withUnsafeBytes(of: modDate.timeIntervalSince1970) { Data($0) }
        hasher.update(data: dateData)

        // Get the final hash
        let hash = hasher.finalize()

        // Convert to hex string
        let hexString = hash.map { String(format: "%02x", $0) }.joined()

        // Return a weak ETag (W/) to indicate it's not byte-for-byte identical
        return "W/\"\(hexString)\""
    }

    public static func installSignalHandlers(server: HTTPServer) {
        let signals = [SIGINT, SIGTERM]

        for sig in signals {
            signal(sig, SIG_IGN) // Ignore default handler

            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Task {
                    await server.stop()
                    exit(EXIT_SUCCESS)
                }
            }
            source.resume()
        }
    }

    private func interrupt() async {
        await exitHandler.interrupt()
    }

    private func terminate() async {
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
