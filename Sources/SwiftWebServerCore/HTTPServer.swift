import Foundation
import Network
import CryptoKit
import Dispatch
import os.log

public struct RuntimeConfiguration: Sendable {
    public let rootURL: URL
    public let publicURL: URL
    public let config: HTTPConfig
    public let port: NWEndpoint.Port
    public let listener: NWListener

    func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        for type in config.mimeTypes {
            if type.pathExtensions.contains(ext) {
                return type.contentType
            }
        }
        return config.defaultMimeType
    }

}

private enum HTTPRuntimeState: Sendable {
    case none
    case runtimeConfig(RuntimeConfiguration)
    case failed(Error)

    var runtimeConfig: RuntimeConfiguration? {
        switch self {
        case .runtimeConfig(let runtimeConfig):
            runtimeConfig
        default: nil
        }
    }

    var failure: Error? {
        switch self {
        case .failed(let error):
            error
        default:
            nil
        }
    }
}

actor HTTPRuntime {
    enum Failure: Error {
        case invalidState
        case configNotFound
        case notBootstrapped
    }
    private var state: HTTPRuntimeState = .none

    var config: RuntimeConfiguration {
        get throws {
            if let error = state.failure {
                throw error
            }

            guard let runtimeConfig = state.runtimeConfig else {
                logger.error("Not bootstrapped yet. Must run bootstrap first.")
                throw Failure.notBootstrapped
            }

            return runtimeConfig
        }
    }

    var error: Error? {
        state.failure
    }

    func bootstrap(at rootURL: URL) throws -> RuntimeConfiguration {
        guard case .none = state else {
            throw Failure.invalidState
        }

        let configURL = rootURL.appendingPathComponent("http-config.json")
        guard FileManager.default.fileExists(atPath: configURL.path()) else {
            logger.error("http-config.json not found at \(configURL.path(), privacy: .public)")
            throw Failure.configNotFound
        }
        let config = try HTTPConfig.init(configURL: configURL)
        let port = NWEndpoint.Port(rawValue: UInt16(config.port))!
        let publicURL = URL(fileURLWithPath: config.path, relativeTo: rootURL).standardizedFileURL
        let listener = try NWListener(using: .tcp, on: port)
        let runtimeConfig = RuntimeConfiguration(rootURL: rootURL, publicURL: publicURL, config: config, port: port, listener: listener)

        logger.log("Listening on port http://localhost:\(config.port)/")

        state = .runtimeConfig(runtimeConfig)

        return runtimeConfig
    }
}

public final class HTTPServer: Sendable {
    enum Failure: Error {
        case notBootstrapped
    }
    private let runtime: HTTPRuntime
    private let connectionsStream: AsyncStream<NWConnection>
    private let connectionsContinuation: AsyncStream<NWConnection>.Continuation

    let exitHandler = ExitHandler()

    public static let `default` = HTTPServer()

