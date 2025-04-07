import Foundation
import Network
import os.log

public actor WebSocketConnection {
    private let connection: NWConnection
    private var isOpen = true

    public init(connection: NWConnection) {
        self.connection = connection
        logger.debug("WebSocketConnection initialized for \(String(describing: connection.endpoint))")
    }

    public func start() {
        logger.debug("Starting WebSocketConnection for \(String(describing: self.connection.endpoint))")

        // Set up connection state monitor
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.debug("WebSocket connection is ready: \(String(describing: self.connection.endpoint))")
            case .waiting(let error):
                logger.warning("WebSocket connection is waiting: \(error)")
            case .failed(let error):
                logger.error("WebSocket connection failed: \(error)")
            case .setup:
                logger.debug("WebSocket connection is setting up")
            case .preparing:
                logger.debug("WebSocket connection is preparing")
            case .cancelled:
                logger.debug("WebSocket connection was cancelled")
            default:
                logger.debug("WebSocket connection is in unknown state: \(String(describing: state))")
            }
        }

        // Start a simple direct loop for receiving frames
        Task {
            logger.debug("Starting simple WebSocket receive loop")
            await simpleReceiveLoop()
        }
    }

    private func simpleReceiveLoop() async {
        logger.debug("Starting simple receive loop for \(String(describing: self.connection.endpoint))")

        while isOpen {
            logger.debug("Waiting for WebSocket data...")

            do {
                // Use a manual continuation to receive data
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    logger.debug("Setting up receive operation")

                    self.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                        logger.debug("Receive callback triggered")

                        if let error = error {
                            logger.error("WebSocket receive error: \(error)")
                            continuation.resume(throwing: error)
                            return
                        }

                        if isComplete {
                            logger.debug("WebSocket connection completed normally")
                            continuation.resume()
                            return
                        }

                        if let data = data, !data.isEmpty {
                            logger.debug("********************************************")
                            logger.debug("RECEIVED \(data.count) BYTES OF WEBSOCKET DATA!")
                            logger.debug("********************************************")

                            let hexString = data.map { String(format: "%02x", $0) }.joined(separator: " ")
                            logger.debug("Raw frame data (hex): \(hexString)")

                            // Try to parse and handle the frame
                            do {
                                let frame = try WebSocketFrame.parse(from: data)
                                logger.debug("Successfully parsed WebSocket frame with opcode \(frame.opcode.rawValue)")
                                Task {
                                    await self.handleFrame(frame)
                                }
                            } catch {
                                logger.error("Failed to parse WebSocket frame: \(error)")
                            }

                            continuation.resume()
                        } else {
                            logger.debug("Received empty data")
                            continuation.resume()
                        }
                    }
                }

                // Small delay between receive attempts
                try await Task.sleep(for: .milliseconds(100))

            } catch {
                logger.error("Error in receive loop: \(error)")
                // Wait before trying again
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        logger.debug("Simple receive loop ended for \(String(describing: self.connection.endpoint))")
    }

    // Keep these compatibility methods
    private func receiveNextFrame() async {
        logger.debug("Using legacy receiveNextFrame (no longer used)")
    }

    private func receiveNextFrameWithTimeout() async {
        logger.debug("Using legacy receiveNextFrameWithTimeout (no longer used)")
    }

    private func handleFrame(_ frame: WebSocketFrame) async {
        logger.debug("Handling WebSocket frame with opcode \(frame.opcode.rawValue)")

        switch frame.opcode {
        case .text:
            if let text = String(data: frame.payload, encoding: .utf8) {
                logger.debug("Received text message: '\(text)'")

                // Log that we're echoing the message back
                logger.debug("Echoing text message back to client: '\(text)'")

                // Echo the message back as text
                let response = WebSocketFrame(
                    fin: true,
                    rsv1: false,
                    rsv2: false,
                    rsv3: false,
                    opcode: .text,
                    masked: false, // Server-to-client frames must not be masked
                    payload: frame.payload
                )
                let responseData = response.toData()
                logger.debug("Sending echo response frame: \(responseData.count) bytes")

                connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
                    if let error = error {
                        logger.error("Error sending echo response: \(error)")
                        Task { await self?.close() }
                    } else {
                        logger.debug("Echo response sent successfully")
                    }
                })
            } else {
                logger.error("Received text frame with invalid UTF-8 data")
            }
        case .binary:
            logger.debug("Received binary data: \(frame.payload.count) bytes")

            // Echo the binary data back
            logger.debug("Echoing binary data back to client: \(frame.payload.count) bytes")

            let response = WebSocketFrame(
                fin: true,
                rsv1: false,
                rsv2: false,
                rsv3: false,
                opcode: .binary,
                masked: false, // Server-to-client frames must not be masked
                payload: frame.payload
            )
            let responseData = response.toData()
            logger.debug("Sending binary echo response frame: \(responseData.count) bytes")

            connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    logger.error("Error sending binary echo response: \(error)")
                    Task { await self?.close() }
                } else {
                    logger.debug("Binary echo response sent successfully")
                }
            })
        case .close:
            logger.debug("Received close frame")
            if frame.payload.count >= 2 {
                let code = UInt16(frame.payload[0]) << 8 | UInt16(frame.payload[1])
                logger.debug("Close frame includes status code: \(code)")

                if frame.payload.count > 2, let reason = String(data: frame.payload.subdata(in: 2..<frame.payload.count), encoding: .utf8) {
                    logger.debug("Close frame includes reason: \(reason)")
                }
            }
            await close()
        case .ping:
            logger.debug("Received ping frame")
            await sendPong()
        case .pong:
            logger.debug("Received pong frame")
        case .continuation:
            logger.debug("Received continuation frame")
        }
    }

    public func send(text: String) async {
        logger.debug("Sending text message: '\(text)'")
        guard let data = text.data(using: .utf8) else {
            logger.error("Failed to encode text to UTF-8 data")
            return
        }
        // Create text frame directly instead of using binary method
        let frame = WebSocketFrame(opcode: .text, masked: false, payload: data)
        let frameData = frame.toData()
        logger.debug("Sending WebSocket text frame: \(frameData.count) bytes")

        connection.send(content: frameData, completion: .contentProcessed { [weak self] error in
            if let error = error {
                logger.error("WebSocket send error: \(error)")
                Task { await self?.close() }
            } else {
                logger.debug("WebSocket frame sent successfully")
            }
        })
    }

    public func send(binary: Data) async {
        logger.debug("Creating WebSocket frame for sending \(binary.count) bytes")
        // Server-to-client frames should NOT be masked
        let frame = WebSocketFrame(opcode: .binary, masked: false, payload: binary)
        let data = frame.toData()
        logger.debug("Sending WebSocket frame: \(data.count) bytes")

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                logger.error("WebSocket send error: \(error)")
                Task { await self?.close() }
            } else {
                logger.debug("WebSocket frame sent successfully")
            }
        })
    }

    private func sendPong() async {
        logger.debug("Sending pong frame")
        let frame = WebSocketFrame(opcode: .pong, masked: false)
        let data = frame.toData()

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                logger.error("WebSocket pong send error: \(error)")
                Task { await self?.close() }
            } else {
                logger.debug("Pong frame sent successfully")
            }
        })
    }

    public func close() async {
        logger.debug("Closing WebSocketConnection for \(String(describing: self.connection.endpoint))")
        guard isOpen else {
            logger.debug("WebSocketConnection already closed")
            return
        }
        isOpen = false

        logger.debug("Creating close frame")
        let frame = WebSocketFrame(opcode: .close, masked: false)
        let data = frame.toData()

        logger.debug("Sending close frame: \(data.count) bytes")
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                logger.error("WebSocket close error: \(error)")
            } else {
                logger.debug("Close frame sent successfully")
            }
            logger.debug("Cancelling WebSocket connection")
            self?.connection.cancel()
        })
    }
}
