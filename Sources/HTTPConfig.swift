// Reads in http-config.json

import Foundation

struct Caching: Codable {
    let enabled: Bool
    let maxAge: Int
}

struct MimeType: Codable {
    let pathExtensions: [String]
    let contentType: String
}

struct HTTPConfig: Codable {
    let port: Int
    let defaultIndex: String // index.html
    let caching: Caching
    let defaultMimeType: String
    let mimeTypes: [MimeType]
    let blockList: [String]
}