    private init() {
        runtime = HTTPRuntime()
        (connectionsStream, connectionsContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public func bootstrap() async throws -> RuntimeConfiguration {
        let rootPath = ProcessInfo.processInfo.environment["ROOT_PATH"] ?? FileManager.default.currentDirectoryPath
        let rootURL = URL(fileURLWithPath: rootPath)

        let runtimeConfig = try await runtime.bootstrap(at: rootURL)
        try await monitor(listener: runtimeConfig.listener, port: runtimeConfig.port)
        await installSignalHandlers()

        return runtimeConfig
    }

    public func start() async throws {
        let runtimeConfig = try await runtime.config

        logger.log("Listening on port \(runtimeConfig.port.rawValue)")

        runtimeConfig.listener.newConnectionHandler = { connection in
            // queue the connection for processing
            self.connectionsContinuation.yield(connection)
        }

        // process connection queue
        processConnections()

        logger.debug("Starting listener on port \(runtimeConfig.port.rawValue)")
        runtimeConfig.listener.start(queue: .global())
        try await exitHandler.wait()
        logger.debug("Listener shutting down")
        runtimeConfig.listener.cancel()
    }

    public func stop() async {
        await exitHandler.cancel()
    }

    // MARK: - Private -

    private func monitor(listener: NWListener, port: NWEndpoint.Port) async throws {
        listener.stateUpdateHandler = { newState in
            switch newState {
            case .failed(let error):
                logger.error("Listener failed: \(error.localizedDescription)")
                Task {
                    await self.terminate()
                }
            case .ready:
                logger.info("Listener is ready on port \(port.rawValue)")
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

    private func installSignalHandlers() async {
        let signals = [SIGINT, SIGTERM]

        for sig in signals {
            signal(sig, SIG_IGN) // Ignore default handler

            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Task { [weak self] in
                    guard let self else { return }
                    await self.stop()
                    exit(EXIT_SUCCESS)
                }
            }
            source.resume()
        }
    }

    private func processConnections() {
        Task {
            for await connection in connectionsStream {
                logger.debug("New connection accepted from \(String(describing: connection.endpoint))")
                connection.start(queue: .global())
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

                        // Attempt to parse completed buffer
                        guard let request = HTTPRequest.parse(from: buffer) else {
                            logger.error("Failed to parse request from buffer of size \(buffer.count)")
                            let response = HTTPResponse(status: .badRequest)
                            connection.send(content: response.data, completion: .contentProcessed { _ in
                                logger.debug("Connection closed after bad request")
                                connection.cancel()
                            })
                            return
                        }

                        logger.debug("Received request: \(request.method) \(request.path) with headers: \(request.headers)")

                        // Handle regular HTTP request
                        logger.debug("Processing regular HTTP request for path: \(request.path)")
                        let response = try await self.respond(to: request)
                        logger.debug("Sending response for \(request.path) with status: \(response.status.statusText) and headers: \(response.headers)")
                        connection.send(content: response.data, completion: .contentProcessed { _ in
                            logger.debug("Connection closed after response")
                            connection.cancel()
                        })
                    }

                    logger.debug("Connection handling completed for \(String(describing: connection.endpoint))")
                }
            }
        }
    }

    private func respond(to request: HTTPRequest) async throws -> HTTPResponse {
        let runtimeConfig = try await runtime.config

        logger.debug("Responding to request: \(request.method) \(request.path)")

        guard request.isSupportedMethod else {
            logger.error("Unsupported method: \(request.method)")
            return HTTPResponse(status: .methodNotAllowed)
        }

        if runtimeConfig.config.blockList.contains(request.path) {
            logger.error("Blocked path: \(request.path)")
            return HTTPResponse(status: .forbidden)
        }

        let relativePath = request.path.removingPercentEncoding ?? request.path
        var fileURL = runtimeConfig.publicURL.appending(path: relativePath).standardizedFileURL

        logger.debug("Mapped path \(request.path) to file URL: \(fileURL.path)")

        guard fileURL.path.hasPrefix(runtimeConfig.publicURL.path) else {
            logger.error("Path traversal attempt detected: \(fileURL.path)")
            return HTTPResponse(status: .forbidden)
        }

        var isDir: ObjCBool = false

        // If the file doesn't exist and it's a directory, try appending the default index file
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
            fileURL.appendPathComponent(runtimeConfig.config.defaultIndex)
            logger.debug("Directory requested, using default index file: \(fileURL.path)")
        }

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modDate = attributes[.modificationDate] as? Date else {
            logger.error("File not found or unable to read: \(fileURL.path)")
            return HTTPResponse(status: .notFound)
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
                )
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
            )
        }

        let extraHeaders: [String : String]
        if runtimeConfig.config.caching.enabled {
            extraHeaders = [
                "Last-Modified": lastModified,
                "ETag": etag,
                "Cache-Control": "public, max-age=\(runtimeConfig.config.caching.maxAge)"
            ]
        } else {
            extraHeaders = [
                "Last-Modified": lastModified,
                "ETag": etag
            ]
        }

        logger.debug("Response headers for \(request.path): \(extraHeaders)")

        return HTTPResponse(
            status: .ok,
            headers: extraHeaders.merging([
                "Content-Type": runtimeConfig.mimeType(for: fileURL)
            ]) { current, _ in current },
            body: data
        )
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

    private func interrupt() async {
        await exitHandler.interrupt()
    }

    private func terminate() async {
        await exitHandler.terminate()
    }
}

struct ConnectionStream {
    enum StreamOutput {
        case data(Data)
        case error(Error)
    }

    let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    var values: AsyncStream<StreamOutput> {
        let stream: AsyncStream<StreamOutput>
        let continuation: AsyncStream<StreamOutput>.Continuation
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)

        Task {
            var isComplete = false
            while !isComplete {
                isComplete = await next(continuation: continuation)
            }
            continuation.finish()
        }

        return stream
    }

    func next(continuation: AsyncStream<StreamOutput>.Continuation) async -> Bool {
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
