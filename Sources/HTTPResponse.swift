import Foundation

struct HTTPResponse {
    enum Status: Int {
        case ok = 200
        case badRequest = 400
        case notFound = 404
        case forbidden = 403
        case methodNotAllowed = 405
        case internalServerError = 500
    }

    let status: Status
    let body: Data
    let contentType: String

    init(status: Status, body: Data = Data(), contentType: String = "text/plain") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    var data: Data {
        var response = "HTTP/1.1 \(status.rawValue) \(statusText)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Connection: close\r\n\r\n"

        var responseData = Data(response.utf8)
        responseData.append(body)
        return responseData
    }

    private var statusText: String {
        switch status {
        case .ok: "OK"
        case .badRequest: "Bad Request"
        case .notFound: "Not Found"
        case .forbidden: "Forbidden"
        case .methodNotAllowed: "Method Not Allowed"
        case .internalServerError: "Internal Server Error"
        }
    }
}
