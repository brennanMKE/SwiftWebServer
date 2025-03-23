import Foundation
import Network

enum HTTPServerError: Error {
    case configNotFound
}

actor ExitHandler {
    var continuation: CheckedContinuation<Void, any Error>?

    init() {}

    func wait() async throws {
        try await withCheckedThrowingContinuation {
            self.continuation = $0
        }
    }

    func terminate(error: Error?) {
        logger.info(#function)
        guard let continuation else { return }
        if let error {
            logger.info("Terminating with error: \(error)")
            continuation.resume(throwing: error)
        } else {
            logger.info("Terminating")
            continuation.resume()
        }
    }
}

final class HTTPServer: Sendable {
    let port: NWEndpoint.Port
    let publicDirectory: URL
    private let config: HTTPConfig
    private let listener: NWListener

    let exitHandler = ExitHandler()

    init(port: Int, publicDirectory: String) throws {
        let rootPath = ProcessInfo.processInfo.environment["ROOT_PATH"] ?? FileManager.default.currentDirectoryPath
        logger.info("rootPath: \(rootPath)")
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).appending(path: publicDirectory)
        self.config = try HTTPServer.loadConfig(at: rootURL)

        self.port = NWEndpoint.Port(rawValue: UInt16(port))!
        self.publicDirectory = rootURL
        self.listener = try NWListener(using: .tcp, on: self.port)
        logger.info("Listening on port http://localhost:\(port)/")
    }

    private static func loadConfig(at rootURL: URL) throws -> HTTPConfig {
        let configURL = rootURL.appendingPathComponent("http.config")
        guard FileManager.default.fileExists(atPath: configURL.path()) else {
            logger.error("http.config not found at \(configURL.absoluteString)")
            throw HTTPServerError.configNotFound
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(HTTPConfig.self, from: data)
    }

    func run() async throws {
        logger.info("Listening on port \(self.port.rawValue)")

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
            var sentError = false
            for await value in connection.values {
                switch value {
                case .data(let data):
                    buffer.append(data)
                case .error(let error):
                    logger.info("Receive error: \(error)")
                    let response = HTTPResponse(status: .internalServerError)
                    connection.send(content: response.data, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    sentError = true
                    break
                }
            }

            guard !sentError else { return }
            // handle data?

            guard let request = HTTPRequest.parse(from: buffer) else {
                logger.info("Bad Request")
                let response = HTTPResponse(status: .badRequest)
                connection.send(content: response.data, completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }

            logger.info("OK - \(request.method) \(request.path)")
            let response = await self.respond(to: request)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func respond(to request: HTTPRequest) async -> Data {
        guard request.method == "GET" else {
            return HTTPResponse(status: .methodNotAllowed).data
        }

        let relativePath = request.path.removingPercentEncoding ?? request.path
        let fileURL = publicDirectory.appendingPathComponent(relativePath).standardizedFileURL

        guard fileURL.path.hasPrefix(publicDirectory.path) else {
            return HTTPResponse(status: .forbidden).data
        }

        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL) {
            return HTTPResponse(status: .ok, body: data, contentType: mimeType(for: fileURL)).data
        } else {
            return HTTPResponse(status: .notFound).data
        }
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

    func interrupt() {
        Task {
            await exitHandler.terminate(error: nil)
        }
    }

    func terminate() {
        Task {
            await exitHandler.terminate(error: nil)
        }
    }
}

enum StreamValue {
    case data(Data)
    case error(Error)
}

extension NWConnection {
    var values: AsyncStream<StreamValue> {
        let stream: AsyncStream<StreamValue>
        let continuation: AsyncStream<StreamValue>.Continuation
        (stream, continuation) = AsyncStream.makeStream(of: StreamValue.self, bufferingPolicy: .unbounded)

        Task {
            var isComplete = false
            while !isComplete {
                isComplete = await next(continuation: continuation)
            }
        }

        return stream
    }

    func next(continuation: AsyncStream<StreamValue>.Continuation) async -> Bool {
        await withCheckedContinuation { checkedContinuation in
            receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
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
