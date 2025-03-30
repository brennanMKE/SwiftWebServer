import Foundation
import Network

enum WebSocketError: Error {
    case connectionFailed
    case connectionClosed
    case invalidPayload
    case invalidFrame
}

struct WebSocketFrame {
    let fin: Bool
    let rsv1: Bool
    let rsv2: Bool
    let rsv3: Bool
    let opcode: Opcode
    let masked: Bool
    let payload: Data
    
    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }
    
    func toData() -> Data {
        var data = Data()
        
        // First byte: FIN + RSV1-3 + opcode
        var firstByte: UInt8 = 0
        if fin { firstByte |= 0x80 }
        if rsv1 { firstByte |= 0x40 }
        if rsv2 { firstByte |= 0x20 }
        if rsv3 { firstByte |= 0x10 }
        firstByte |= opcode.rawValue
        data.append(firstByte)
        
        // Second byte: Mask + payload length
        var secondByte: UInt8 = 0
        if masked { secondByte |= 0x80 }
        
        if payload.count <= 125 {
            secondByte |= UInt8(payload.count)
        } else if payload.count <= 65535 {
            secondByte |= 126
            data.append(UInt8((payload.count >> 8) & 0xFF))
            data.append(UInt8(payload.count & 0xFF))
        } else {
            secondByte |= 127
            for i in (0..<8).reversed() {
                data.append(UInt8((payload.count >> (i * 8)) & 0xFF))
            }
        }
        
        data.append(secondByte)
        
        // Masking key if masked
        if masked {
            let mask = [UInt8](repeating: 0, count: 4)
            data.append(contentsOf: mask)
        }
        
        // Payload
        data.append(contentsOf: payload)
        
        return data
    }
    
    static func parse(from data: Data) throws -> WebSocketFrame {
        guard data.count >= 2 else {
            throw WebSocketError.invalidFrame
        }
        
        let firstByte = data[0]
        let secondByte = data[1]
        
        let fin = (firstByte & 0x80) != 0
        let rsv1 = (firstByte & 0x40) != 0
        let rsv2 = (firstByte & 0x20) != 0
        let rsv3 = (firstByte & 0x10) != 0
        let opcode = Opcode(rawValue: firstByte & 0x0F) ?? .continuation
        
        let masked = (secondByte & 0x80) != 0
        var payloadLength = Int(secondByte & 0x7F)
        
        var offset = 2
        
        // Handle extended payload length
        if payloadLength == 126 {
            guard data.count >= 4 else { throw WebSocketError.invalidFrame }
            payloadLength = Int(data[2]) << 8 | Int(data[3])
            offset += 2
        } else if payloadLength == 127 {
            guard data.count >= 10 else { throw WebSocketError.invalidFrame }
            var length: UInt64 = 0
            for i in 0..<8 {
                length |= UInt64(data[2 + i]) << ((7 - i) * 8)
            }
            payloadLength = Int(length)
            offset += 8
        }
        
        // Handle masking key
        if masked {
            guard data.count >= offset + 4 else { throw WebSocketError.invalidFrame }
            offset += 4
        }
        
        // Get payload
        guard data.count >= offset + payloadLength else { throw WebSocketError.invalidFrame }
        let payload = data.subdata(in: offset..<(offset + payloadLength))
        
        return WebSocketFrame(
            fin: fin,
            rsv1: rsv1,
            rsv2: rsv2,
            rsv3: rsv3,
            opcode: opcode,
            masked: masked,
            payload: payload
        )
    }
}

actor WebSocketTestClient {
    private var connection: NWConnection?
    private let url: URL
    private var isConnected = false
    
    init(url: URL) {
        self.url = url
    }
    
    func connect() async throws {
        let host = NWEndpoint.Host(url.host ?? "127.0.0.1")
        let port = NWEndpoint.Port(integerLiteral: UInt16(url.port ?? 9001))
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        let parameters = NWParameters.tcp
        
        connection = NWConnection(to: endpoint, using: parameters)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { [weak self] in
                        await self?.setConnected(true)
                        continuation.resume()
                    }
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .cancelled:
                    continuation.resume(throwing: WebSocketError.connectionClosed)
                default:
                    break
                }
            }
            
            connection?.start(queue: .global())
        }
    }
    
    private func setConnected(_ value: Bool) {
        isConnected = value
    }
    
    func send(_ text: String) async throws {
        guard let connection = connection, isConnected else {
            throw WebSocketError.connectionClosed
        }
        
        let frame = WebSocketFrame(
            fin: true,
            rsv1: false,
            rsv2: false,
            rsv3: false,
            opcode: .text,
            masked: true,
            payload: text.data(using: .utf8) ?? Data()
        )
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame.toData(), completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    func receive() async throws -> String {
        guard let connection = connection, isConnected else {
            throw WebSocketError.connectionClosed
        }
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let data = content else {
                    continuation.resume(throwing: WebSocketError.connectionClosed)
                    return
                }
                
                do {
                    let frame = try WebSocketFrame.parse(from: data)
                    if let text = String(data: frame.payload, encoding: .utf8) {
                        continuation.resume(returning: text)
                    } else {
                        continuation.resume(throwing: WebSocketError.invalidPayload)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func close() async {
        guard let connection = connection else { return }
        
        let frame = WebSocketFrame(
            fin: true,
            rsv1: false,
            rsv2: false,
            rsv3: false,
            opcode: .close,
            masked: true,
            payload: Data()
        )
        
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame.toData(), completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
        
        connection.cancel()
        isConnected = false
    }
}

// Main program
let url = URL(string: "ws://127.0.0.1:9001/ws")!
let client = WebSocketTestClient(url: url)

Task {
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

// Keep the program running
RunLoop.main.run() 