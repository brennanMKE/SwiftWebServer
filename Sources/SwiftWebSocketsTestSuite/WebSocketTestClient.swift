import Foundation
import Network
import SwiftWebServerCore
import os.log

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

        // Generate and apply masking key if needed
        if masked {
            // Generate random masking key
            let maskingKey = [UInt8.random(in: 0...255),
                              UInt8.random(in: 0...255),
                              UInt8.random(in: 0...255),
                              UInt8.random(in: 0...255)]

            let maskingKeyHex = maskingKey.map { String(format: "%02x", $0) }.joined(separator: " ")
            logger.debug("Using masking key: \(maskingKeyHex, privacy: .public)")

            data.append(contentsOf: maskingKey)

            // Mask the payload data - create a new mutable data
            var maskedPayload = Data(count: payload.count)
            for i in 0..<payload.count {
                maskedPayload[i] = payload[i] ^ maskingKey[i % 4]
            }

            // Verify the first few bytes were masked correctly
            let original = payload.prefix(min(8, payload.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
            let masked = maskedPayload.prefix(min(8, maskedPayload.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
            logger.debug("Original: \(original, privacy: .public)")
            logger.debug("Masked:   \(masked, privacy: .public)")

            data.append(maskedPayload)
        } else {
            data.append(payload)
        }

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

extension NWConnection.State {
    var summary: String {
        switch self {
        case .setup:
            "Setup"
        case .waiting(let error):
            "Waiting: \(error)"
        case .preparing:
            "Preparing"
        case .ready:
            "Ready"
        case .failed(let error):
            "Failed: \(error)"
        case .cancelled:
            "Cancelled"
        default:
            "Unknown"
        }
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

        // Create an async sequence of connection states
        let states = AsyncStream<NWConnection.State> { continuation in
            connection.stateUpdateHandler = { state in
                logger.debug("Connection state changed: \(state.summary, privacy: .public)")
                continuation.yield(state)

                // End the stream when we reach a terminal state
                switch state {
                case .ready, .failed, .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }

        // Wait for a terminal state
        for await state in states {
            switch state {
            case .ready:
                logger.debug("Connection is ready")
                setConnected(true)

                // Send WebSocket upgrade request
                try await sendWebSocketUpgradeRequest()
                return
            case .failed(let error):
                logger.error("Connection failed: \(error, privacy: .public)")
                throw error
            case .cancelled:
                logger.debug("Connection cancelled")
                throw WebSocketError.connectionClosed
            default:
                continue
            }
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

        let frameData = frame.toData()
        logger.debug("Sending message: \(text, privacy: .public)")
        logger.debug("Frame data size: \(frameData.count) bytes")
        let hexString = frameData.map { String(format: "%02x", $0) }.joined(separator: " ")
        logger.debug("Frame data (hex): \(hexString, privacy: .public)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let connection = connection else {
                continuation.resume(throwing: WebSocketError.notConnected)
                return
            }

            connection.send(content: frameData, completion: .contentProcessed { error in
                if let error = error {
                    logger.error("Error sending message: \(error, privacy: .public)")
                    continuation.resume(throwing: error)
                } else {
                    logger.debug("Message sent successfully")
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
                    logger.error("Error receiving message: \(error, privacy: .public)")
                    continuation.resume(throwing: error)
                    return
                }

                if let content = content {
                    logger.debug("Received raw data: \(content.count) bytes")
                    let rawHex = content.map { String(format: "%02x", $0) }.joined(separator: " ")
                    logger.debug("Raw data (hex): \(rawHex, privacy: .public)")

                    do {
                        let frame = try WebSocketFrame.parse(from: content)
                        logger.debug("Parsed WebSocket frame: opcode=\(frame.opcode.rawValue), payload=\(frame.payload.count) bytes")

                        if frame.opcode == .text {
                            if let text = String(data: frame.payload, encoding: .utf8) {
                                logger.debug("Received message: \(text, privacy: .public)")
                            } else {
                                logger.debug("Received invalid UTF-8 text data")
                            }
                        } else {
                            logger.debug("Received binary data: \(frame.payload.count) bytes")
                            let payloadHex = frame.payload.map { String(format: "%02x", $0) }.joined(separator: " ")
                            logger.debug("Binary payload (hex): \(payloadHex, privacy: .public)")
                        }
                        continuation.resume(returning: frame.payload)
                    } catch {
                        logger.error("Error parsing received message: \(error, privacy: .public)")
                        logger.error("Error details: \(String(describing: error), privacy: .public)")
                        continuation.resume(throwing: error)
                    }
                } else if isComplete {
                    logger.debug("Connection closed by peer")
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

        logger.debug("Closing connection")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame.toData(), completion: .contentProcessed { error in
                if let error = error {
                    logger.error("Error closing connection: \(error, privacy: .public)")
                    continuation.resume(throwing: error)
                } else {
                    logger.debug("Connection closed successfully")
                    continuation.resume()
                }
            })
        }

        connection.cancel()
        self.connection = nil
        setConnected(false)
    }

    private func sendWebSocketUpgradeRequest() async throws {
        logger.debug("Sending WebSocket upgrade request")

        // Generate a random key for the handshake
        let wsKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        logger.debug("WebSocket key: \(wsKey, privacy: .public)")

        // Construct the HTTP request for upgrading to WebSocket
        let path = url.path.isEmpty ? "/" : url.path
        let request = """
        GET \(path) HTTP/1.1\r
        Host: \(url.host ?? "localhost")\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(wsKey)\r
        Sec-WebSocket-Version: 13\r
        \r
        """

        logger.debug("WebSocket upgrade request: \(request, privacy: .public)")

        guard let requestData = request.data(using: .utf8) else {
            throw WebSocketError.invalidData
        }

        // Send the upgrade request
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let connection = connection else {
                continuation.resume(throwing: WebSocketError.notConnected)
                return
            }

            connection.send(content: requestData, completion: .contentProcessed { error in
                if let error = error {
                    logger.error("Error sending WebSocket upgrade request: \(error, privacy: .public)")
                    continuation.resume(throwing: error)
                } else {
                    logger.debug("WebSocket upgrade request sent successfully")
                    continuation.resume()
                }
            })
        }

        // Wait for and process the upgrade response
        let response = try await receiveWebSocketUpgradeResponse()
        logger.debug("WebSocket upgrade response: \(response, privacy: .public)")

        // Check if the upgrade was successful
        if !response.contains("HTTP/1.1 101") {
            logger.error("WebSocket upgrade failed: \(response, privacy: .public)")
            throw WebSocketError.connectionFailed
        }

        logger.debug("WebSocket connection established")
    }

    private func receiveWebSocketUpgradeResponse() async throws -> String {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            guard let connection = connection else {
                continuation.resume(throwing: WebSocketError.notConnected)
                return
            }

            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { content, _, isComplete, error in
                if let error = error {
                    logger.error("Error receiving WebSocket upgrade response: \(error, privacy: .public)")
                    continuation.resume(throwing: error)
                    return
                }

                if let content = content, let response = String(data: content, encoding: .utf8) {
                    logger.debug("Received upgrade response data: \(content.count) bytes")
                    continuation.resume(returning: response)
                } else if isComplete {
                    logger.debug("Connection closed by peer during handshake")
                    continuation.resume(throwing: WebSocketError.connectionClosed)
                } else {
                    logger.error("Failed to parse WebSocket upgrade response")
                    continuation.resume(throwing: WebSocketError.invalidData)
                }
            }
        }
    }
}
