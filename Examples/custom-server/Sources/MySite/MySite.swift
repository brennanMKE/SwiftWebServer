import AccessLog
import Compression
import Dispatch
import Darwin
import HTTP1
import HTTPCore
import HTTPServer
import NetworkTransport
import Router
import StaticFiles
import WebSockets

/// A JSON response from a string.
func json(_ text: String, status: HTTPStatus = .ok) -> HTTPResponse {
    var headers = HTTPFields()
    headers.append(.contentType, "application/json")
    return HTTPResponse(status: status, headers: headers, body: .bytes(ByteBuffer(bytes: Array(text.utf8))))
}

/// Runs `action` on SIGINT and SIGTERM. A plain (nonisolated) function, so the handler does
/// not inherit `main()`'s main-actor isolation; it runs on a dispatch queue.
func onShutdownSignal(_ action: @escaping @Sendable () -> Void) -> [any DispatchSourceSignal] {
    let queue = DispatchQueue(label: "signals")
    return [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
        source.setEventHandler(handler: action)
        source.resume()
        return source
    }
}

@main
struct MySite {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let root = arguments.count > 1 ? arguments[1] : "Public"
        let port = arguments.count > 2 ? UInt16(arguments[2]) ?? 8080 : 8080

        let router = try Router {
            GET("/api/hello/:name") { _, context in
                json(#"{"hello": "\#(context.params["name"] ?? "")"}"#)
            }
            POST("/api/echo") { request, _ in
                let body = try await request.body.collect(upTo: 1 << 20)
                var headers = HTTPFields()
                headers.append(.contentType, "application/octet-stream")
                return HTTPResponse(status: .ok, headers: headers, body: .bytes(body))
            }
        }
        let echo = WebSocketUpgrade(path: "/ws") { socket, _ in
            for await message in socket.messages {
                try await socket.send(message)
            }
        }
        let files = try StaticFiles(root: root)
        let listener = try BSDSocketListener(configuration: .init(host: "127.0.0.1", port: port))

        let server = Server(listeners: [listener], protocols: [HTTP1()]) {
            AccessLog(format: .combined, destination: .standardOutput)
            Compression()
            echo
            router
            files               // the last element is the terminal handler
        }

        // SIGINT and SIGTERM: stop accepting, let open connections finish, then return.
        let signals = onShutdownSignal { server.requestShutdown() }
        defer { signals.forEach { $0.cancel() } }

        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { try await server.run() }   // returns after a graceful shutdown
            group.addTask {
                for address in try await server.waitUntilRunning() { print("listening \(address)") }
            }
        }
    }
}
