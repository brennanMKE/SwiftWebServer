public import Foundation

/// An error in a config file. The description names the file and, for a bad value, the key.
public struct ConfigFileError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The key at fault (dotted for nested keys, such as `timeouts.idle`), when there is one.
    public var key: String?
    public var description: String

    public init(key: String? = nil, _ description: String) {
        self.key = key
        self.description = description
    }
}

/// `http-config.json` parsed into ``ServerSettings`` (#0086, legacy #0023).
///
/// - Every key is optional; missing keys keep their default (or the `defaults` passed in).
/// - Unknown keys do not fail: each adds a line to ``warnings``.
/// - A value of the wrong type or out of range throws ``ConfigFileError`` naming the key.
/// - Keys reserved for components that are not built yet (`tls`, `accessLog`) and legacy
///   keys that no longer do anything (`enableETags`, `enableCompression`) are accepted with a
///   warning, so the TLS and AccessLog work can claim them without breaking old files.
///
/// Foundation is used here: the file is read once at startup, never on the request path.
public struct ConfigFile: Sendable {
    /// The settings: `defaults` with every key in the file applied.
    public var settings: ServerSettings
    /// One line per ignored key or value.
    public var warnings: [String]
    /// The top-level keys present in the file.
    public var keys: Set<String>
    /// Values of reserved keys (`tls`, `accessLog`), as JSON objects, for the components that
    /// will read them.
    public var reserved: [String: ReservedValue]

    /// A reserved key's value, kept as text so it stays `Sendable`.
    public struct ReservedValue: Sendable, Equatable {
        /// The value re-serialized as JSON.
        public var json: String
    }

    /// Keys whose components are not built yet; accepted and passed through.
    public static let reservedKeys: Set<String> = ["tls", "accessLog"]
    /// Legacy keys that have no effect any more.
    public static let ignoredLegacyKeys: [String: String] = [
        "enableETags": "ETags are always sent (metadata-based, no hashing)",
        "enableCompression": "compression is not available yet (#0091)",
    ]

    /// Reads and parses the file at `path`. ``ServerSettings/baseDirectory`` becomes the file's
    /// directory, so a relative `root` is relative to the file.
    public static func load(path: String, defaults: ServerSettings = ServerSettings()) throws(ConfigFileError) -> ConfigFile {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ConfigFileError("cannot read config file \(path): \(Self.reason(error))")
        }
        var base = defaults
        base.baseDirectory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return try parse(data, source: path, defaults: base)
    }

    /// Parses JSON `data`; `source` names it in messages.
    public static func parse(_ data: Data, source: String = "config", defaults: ServerSettings = ServerSettings()) throws(ConfigFileError) -> ConfigFile {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ConfigFileError("config file \(source) is not valid JSON: \(Self.reason(error))")
        }
        guard let dictionary = object as? [String: Any] else {
            throw ConfigFileError("config file \(source) is not a JSON object")
        }
        var parser = Parser(source: source, settings: defaults)
        try parser.apply(dictionary)
        return ConfigFile(settings: parser.settings, warnings: parser.warnings,
                          keys: Set(dictionary.keys), reserved: parser.reserved)
    }

    static func reason(_ error: any Error) -> String {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        if let debug = nsError.userInfo["NSDebugDescription"] as? String { return debug }
        return nsError.localizedDescription
    }
}

/// Applies a decoded JSON object to settings, key by key.
struct Parser {
    let source: String
    var settings: ServerSettings
    var warnings: [String] = []
    var reserved: [String: ConfigFile.ReservedValue] = [:]

    init(source: String, settings: ServerSettings) {
        self.source = source
        self.settings = settings
    }

    func fail(_ key: String, _ expectation: String) -> ConfigFileError {
        ConfigFileError(key: key, "config file \(source): \"\(key)\" \(expectation)")
    }

    mutating func warn(_ text: String) {
        warnings.append("config file \(source): \(text)")
    }

