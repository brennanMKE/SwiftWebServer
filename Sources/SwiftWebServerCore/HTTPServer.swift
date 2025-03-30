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
        let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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
            connection.start(queue: .global())
            self.handle(connection)
        }

        listener.start(queue: .global())
        try await exitHandler.wait()
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
            default:
                break
            }
        }
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
                
                // Check for WebSocket upgrade request
                if request.isWebSocketUpgrade {
                    if WebSocketUpgrade.validateUpgradeRequest(request) {
                        let response = WebSocketUpgrade.createUpgradeResponse(request)
                        connection.send(content: response.data, completion: .contentProcessed { error in
                            if let error = error {
                                logger.error("Failed to send WebSocket upgrade response: \(error)")
                                connection.cancel()
                                return
                            }
                            
                            let webSocket = WebSocketConnection(connection: connection)
                            Task {
                                await webSocket.start()
                            }
                        })
                    } else {
                        let response = HTTPResponse(status: .badRequest)
                        connection.send(content: response.data, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                    return
                }
                
                // Handle regular HTTP request
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
