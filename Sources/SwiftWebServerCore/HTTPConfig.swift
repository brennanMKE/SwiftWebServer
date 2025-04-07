// Reads in http-config.json

import Foundation

public struct Caching: Codable, Sendable {
    public let enabled: Bool
    public let maxAge: Int
    
    public init(enabled: Bool, maxAge: Int) {
        self.enabled = enabled
        self.maxAge = maxAge
    }
}

public struct MimeType: Codable, Sendable {
    public let pathExtensions: [String]
    public let contentType: String
    
    public init(pathExtensions: [String], contentType: String) {
        self.pathExtensions = pathExtensions
        self.contentType = contentType
    }
}

public struct HTTPConfig: Codable, Sendable {
    public let port: UInt16
    public let maxConnections: Int
    public let keepAliveTimeout: TimeInterval
    public let maxRequestSize: Int
    public let enableCompression: Bool
    public let enableETags: Bool
    public let defaultIndex: String // index.html
    public let caching: Caching
    public let defaultMimeType: String
    public let mimeTypes: [MimeType]
    public let blockList: [String]
    
    public init(
        port: UInt16 = 8080,
        maxConnections: Int = 100,
        keepAliveTimeout: TimeInterval = 5,
        maxRequestSize: Int = 10 * 1024 * 1024, // 10MB
        enableCompression: Bool = true,
        enableETags: Bool = true,
        defaultIndex: String = "index.html",
        caching: Caching = Caching(enabled: true, maxAge: 3600),
        defaultMimeType: String = "text/html",
        mimeTypes: [MimeType] = [],
        blockList: [String] = []
    ) {
        self.port = port
        self.maxConnections = maxConnections
        self.keepAliveTimeout = keepAliveTimeout
        self.maxRequestSize = maxRequestSize
        self.enableCompression = enableCompression
        self.enableETags = enableETags
        self.defaultIndex = defaultIndex
        self.caching = caching
        self.defaultMimeType = defaultMimeType
        self.mimeTypes = mimeTypes
        self.blockList = blockList
    }
}
