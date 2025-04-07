import Foundation
import CryptoKit
import os.log

public enum WebSocketError: Error {
    case invalidUpgradeRequest
    case invalidKey
    case invalidProtocol
    case frameParsingError(String)
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

    // TODO: replace toData with an extension of Data which takes a WebSocketFrame with an initializer
    public func toData() -> Data {
        logger.debug("Creating WebSocket frame data: opcode=\(opcode.rawValue), masked=\(masked), payload=\(payload.count) bytes")
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
            logger.debug("Generated masking key: \(maskingKey.map { String(format: "%02x", $0) }.joined())")
            data.append(contentsOf: maskingKey)

            // Mask payload
            var maskedPayload = Data()
            for (index, byte) in payload.enumerated() {
                maskedPayload.append(byte ^ maskingKey[index % 4])
            }
            data.append(maskedPayload)
            logger.debug("Appended masked payload: \(maskedPayload.count) bytes")
        } else {
            data.append(payload)
            logger.debug("Appended unmasked payload: \(payload.count) bytes")
        }

        logger.debug("Created WebSocket frame: \(data.count) bytes total")
        return data
    }

    public static func parse(from data: Data) throws -> WebSocketFrame {
        logger.debug("Parsing WebSocket frame from \(data.count) bytes")

        // Log raw data hex for debugging
        if data.count > 0 {
            let hexString = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            logger.debug("Frame raw data: \(hexString, privacy: .public)")
        }

        guard data.count >= 2 else {
            let error = "Frame too short: \(data.count) bytes, minimum 2 required"
            logger.error("WebSocket parse error: \(error)")
            throw WebSocketError.frameParsingError(error)
        }

        let firstByte = data[0]
        let secondByte = data[1]

        let fin = (firstByte & 0x80) != 0
        let rsv1 = (firstByte & 0x40) != 0
        let rsv2 = (firstByte & 0x20) != 0
        let rsv3 = (firstByte & 0x10) != 0
        let opcodeRaw = firstByte & 0x0F

        logger.debug("Basic frame info - FIN: \(fin), RSV1: \(rsv1), RSV2: \(rsv2), RSV3: \(rsv3), opcode: \(opcodeRaw)")

        // Be more tolerant of opcodes - if we don't recognize it, treat as binary
        var opcode: Opcode
        if let knownOpcode = Opcode(rawValue: opcodeRaw) {
            opcode = knownOpcode
        } else {
            logger.warning("Unknown opcode: \(opcodeRaw, privacy: .public), treating as binary")
            opcode = .binary
        }

        logger.debug("Frame header: FIN=\(fin), RSV1=\(rsv1), RSV2=\(rsv2), RSV3=\(rsv3), opcode=\(opcode.rawValue)")

        let masked = (secondByte & 0x80) != 0
        var payloadLength = Int(secondByte & 0x7F)

        logger.debug("Frame initial payload length: \(payloadLength), masked: \(masked)")

        var offset = 2

        // Handle extended payload length
        if payloadLength == 126 {
            guard data.count >= 4 else {
                let error = "Extended payload length (16-bit) frame too short: \(data.count) bytes, minimum 4 required"
                logger.error("WebSocket parse error: \(error)")
                throw WebSocketError.frameParsingError(error)
            }
            payloadLength = Int(data[2]) << 8 | Int(data[3])
            offset += 2
            logger.debug("Extended payload length (16-bit): \(payloadLength)")
        } else if payloadLength == 127 {
            guard data.count >= 10 else {
                let error = "Extended payload length (64-bit) frame too short: \(data.count) bytes, minimum 10 required"
                logger.error("WebSocket parse error: \(error)")
                throw WebSocketError.frameParsingError(error)
            }
            payloadLength = 0
            for i in 0..<8 {
                payloadLength = payloadLength << 8 | Int(data[2 + i])
            }
            offset += 8
            logger.debug("Extended payload length (64-bit): \(payloadLength)")
        }

        // Check if the frame size is reasonable (to avoid memory issues)
        if payloadLength > 100 * 1024 * 1024 { // 100MB limit
            let error = "Payload length too large: \(payloadLength) bytes"
            logger.error("WebSocket parse error: \(error, privacy: .public)")
            throw WebSocketError.frameParsingError(error)
        }

        // Handle masking key
        var maskingKey: [UInt8]?
        if masked {
            guard data.count >= offset + 4 else {
                let error = "Masked frame too short for masking key: \(data.count) bytes, minimum \(offset + 4) required"
                logger.error("WebSocket parse error: \(error)")
                throw WebSocketError.frameParsingError(error)
            }
            maskingKey = Array(data[offset..<offset + 4])
            let keyHex = maskingKey?.map { String(format: "%02x", $0) }.joined(separator: " ") ?? "none"
            logger.debug("Masking key: \(keyHex, privacy: .public)")
            offset += 4
        } else {
            // RFC 6455 5.1: "All frames sent from client to server have this bit set to 1."
            // Make this a warning instead of an error
            logger.warning("Received unmasked frame - RFC 6455 requires client-to-server frames to be masked")
        }

        // Handle payload
        guard data.count >= offset + payloadLength else {
            let error = "Frame payload incomplete: got \(data.count - offset) bytes, expected \(payloadLength)"
            logger.error("WebSocket parse error: \(error)")
            throw WebSocketError.frameParsingError(error)
        }
        var payload = Data(data[offset..<(offset + payloadLength)])

        // Unmask payload if masked
        if let maskingKey = maskingKey {
            logger.debug("Unmasking payload with masking key")
            var unmaskedData = Data(count: payload.count)
            for i in 0..<payload.count {
                unmaskedData[i] = payload[i] ^ maskingKey[i % 4]
            }
            payload = unmaskedData

            // Log sample of unmasked data
            if payload.count > 0 {
                let sampleSize = min(payload.count, 32)
                let sample = payload.prefix(sampleSize)
                let sampleHex = sample.map { String(format: "%02x", $0) }.joined(separator: " ")
                logger.debug("Unmasked payload sample (\(sampleSize) bytes): \(sampleHex, privacy: .public)")

                // Try to convert text frames to string
                if opcode == .text, let textSample = String(data: sample, encoding: .utf8) {
                    logger.debug("Text sample: \"\(textSample, privacy: .public)\"")
                }
            }
        }

        logger.debug("Successfully parsed WebSocket frame: opcode=\(opcode.rawValue), payload=\(payload.count) bytes")

        return WebSocketFrame(fin: fin, rsv1: rsv1, rsv2: rsv2, rsv3: rsv3,
                              opcode: opcode, masked: masked, payload: payload)
    }
}

