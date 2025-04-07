import Foundation

public struct HTTPResponse: Sendable {
    public let status: Status
    public let headers: [String: String]
    public let body: Data?

    public init(status: Status, headers: [String: String] = [:], body: Data? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var statusText: String {
        switch status {
        case .ok: return "OK"
        case .notFound: return "Not Found"
        case .badRequest: return "Bad Request"
        case .internalServerError: return "Internal Server Error"
        case .switchingProtocols: return "Switching Protocols"
        case .notModified: return "Not Modified"
        case .forbidden: return "Forbidden"
        case .methodNotAllowed: return "Method Not Allowed"
        }
    }

    public var statusLine: String {
        "HTTP/1.1 \(status.rawValue) \(statusText)"
    }

    public var data: Data {
        var response = statusLine + "\r\n"

        // Add headers
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }

        // Add content length if there's a body
        if let body = body {
            response += "Content-Length: \(body.count)\r\n"
        }

        response += "\r\n"

        var responseData = Data(response.utf8)
        if let body = body {
            responseData.append(body)
        }

        return responseData
    }
}

public enum Status: Int, Sendable {
    case ok = 200
    case notModified = 304
    case badRequest = 400
    case forbidden = 403
    case notFound = 404
    case methodNotAllowed = 405
    case internalServerError = 500
    case switchingProtocols = 101
}
