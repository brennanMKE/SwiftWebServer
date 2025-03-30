import Foundation
import Network

public actor WebSocketConnection {
    private let connection: NWConnection
    private var isOpen = true
    
    public init(connection: NWConnection) {
        self.connection = connection
    }
    
    public func start() {
        receiveNextFrame()
    }
    
    private func receiveNextFrame() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("WebSocket receive error: \(error)")
                Task { await self.close() }
                return
            }
            
            if isComplete {
                Task { await self.close() }
                return
            }
            
            if let data = data {
                Task {
                    do {
                        let frame = try WebSocketFrame.parse(from: data)
                        await self.handleFrame(frame)
                    } catch {
                        print("Failed to parse WebSocket frame: \(error)")
                        await self.close()
                    }
                }
            }
            
            Task {
                if await self.isOpen {
                    await self.receiveNextFrame()
                }
            }
        }
    }
    
    private func handleFrame(_ frame: WebSocketFrame) async {
        switch frame.opcode {
        case .text:
            if let text = String(data: frame.payload, encoding: .utf8) {
                print("Received text: \(text)")
                // Echo the message back
                await send(text: text)
            }
        case .binary:
            print("Received binary data: \(frame.payload.count) bytes")
            // Echo the binary data back
            await send(binary: frame.payload)
        case .close:
            print("Received close frame")
            await close()
        case .ping:
            print("Received ping")
            await sendPong()
        case .pong:
            print("Received pong")
        case .continuation:
            print("Received continuation frame")
        }
    }
    
    public func send(text: String) async {
        guard let data = text.data(using: .utf8) else { return }
        await send(binary: data)
    }
    
    public func send(binary: Data) async {
        let frame = WebSocketFrame(opcode: .text, payload: binary)
        let data = frame.toData()
        
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("WebSocket send error: \(error)")
                Task { await self?.close() }
            }
        })
    }
    
    private func sendPong() async {
        let frame = WebSocketFrame(opcode: .pong)
        let data = frame.toData()
        
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("WebSocket send error: \(error)")
                Task { await self?.close() }
            }
        })
    }
    
    public func close() async {
        guard isOpen else { return }
        isOpen = false
        
        let frame = WebSocketFrame(opcode: .close)
        let data = frame.toData()
        
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("WebSocket close error: \(error)")
            }
            self?.connection.cancel()
        })
    }
} 