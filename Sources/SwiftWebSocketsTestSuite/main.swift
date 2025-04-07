import Foundation
import os.log
import SwiftWebServerCore

// subsystem:WebSocketsTestSuite
let logger = Logger(subsystem: "WebSocketsTestSuite", category: "WebSocketsTestSuite")

// Helper to view data as hex
extension Data {
    var hexDescription: String {
        return self.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

Task {
    let client = WebSocketTestClient(url: URL(string: "ws://localhost:8080/test")!)

    do {
        try await client.connect()
        logger.log("Connected to WebSocket server")

        // Give the server a moment to prepare
        try await Task.sleep(for: .seconds(0.5))

        let message = "Hello, WebSocket!"
        logger.log("Preparing to send test message: '\(message)'")

        // Get frame data and log it with public privacy
        let frame = WebSocketFrame(
            fin: true,
            rsv1: false,
            rsv2: false,
            rsv3: false,
            opcode: .text,
            masked: true,
            payload: message.data(using: .utf8)!
        )
        let frameData = frame.toData()
        let hexString = frameData.hexDescription
        logger.log("Frame data (hex): \(hexString, privacy: .public)")

        try await client.send(text: message)
        logger.log("Sent test message")

        // Wait a bit longer to receive the response
        try await Task.sleep(for: .seconds(2))

        logger.log("Attempting to receive response...")
        let response = try await client.receive()
        if let text = String(data: response, encoding: .utf8) {
            logger.log("Received response: \(text)")
            logger.log("Response data (hex): \(response.hexDescription)")
        } else {
            logger.log("Received binary response: \(response.count) bytes")
            logger.log("Binary response (hex): \(response.hexDescription)")
        }

        try await client.close()
        logger.log("Connection closed")
        exit(EXIT_SUCCESS)
    } catch {
        logger.error("Error: \(error, privacy: .public)")
        logger.log("Detailed error: \(error)")
        exit(EXIT_FAILURE)
    }
}

// Keep the process alive
dispatchMain()
