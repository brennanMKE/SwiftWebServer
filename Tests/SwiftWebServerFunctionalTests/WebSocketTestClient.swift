import Foundation
import Network
import SwiftWebServerCore

public enum WebSocketError: Error {
    case connectionFailed
    case connectionClosed
    case notConnected
    case invalidData
    case invalidFrame
    case invalidPayload
}

public struct WebSocketFrame {
    let fin: Bool
    let rsv1: Bool
    let rsv2: Bool
    let rsv3: Bool
    let opcode: OpCode
    let masked: Bool
    let payload: Data
    
    enum OpCode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }
    
    init(
        fin: Bool = true,
        rsv1: Bool = false,
        rsv2: Bool = false,
        rsv3: Bool = false,
        opcode: OpCode,
        masked: Bool = false,
        payload: Data = Data()
    ) {
        self.fin = fin
        self.rsv1 = rsv1
        self.rsv2 = rsv2
        self.rsv3 = rsv3
        self.opcode = opcode
        self.masked = masked
        self.payload = payload
    }
    
    func toData() -> Data {
        var data = Data()
        
        // First byte: FIN, RSV1-3, OpCode
        var byte: UInt8 = 0
        if fin { byte |= 0x80 }
        if rsv1 { byte |= 0x40 }
        if rsv2 { byte |= 0x20 }
        if rsv3 { byte |= 0x10 }
        byte |= opcode.rawValue
        data.append(byte)
        
        // Second byte: Mask, Payload length
        byte = masked ? 0x80 : 0x00
        let payloadLength = UInt64(payload.count)
        
        if payloadLength <= 125 {
            byte |= UInt8(payloadLength)
            data.append(byte)
        } else if payloadLength <= UInt64(UInt16.max) {
            byte |= 126
            data.append(byte)
            data.append(UInt8(payloadLength >> 8 & 0xFF))
            data.append(UInt8(payloadLength & 0xFF))
        } else {
            byte |= 127
            data.append(byte)
            for i in stride(from: 7, through: 0, by: -1) {
                data.append(UInt8((payloadLength >> (i * 8)) & 0xFF))
            }
        }
        
        // Add payload
        data.append(payload)
        return data
    }
    
    static func parse(from data: Data) throws -> WebSocketFrame {
        guard data.count >= 2 else {
            throw WebSocketError.invalidFrame
        }
        
        // Parse first byte
        let firstByte = data[0]
        let fin = (firstByte & 0x80) != 0
        let rsv1 = (firstByte & 0x40) != 0
        let rsv2 = (firstByte & 0x20) != 0
        let rsv3 = (firstByte & 0x10) != 0
        guard let opcode = OpCode(rawValue: firstByte & 0x0F) else {
            throw WebSocketError.invalidFrame
        }
        
        // Parse second byte
        let secondByte = data[1]
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
                length = length << 8 | UInt64(data[offset + i])
            }
            guard length <= Int.max else { throw WebSocketError.invalidFrame }
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

public actor WebSocketTestClient {
    private var connection: NWConnection?
    private let url: URL
    private var isConnected = false
    
    public init(url: URL) {
        self.url = url
    }
    
    public func connect() async throws {
        let endpoint = NWEndpoint.url(url)
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                
                Task {
                    switch state {
                    case .ready:
                        await self.setConnected(true)
                        continuation.resume()
                    case .failed(let error):
                        continuation.resume(throwing: error)
                    case .cancelled:
                        continuation.resume(throwing: WebSocketError.connectionClosed)
                    default:
                        break
                    }
                }
            }
            
            connection.start(queue: .main)
        }
    }
    
    private func setConnected(_ value: Bool) {
        isConnected = value
    }
    
    public func send(text: String) async throws {
        guard let data = text.data(using: .utf8) else {
            throw WebSocketError.invalidData
        }
        
        let frame = WebSocketFrame(
            fin: true,
            rsv1: false,
            rsv2: false,
            rsv3: false,
            opcode: .text,
            masked: true,
            payload: data
        )
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let connection = connection else {
                continuation.resume(throwing: WebSocketError.notConnected)
                return
            }
            
            connection.send(content: frame.toData(), completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    public func receive() async throws -> Data {
        guard let connection = connection else {
            throw WebSocketError.notConnected
        }
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                if let content = content {
                    do {
                        let frame = try WebSocketFrame.parse(from: content)
                        continuation.resume(returning: frame.payload)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else if isComplete {
                    continuation.resume(throwing: WebSocketError.connectionClosed)
                }
            }
        }
    }
    
    public func close() async throws {
        guard let connection = connection else {
            throw WebSocketError.notConnected
        }
        
        let frame = WebSocketFrame(
            fin: true,
            rsv1: false,
            rsv2: false,
            rsv3: false,
            opcode: .close,
            masked: true,
            payload: Data()
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
        
        connection.cancel()
        self.connection = nil
        setConnected(false)
    }
} 