import Foundation

@main
struct WebSocketTests {
    static func main() async {
        let url = URL(string: "ws://127.0.0.1:9001/ws")!
        let client = WebSocketTestClient(url: url)
        
        do {
            print("Connecting to test suite...")
            try await client.connect()
            print("Connected successfully!")
            
            // Send a test message
            print("Sending test message...")
            try await client.send("Hello, Autobahn Test Suite!")
            
            // Receive response
            print("Waiting for response...")
            let response = try await client.receive()
            print("Received: \(response)")
            
            // Close connection
            print("Closing connection...")
            await client.close()
            print("Connection closed.")
            
        } catch {
            print("Error: \(error)")
        }
    }
} 