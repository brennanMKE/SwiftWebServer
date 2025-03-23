import Foundation

struct HTTPRequest {
    let method: String
    let path: String

    static func parse(from data: Data) -> HTTPRequest? {
        guard let requestLine = String(data: data, encoding: .utf8)?
                .components(separatedBy: "\r\n").first else {
            return nil
        }

        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 2 else { return nil }

        return HTTPRequest(method: components[0], path: components[1])
    }
}
