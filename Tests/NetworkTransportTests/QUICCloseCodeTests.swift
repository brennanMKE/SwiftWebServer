import Foundation
import HTTPCore
import HTTPTestSupport
import Network
@testable import NetworkTransport
import Synchronization
import Testing

/// Homebrew curl, built with HTTP/3 (ngtcp2).
let closeCodeCurlPath = "/opt/homebrew/opt/curl/bin/curl"

/// #0104, QUIC spike open question 6: does the application error code set on the group
/// (`NWProtocolQUIC.Metadata.applicationError`) reach the peer in CONNECTION_CLOSE?
///
/// curl runs through a loopback ``UDPRelay`` that keeps every datagram the server sends, and
/// writes its TLS secrets (`SSLKEYLOGFILE`) and a qlog (`QLOGDIR`). The test decrypts what the
/// server sent after it began closing (``QUICShortHeaderDecryptor``) and also reads which
/// CONNECTION_CLOSE frames curl logged. No packet capture, root or new tools are needed.
///
/// Observed (macOS 27, curl 8.23 / ngtcp2 1.26, recorded in `docs/notes/nw-transport.md`):
/// Network.framework never sends an application CONNECTION_CLOSE (frame 0x1d), so our code
/// never reaches the peer, in either close mode. After the group is cancelled the server sends
/// only STOP_SENDING / RESET_STREAM frames (and a FIN on a server-initiated stream 1 it never
/// opened); curl then closes the connection itself. The only CONNECTION_CLOSE the server sends
/// (in some runs) is a transport one (0x1c) with NO_ERROR, mostly after curl's own close. The test checks that pipeline
/// (every datagram decrypts) and those facts; our code reaching curl is a known issue, so a
/// Network.framework change that starts sending it shows up here.
@Suite(.timeLimit(.minutes(1)), .enabled(if: FileManager.default.isExecutableFile(atPath: closeCodeCurlPath)))
struct QUICCloseCodeTests {
    static let curlPath = closeCodeCurlPath

    /// How the server ends the connection.
    enum CloseMode: Sendable, CaseIterable, CustomTestStringConvertible {
        /// `QUICConnection.close(applicationError:)`: reset every stream, then cancel the group.
        case adapter
        /// Set the group's application error and cancel the group, streams untouched.
        case groupOnly

        var testDescription: String { "\(self)" }
    }

    struct Observation: Sendable {
        /// `connection_close` frames curl logged as received: (error space, code).
        var received: [(space: String, code: UInt64)] = []
        /// `connection_close` frames curl sent.
        var sent: [(space: String, code: UInt64)] = []
        /// Stream resets and STOP_SENDINGs curl logged as received.
        var streamAborts = 0
        /// Server-to-client datagrams (size, first byte) the relay saw after the server began
        /// closing.
        var serverDatagramsAfterClose: [(size: Int, firstByte: UInt8)] = []
        /// CONNECTION_CLOSE frames in those datagrams, decrypted with curl's key log:
        /// (frame type, code). 0x1d is an application close.
        var decryptedCloses: [(type: UInt64, code: UInt64)] = []
        /// Short-header datagrams among those that did not decrypt.
        var undecryptable = 0
        /// Whether curl had already sent its own CONNECTION_CLOSE (decrypted from the relay)
        /// before the first one from the server.
        var curlClosedFirst: Bool?
        /// curl's error message.
        var curlError = ""

        /// True when our code reached curl in an application CONNECTION_CLOSE.
        func sawOurCode(_ code: UInt64) -> Bool {
            decryptedCloses.contains { $0.type == 0x1d && $0.code == code }
                || received.contains { $0.space == "application" && $0.code == code }
        }
    }

    @Test(arguments: CloseMode.allCases, [UInt64(0x107), 0x100])
    func applicationCloseCode(mode: CloseMode, code: UInt64) async throws {
        let observation = try await Self.observe(mode: mode, code: code)
        // The server did send something after it began closing, and all of it decrypted.
        #expect(!observation.serverDatagramsAfterClose.isEmpty, "\(observation)")
        #expect(observation.undecryptable == 0, "\(observation)")
        // A close from the server is either ours or a transport NO_ERROR (Network.framework's
        // own, usually after curl closed).
        for close in observation.decryptedCloses where !(close.type == 0x1d && close.code == code) {
            #expect(close.type == 0x1c && close.code == 0, "\(observation)")
        }
        for close in observation.received {
            #expect(close.space == "application" && close.code == code, "\(observation)")
        }
        // The known limitation: our code does not reach the peer. If this is reported as
        // passing, Network.framework now sends CONNECTION_CLOSE; update docs/notes/nw-transport.md.
        withKnownIssue("Network.framework sends no CONNECTION_CLOSE (#0104, spike Q6)", isIntermittent: true) {
            #expect(observation.sawOurCode(code), "\(observation)")
        }
    }