    mutating func apply(_ object: [String: Any]) throws(ConfigFileError) {
        // Sorted, so warnings and the first error do not depend on dictionary order.
        for key in object.keys.sorted() {
            let value = object[key]!
            switch key {
            case "host":
                let host = try string(value, key)
                guard !host.isEmpty else { throw fail(key, "must not be empty") }
                settings.host = host
            case "port":
                settings.port = UInt16(try integer(value, key, in: 0...65535))
            case "root", "path":
                if object["root"] != nil, object["path"] != nil, key == "path" {
                    warn("\"path\" ignored because \"root\" is set")
                    continue
                }
                let root = try string(value, key)
                guard !root.isEmpty else { throw fail(key, "must not be empty") }
                settings.root = root
            case "index", "defaultIndex":
                if object["index"] != nil, object["defaultIndex"] != nil, key == "defaultIndex" {
                    warn("\"defaultIndex\" ignored because \"index\" is set")
                    continue
                }
                let names = value is String ? [try string(value, key)] : try strings(value, key)
                guard !names.contains(where: { $0.isEmpty || $0.contains("/") }) else {
                    throw fail(key, "must be file names (not empty, no \"/\")")
                }
                settings.index = names
            case "mimeTypes":
                settings.mimeTypes = try mimeTypes(value, key)
            case "defaultMimeType":
                let type = try string(value, key)
                guard !type.isEmpty else { throw fail(key, "must not be empty") }
                settings.defaultMimeType = type
            case "blockList":
                settings.blockList = try strings(value, key)
            case "blockDotfiles":
                settings.blockDotfiles = try bool(value, key)
            case "caching":
                try caching(value, key)
            case "maxConnections":
                settings.maxConnections = try integer(value, key, in: 1...Int(Int32.max))
            case "drainTimeout":
                settings.drainTimeout = try seconds(value, key, zeroMeansOff: false)
            case "timeouts":
                try timeouts(value, key)
            case "keepAliveTimeout":
                if (object["timeouts"] as? [String: Any])?["idle"] != nil {
                    warn("\"keepAliveTimeout\" ignored because \"timeouts.idle\" is set")
                    continue
                }
                settings.timeouts.idle = try seconds(value, key)
            case "maxBodySize", "maxRequestSize":
                if object["maxBodySize"] != nil, object["maxRequestSize"] != nil, key == "maxRequestSize" {
                    warn("\"maxRequestSize\" ignored because \"maxBodySize\" is set")
                    continue
                }
                settings.maxBodySize = try integer(value, key, in: 0...Int.max)
            case "transport":
                let text = try string(value, key)
                guard let transport = ServerSettings.Transport(rawValue: text) else {
                    throw fail(key, "must be one of \(ServerSettings.Transport.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))")
                }
                settings.transport = transport
            case "errorPages":
                settings.errorPages = try errorPages(value, key)
            case _ where ConfigFile.reservedKeys.contains(key):
                reserved[key] = ConfigFile.ReservedValue(json: Self.json(value))
                warn("\"\(key)\" is reserved for a component that is not available yet; ignored")
            case _ where ConfigFile.ignoredLegacyKeys[key] != nil:
                warn("\"\(key)\" has no effect: \(ConfigFile.ignoredLegacyKeys[key]!)")
            default:
                warn("unknown key \"\(key)\" ignored")
            }
        }
    }

    // MARK: Sections

    mutating func caching(_ value: Any, _ key: String) throws(ConfigFileError) {
        if Self.isBool(value) {
            settings.maxAge = try bool(value, key) ? (settings.maxAge ?? 3600) : nil
            return
        }
        let object = try dictionary(value, key)
        var enabled = true
        var maxAge = settings.maxAge ?? 3600
        for name in object.keys.sorted() {
            let path = "\(key).\(name)"
            switch name {
            case "enabled": enabled = try bool(object[name]!, path)
            case "maxAge": maxAge = try integer(object[name]!, path, in: 0...Int(Int32.max))
            default: warn("unknown key \"\(path)\" ignored")
            }
        }
        settings.maxAge = enabled ? maxAge : nil
    }

    mutating func timeouts(_ value: Any, _ key: String) throws(ConfigFileError) {
        let object = try dictionary(value, key)
        for name in object.keys.sorted() {
            let path = "\(key).\(name)"
            let limit = try seconds(object[name]!, path)
            switch name {
            case "header": settings.timeouts.header = limit
            case "idle": settings.timeouts.idle = limit
            case "body": settings.timeouts.body = limit
            case "send": settings.timeouts.send = limit
            case "linger": settings.timeouts.linger = limit
            default: warn("unknown key \"\(path)\" ignored")
            }
        }
    }

