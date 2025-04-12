 import Foundation
 import os.log
 import SwiftWebServerCore

 // subsystem:WebSocketsTestSuite
 let logger = Logger(subsystem: "WebSocketsTestSuite", category: "WebSocketsTestSuite")

 Task {
     do {
         logger.log("Not implemented")
         exit(EXIT_SUCCESS)
     } catch {
         logger.error("Error: \(error, privacy: .public)")
         logger.log("Detailed error: \(error)")
         exit(EXIT_FAILURE)
     }
 }

 // Keep the process alive
 dispatchMain()
