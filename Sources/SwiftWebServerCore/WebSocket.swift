import Foundation
import CryptoKit

public enum WebSocketError: Error {
    case invalidUpgradeRequest
    case invalidKey
    case invalidProtocol
}

public struct WebSocketFrame {
    public enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }
    
    public let fin: Bool
    public let rsv1: Bool
    public let rsv2: Bool
    public let rsv3: Bool
    public let opcode: Opcode
    public let masked: Bool
    public let payload: Data
    
    public init(fin: Bool = true, rsv1: Bool = false, rsv2: Bool = false, rsv3: Bool = false,
                opcode: Opcode, masked: Bool = false, payload: Data = Data()) {
        self.fin = fin
        self.rsv1 = rsv1
        self.rsv2 = rsv2
        self.rsv3 = rsv3
        self.opcode = opcode
        self.masked = masked
        self.payload = payload
    }
    
    public func toData() -> Data {
        var data = Data()
        
        // First byte: FIN + RSV1-3 + opcode
        var firstByte: UInt8 = 0
        if fin { firstByte |= 0x80 }
        if rsv1 { firstByte |= 0x40 }
        if rsv2 { firstByte |= 0x20 }
        if rsv3 { firstByte |= 0x10 }
        firstByte |= opcode.rawValue
        data.append(firstByte)
        
        // Second byte: MASK + payload length
        var secondByte: UInt8 = 0
        if masked { secondByte |= 0x80 }
        
        let payloadLength = payload.count
        if payloadLength <= 125 {
            secondByte |= UInt8(payloadLength)
            data.append(secondByte)
        } else if payloadLength <= 65535 {
            secondByte |= 126
            data.append(secondByte)
            data.append(UInt8((payloadLength >> 8) & 0xFF))
            data.append(UInt8(payloadLength & 0xFF))
        } else {
            secondByte |= 127
            data.append(secondByte)
            for i in (0..<8).reversed() {
                data.append(UInt8((payloadLength >> (i * 8)) & 0xFF))
            }
        }
        
        // Masking key if masked
        if masked {
            let maskingKey = (0..<4).map { _ in UInt8.random(in: 0...255) }
            data.append(contentsOf: maskingKey)
            
            // Mask payload
            var maskedPayload = Data()
            for (index, byte) in payload.enumerated() {
                maskedPayload.append(byte ^ maskingKey[index % 4])
            }
            data.append(maskedPayload)
        } else {
            data.append(payload)
        }
        
        return data
    }
    
    public static func parse(from data: Data) throws -> WebSocketFrame {
        guard data.count >= 2 else {
            throw WebSocketError.invalidUpgradeRequest
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
            guard data.count >= 4 else { throw WebSocketError.invalidUpgradeRequest }
            payloadLength = Int(data[2]) << 8 | Int(data[3])
            offset += 2
        } else if payloadLength == 127 {
            guard data.count >= 10 else { throw WebSocketError.invalidUpgradeRequest }
            payloadLength = 0
            for i in 0..<8 {
                payloadLength = payloadLength << 8 | Int(data[2 + i])
            }
            offset += 8
        }
        
        // Handle masking key
        var maskingKey: [UInt8]?
        if masked {
            guard data.count >= offset + 4 else { throw WebSocketError.invalidUpgradeRequest }
            maskingKey = Array(data[offset..<offset + 4])
            offset += 4
        }
        
        // Handle payload
        guard data.count >= offset + payloadLength else { throw WebSocketError.invalidUpgradeRequest }
        var payload = data[offset..<offset + payloadLength]
        
        // Unmask payload if masked
        if let maskingKey = maskingKey {
            payload = Data(payload.enumerated().map { index, byte in
                byte ^ maskingKey[index % 4]
            })
        }
        
        return WebSocketFrame(fin: fin, rsv1: rsv1, rsv2: rsv2, rsv3: rsv3,
                            opcode: opcode, masked: masked, payload: payload)
    }
}

public struct WebSocketUpgrade {
    private static let magicString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    
    public static func generateAcceptKey(_ key: String) -> String {
        let combined = key + magicString
        let sha1 = Insecure.SHA1.hash(data: combined.data(using: .utf8)!)
        return Data(sha1).base64EncodedString()
    }
    
    public static func validateUpgradeRequest(_ request: HTTPRequest) -> Bool {
        guard request.isWebSocketUpgrade,
              request.header(named: "Sec-WebSocket-Key") != nil,
              let version = request.header(named: "Sec-WebSocket-Version"),
              version == "13" else {
            return false
        }
        return true
    }
    
    public static func createUpgradeResponse(_ request: HTTPRequest) -> HTTPResponse {
        guard let key = request.header(named: "Sec-WebSocket-Key") else {
            return HTTPResponse(status: .badRequest)
        }
        
        let acceptKey = generateAcceptKey(key)
        let headers = [
            "Upgrade": "websocket",
            "Connection": "Upgrade",
            "Sec-WebSocket-Accept": acceptKey,
            "Sec-WebSocket-Version": "13"
        ]
        
        return HTTPResponse(status: .switchingProtocols, headers: headers)
    }
} 