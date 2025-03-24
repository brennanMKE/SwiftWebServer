import Foundation
import Network
import os.log

// subsystem:HTTPServer
let logger = Logger(subsystem: "HTTPServer", category: "HTTPServer")

do {
    let server = try HTTPServer(publicDirectory: "Public")
    HTTPServer.installSignalHandlers(server: server)
    Task {
        try await server.run()
        logger.log("Shutting down HTTP server")
        try await Task.sleep(for: .milliseconds(250))
        exit(EXIT_SUCCESS)
    }
} catch {
    logger.error("Error: \(error)")
    exit(EXIT_FAILURE)
}

// Keep the process alive
dispatchMain()