public struct WebSocketUpgrade {
    private static let magicString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    public static func generateAcceptKey(_ key: String) -> String {
        logger.debug("Generating WebSocket accept key for: \(key)")
        let combined = key + magicString
        let sha1 = Insecure.SHA1.hash(data: combined.data(using: .utf8)!)
        let acceptKey = Data(sha1).base64EncodedString()
        logger.debug("Generated accept key: \(acceptKey)")
        return acceptKey
    }

    public static func validateUpgradeRequest(_ request: HTTPRequest) -> Bool {
        logger.debug("Validating WebSocket upgrade request for path: \(request.path)")

        guard request.isWebSocketUpgrade else {
            logger.error("Request missing 'Upgrade: websocket' header")
            return false
        }

        guard let key = request.header(named: "Sec-WebSocket-Key") else {
            logger.error("Request missing 'Sec-WebSocket-Key' header")
            return false
        }
        logger.debug("Sec-WebSocket-Key: \(key)")

        guard let version = request.header(named: "Sec-WebSocket-Version") else {
            logger.error("Request missing 'Sec-WebSocket-Version' header")
            return false
        }
        logger.debug("Sec-WebSocket-Version: \(version)")

        guard version == "13" else {
            logger.error("Unsupported WebSocket version: \(version)")
            return false
        }

        logger.debug("WebSocket upgrade request validated successfully")
        return true
    }

    public static func createUpgradeResponse(_ request: HTTPRequest) -> HTTPResponse {
        logger.debug("Creating WebSocket upgrade response")

        guard let key = request.header(named: "Sec-WebSocket-Key") else {
            logger.error("Missing Sec-WebSocket-Key header in upgrade request")
            return HTTPResponse(status: .badRequest)
        }

        let acceptKey = generateAcceptKey(key)
        let headers = [
            "Upgrade": "websocket",
            "Connection": "Upgrade",
            "Sec-WebSocket-Accept": acceptKey,
            "Sec-WebSocket-Version": "13"
        ]

        logger.debug("WebSocket upgrade response headers: \(headers)")
        return HTTPResponse(status: .switchingProtocols, headers: headers)
    }
}
