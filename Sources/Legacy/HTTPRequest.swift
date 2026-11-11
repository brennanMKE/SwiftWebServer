import Foundation

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String             // decoded path like "/foo/index.html"
    public let rawTarget: String        // full raw URI from the request line (e.g. "/foo/index.html?x=1")
    public let query: String?           // raw query string, if any
    public let headers: [String: String]
    public let body: Data?

    public init(method: String, path: String, rawTarget: String, query: String?, headers: [String: String], body: Data? = nil) {
        self.method = method
        self.path = path
        self.rawTarget = rawTarget
        self.query = query
        self.headers = headers
        self.body = body
    }

    public var includeBody: Bool {
        method == "GET"
    }

    public var isSupportedMethod: Bool {
        method == "GET" || method == "HEAD"
    }

    public var isWebSocketUpgrade: Bool {
        header(named: "Upgrade")?.lowercased() == "websocket"
    }

    public func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public static func parse(from data: Data) -> HTTPRequest? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }

        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 2 else { return nil }

        let method = components[0]
        let rawTarget = components[1]
        let path: String
        let query: String?

        if let urlComponents = URLComponents(string: rawTarget) {
            path = urlComponents.path
            query = urlComponents.query
        } else {
            path = rawTarget
            query = nil
        }

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, let sep = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<sep]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return HTTPRequest(
            method: method,
            path: path,
            rawTarget: rawTarget,
            query: query,
            headers: headers
        )
    }
}
