import Foundation
import Network
import os.log
import SwiftWebServerCore

// subsystem:HTTPServer
let logger = Logger(subsystem: "HTTPServer", category: "HTTPServer")

do {
    let publicDirectory: String
    if CommandLine.arguments.count > 1 {
        publicDirectory = CommandLine.arguments[1]
    } else {
        publicDirectory = "Public"
    }

    let server = try HTTPServer(publicDirectory: publicDirectory)
    HTTPServer.installSignalHandlers(server: server)
    Task {
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
