import Foundation
import Network
import os.log

let logger = Logger(subsystem: "HTTPServer", category: "HTTPServer")

let server: HTTPServer

do {
    server = try HTTPServer(port: 8080, publicDirectory: "Public")
    Task {
        try await server.run()
        logger.info("Shutting down HTTP server")
        exit(EXIT_SUCCESS)
    }
} catch {
    logger.error("Error: \(error)")
    exit(EXIT_FAILURE)
}

signal(SIGINT) { _ in
    logger.info("interrupt")
    server.interrupt()
}

signal(SIGTERM) { _ in
    logger.info("terminate")
    server.terminate()
}

// Keep the process alive
dispatchMain()

