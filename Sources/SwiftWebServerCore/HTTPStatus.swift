import Foundation

public enum HTTPStatus: Int, Sendable {
    case ok = 200
    case notModified = 304
    case badRequest = 400
    case forbidden = 403
    case notFound = 404
    case methodNotAllowed = 405
    case internalServerError = 500

    var statusText: String {
        switch self {
        case .ok: "OK"
        case .notModified: "Not Modified"
        case .badRequest: "Bad Request"
        case .forbidden: "Forbidden"
        case .notFound: "Not Found"
        case .methodNotAllowed: "Method Not Allowed"
        case .internalServerError: "Internal Server Error"
        }
    }

}
