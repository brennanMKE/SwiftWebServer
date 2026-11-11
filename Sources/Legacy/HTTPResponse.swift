import Foundation

public struct HTTPResponse: Sendable {
    public let status: HTTPStatus
    public let headers: [String: String]
    public let body: Data?

    public init(status: HTTPStatus, headers: [String: String] = [:], body: Data? = nil) {
        self.status = status
        self.headers = headers
        if status == .ok {
            self.body = body
        } else {
            self.body = HTTPPage.default.page(for: status).data(using: .utf8)
        }
    }

    public var statusLine: String {
        "HTTP/1.1 \(status.rawValue) \(status.statusText)"
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