    func mimeTypes(_ value: Any, _ key: String) throws(ConfigFileError) -> [String: String] {
        var result: [String: String] = [:]
        if let array = value as? [Any] {
            // Legacy form: [{"contentType": "text/css", "pathExtensions": ["css"]}].
            for (offset, element) in array.enumerated() {
                let path = "\(key)[\(offset)]"
                let entry = try dictionary(element, path)
                guard let type = entry["contentType"] else { throw fail(path, "needs \"contentType\"") }
                let contentType = try string(type, "\(path).contentType")
                for ext in try strings(entry["pathExtensions"] ?? [Any](), "\(path).pathExtensions") {
                    result[Self.normalized(ext)] = contentType
                }
            }
            return result
        }
        let object = try dictionary(value, key, expectation: "must be an object of extension to type (or the legacy array)")
        for (ext, type) in object {
            let contentType = try string(type, "\(key).\(ext)")
            guard !ext.isEmpty, !contentType.isEmpty else { throw fail("\(key).\(ext)", "must be a non-empty type for a non-empty extension") }
            result[Self.normalized(ext)] = contentType
        }
        return result
    }

    func errorPages(_ value: Any, _ key: String) throws(ConfigFileError) -> ServerSettings.ErrorPagesSetting {
        if Self.isBool(value) { return try bool(value, key) ? .generated : .off }
        let object = try dictionary(value, key, expectation: "must be true, false or an object of status code to file")
        var pages: [Int: String] = [:]
        for (code, file) in object {
            guard let status = Int(code), (400...599).contains(status) else {
                throw fail("\(key).\(code)", "is not a status code from 400 to 599")
            }
            let path = try string(file, "\(key).\(code)")
            guard !path.isEmpty else { throw fail("\(key).\(code)", "must not be empty") }
            pages[status] = path
        }
        return .files(pages)
    }

    // MARK: Values

    static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    func bool(_ value: Any, _ key: String) throws(ConfigFileError) -> Bool {
        guard Self.isBool(value), let number = value as? NSNumber else { throw fail(key, "must be true or false") }
        return number.boolValue
    }

    func string(_ value: Any, _ key: String) throws(ConfigFileError) -> String {
        guard let text = value as? String else { throw fail(key, "must be a string") }
        return text
    }

    func strings(_ value: Any, _ key: String) throws(ConfigFileError) -> [String] {
        guard let array = value as? [Any], let texts = array as? [String] else {
            throw fail(key, "must be an array of strings")
        }
        return texts
    }

    func dictionary(_ value: Any, _ key: String, expectation: String = "must be an object") throws(ConfigFileError) -> [String: Any] {
        guard let object = value as? [String: Any] else { throw fail(key, expectation) }
        return object
    }

    func number(_ value: Any, _ key: String, expectation: String) throws(ConfigFileError) -> Double {
        guard !Self.isBool(value), let number = value as? NSNumber else { throw fail(key, expectation) }
        return number.doubleValue
    }

    func integer(_ value: Any, _ key: String, in range: ClosedRange<Int>) throws(ConfigFileError) -> Int {
        let expectation = "must be an integer from \(range.lowerBound) to \(range.upperBound)"
        let double = try number(value, key, expectation: expectation)
        guard let integer = Int(exactly: double), range.contains(integer) else { throw fail(key, expectation) }
        return integer
    }

    /// Seconds as a number; `null` (and `0`, when `zeroMeansOff`) turns the limit off.
    func seconds(_ value: Any, _ key: String, zeroMeansOff: Bool = true) throws(ConfigFileError) -> Duration? {
        if value is NSNull { return nil }
        let expectation = zeroMeansOff
            ? "must be a number of seconds (0 or null turns it off)"
            : "must be a number of seconds, 0 or more (null waits indefinitely)"
        let seconds = try number(value, key, expectation: expectation)
        guard seconds.isFinite, seconds >= 0, seconds <= 86_400 * 365 else { throw fail(key, expectation) }
        if seconds == 0, zeroMeansOff { return nil }
        return .milliseconds(max(Int64((seconds * 1000).rounded()), seconds > 0 ? 1 : 0))
    }

    static func normalized(_ ext: String) -> String {
        (ext.hasPrefix(".") ? String(ext.dropFirst()) : ext).lowercased()
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