    static func bytes(hex: Substring) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)!
        }
    }

    /// Runs one curl request, through a ``UDPRelay``, against a listener whose connection is
    /// closed as `mode` says once curl's request stream arrives; reads curl's qlog and the
    /// relay's log.
    static func observe(mode: CloseMode, code: UInt64) async throws -> Observation {
        let qlogDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sws-qlog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: qlogDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: qlogDirectory) }

        let listener = try await makeQUICListener(quic: testQUICConfiguration())
        let relay = try UDPRelay(serverPort: listener.port)
        let closedAt = Mutex<ContinuousClock.Instant?>(nil)
        let keyLog = qlogDirectory.deletingLastPathComponent().appendingPathComponent("sws-keylog-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: keyLog) }
        let curlError = Mutex("")
        try await withThrowingTaskGroup(of: Void.self) { outer in
            outer.addTask { await relay.run() }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let connection = try await accept(listener)
                    // Keep every stream: dropping one cancels it (STOP_SENDING), and curl closes
                    // the connection itself when its control or QPACK stream is stopped.
                    var streams: [QUICStreamTransport] = []
                    var inbound = connection.inboundStreams.makeAsyncIterator()
                    while let stream = try await inbound.next() {
                        streams.append(stream)
                        if !stream.isUnidirectional { break }
                    }
                    closedAt.withLock { $0 = .now }
                    switch mode {
                    case .adapter:
                        await connection.close(applicationError: code)
                    case .groupOnly:
                        let nwGroup = connection.core.state.withLock { $0.group }
                        nwGroup?.quicMetadata?.applicationError = NWProtocolQUIC.ApplicationError(code: code, reason: "")
                        nwGroup?.cancel()
                        try await Task.sleep(for: .milliseconds(300))
                        await connection.close(applicationError: code)
                    }
                    streams.removeAll()
                }
                group.addTask {
                    let output = try await ChildProcess.run(
                        URL(fileURLWithPath: "/usr/bin/env"),
                        ["QLOGDIR=\(qlogDirectory.path)", "SSLKEYLOGFILE=\(keyLog.path)", curlPath, "--http3-only", "-k", "-s", "-S", "--max-time", "10",
                         "-o", "/dev/null", "https://127.0.0.1:\(relay.port)/"],
                        timeout: .seconds(20))
                    curlError.withLock { $0 = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                try await group.waitForAll()
            }
            // Anything the server still sends after curl has gone.
            try await Task.sleep(for: .milliseconds(200))
            outer.cancelAll()
        }
        await listener.close()

        var observation = Observation()
        let since = closedAt.withLock { $0 } ?? .now
        observation.serverDatagramsAfterClose = relay.serverDatagrams.filter { $0.at >= since }.map { ($0.size, $0.firstByte) }
        observation.curlError = curlError.withLock { $0 }
        // Decrypt what the server sent after it started closing, with curl's key log.
        let lines = (try? String(contentsOf: keyLog, encoding: .utf8))?.split(separator: "\n") ?? []
        if let line = lines.first(where: { $0.hasPrefix("SERVER_TRAFFIC_SECRET_0 ") }),
           let hex = line.split(separator: " ").last {
            let secret = stride(from: 0, to: hex.count, by: 2).map {
                UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)!
            }
            // curl's connection IDs are 20 bytes; Network.framework's are 8.
            let decryptor = QUICShortHeaderDecryptor(secret: secret, connectionIDLength: 20)
            let clientSecret = lines.first { $0.hasPrefix("CLIENT_TRAFFIC_SECRET_0 ") }.flatMap { $0.split(separator: " ").last }
            let clientDecryptor = clientSecret.map { QUICShortHeaderDecryptor(secret: Self.bytes(hex: $0), connectionIDLength: 8) }
            var curlClosed = false
            for datagram in relay.datagrams where datagram.at >= since && datagram.firstByte & 0x80 == 0 {
                if !datagram.fromServer {
                    if let frames = clientDecryptor?.decrypt(datagram.bytes),
                       !QUICShortHeaderDecryptor.connectionCloses(in: frames).isEmpty {
                        curlClosed = true
                    }
                    continue
                }
                guard let frames = decryptor.decrypt(datagram.bytes) else {
                    observation.undecryptable += 1
                    continue
                }
                let closes = QUICShortHeaderDecryptor.connectionCloses(in: frames)
                if !closes.isEmpty && observation.curlClosedFirst == nil { observation.curlClosedFirst = curlClosed }
                observation.decryptedCloses += closes
            }
        }
        for file in try FileManager.default.contentsOfDirectory(at: qlogDirectory, includingPropertiesForKeys: nil) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for record in text.split(whereSeparator: { $0 == "\u{1e}" || $0 == "\n" }) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(record.utf8)) as? [String: Any],
                      let name = object["name"] as? String,
                      let data = object["data"] as? [String: Any],
                      let frames = data["frames"] as? [[String: Any]]
                else { continue }
                let received = name == "transport:packet_received"
                guard received || name == "transport:packet_sent" else { continue }
                for frame in frames {
                    switch frame["frame_type"] as? String {
                    case "connection_close":
                        let close = (space: frame["error_space"] as? String ?? "?",
                                     code: (frame["error_code"] as? NSNumber)?.uint64Value ?? .max)
                        if received { observation.received.append(close) } else { observation.sent.append(close) }
                    case "reset_stream", "stop_sending":
                        if received { observation.streamAborts += 1 }
                    default:
                        break
                    }
                }
            }
        }
        return observation
    }
}
