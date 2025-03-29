import Foundation

struct HTTPResponse {
    enum Status: Int {
        case ok = 200
        case notModified = 304
        case badRequest = 400
        case notFound = 404
        case forbidden = 403
        case methodNotAllowed = 405
        case internalServerError = 500

        var statusText: String {
            switch self {
            case .ok: "OK"
            case .notModified: "Not Modified"
            case .badRequest: "Bad Request"
            case .notFound: "Not Found"
            case .forbidden: "Forbidden"
            case .methodNotAllowed: "Method Not Allowed"
            case .internalServerError: "Internal Server Error"
            }
        }
    }

    let status: Status
    let body: Data
    let contentType: String
    let extraHeaders: [String: String]
    let includeBody: Bool

    init(status: Status,
         body: Data = Data(),
         contentType: String = "text/plain",
         extraHeaders: [String: String] = [:],
         includeBody: Bool = true) {
        self.status = status
        self.extraHeaders = extraHeaders
        self.includeBody = includeBody

        if status == .ok {
            self.body = body
            self.contentType = contentType
        } else {
            self.body = HTTPPage.default.page(for: status).data(using: .utf8) ?? body
            self.contentType = "text/html"
        }
    }

    var data: Data {
        var response = "HTTP/1.1 \(status.rawValue) \(status.statusText)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Content-Type: \(contentType)\r\n"

        for (key, value) in extraHeaders {
            response += "\(key): \(value)\r\n"
        }

        response += "Connection: close\r\n\r\n"

        var responseData = Data(response.utf8)
        if includeBody {
            responseData.append(body)
        }
        return responseData
    }
}
