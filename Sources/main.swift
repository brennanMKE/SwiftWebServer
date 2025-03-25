import Foundation
import Network
import os.log

// subsystem:HTTPServer
let logger = Logger(subsystem: "HTTPServer", category: "HTTPServer")

do {
    let publicDirectory: String
    var isDir: ObjCBool = false

    if CommandLine.arguments.count > 1 {
        publicDirectory = CommandLine.arguments[1]
    } else if FileManager.default.fileExists(atPath: "Public", isDirectory: &isDir), isDir.boolValue {
        publicDirectory = "Public"
    } else {
        logger.error("Error: No public directory found. Pass a directory path as an argument.")
        exit(EXIT_FAILURE)
    }

    let server = try HTTPServer(publicDirectory: publicDirectory)
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
