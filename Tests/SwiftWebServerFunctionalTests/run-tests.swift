import Foundation
import SwiftWebServerCore

@main
struct WebSocketTests {
    static func main() async throws {
        let client = WebSocketTestClient(url: URL(string: "ws://localhost:9000/test")!)
        
        do {
            try await client.connect()
            print("Connected to WebSocket server")
            
            try await client.send(text: "Hello, WebSocket!")
            print("Sent test message")
            
            let response = try await client.receive()
            if let text = String(data: response, encoding: .utf8) {
                print("Received response: \(text)")
            }
            
            try await client.close()
            print("Connection closed")
        } catch {
            print("Error: \(error)")
            throw error
        }
    }
} 