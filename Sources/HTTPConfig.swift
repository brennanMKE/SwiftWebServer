// Reads in http.config

import Foundation

struct MimeType: Codable {
    let pathExtensions: [String]
    let contentType: String
}

struct HTTPConfig: Codable {
    let defaultIndex: String // index.html
    let defaultMimeType: String
    let mimeTypes: [MimeType]
}
