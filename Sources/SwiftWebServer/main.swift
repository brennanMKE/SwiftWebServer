import Foundation
import Network
import os.log
import SwiftWebServerCore

// subsystem:HTTPServer
let logger = Logger(subsystem: "HTTPServer", category: "HTTPServer")

do {
    let server = HTTPServer.default
    Task {
        try await server.bootstrap()
        try await server.start()
        logger.log("Shutting down HTTP server")
        try await Task.sleep(for: .milliseconds(250))
        exit(EXIT_SUCCESS)
    }
} catch {
    logger.error("Error: \(error, privacy: .public)")
    exit(EXIT_FAILURE)
}

// Keep the process alive
dispatchMain()
