#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import AccessLog
import Foundation

// The `accessLog` key (#0125): the `AccessLog` component (#0090) and its optional
// `MetricsEndpoint`, outermost in the chain so every final status is recorded.

extension ServerSettings {
    /// The `accessLog` key.
    public struct AccessLogSettings: Sendable, Equatable {
        /// Where lines go.
        public enum Output: Sendable, Equatable {
            /// A file (relative to ``ServerSettings/baseDirectory``), opened for appending and
            /// created with mode 0644 if missing.
            case file(String)
            /// `"stdout"`.
            case standardOutput
            /// `"stderr"`.
            case standardError
        }

        /// Line format; the names are the file's values.
        public enum Format: String, Sendable, Hashable, CaseIterable {
            case common, combined, json
        }

        /// Where lines go; `nil` writes no lines (metrics only). Default standard output.
        public var output: Output? = .standardOutput
        /// Default ``Format/common``.
        public var format = Format.common
        /// Path that serves the metrics in the Prometheus text format; `nil` (the default)
        /// serves none.
        public var metricsPath: String?
        /// Longest a line waits in a connection's buffer. Default 1 s.
        public var flushInterval: Duration = .seconds(1)

        public init() {}
    }

    /// The access log file path resolved against ``baseDirectory``, when the log goes to a file.
    public var resolvedAccessLogPath: String? {
        guard case .file(let path) = accessLog?.output else { return nil }
        return Self.resolve(path, against: baseDirectory)
    }

    /// The `AccessLog` and `MetricsEndpoint` for ``accessLog``, or `nil`s when it is off. A log
    /// file is opened once here, so a path that cannot be written stops startup with a message
    /// naming `accessLog.path` instead of failing after the listeners are bound.
    func makeAccessLog() throws(ConfigFileError) -> (AccessLog?, MetricsEndpoint?) {
        guard let settings = accessLog else { return (nil, nil) }
        let format: AccessLogFormat = switch settings.format {
        case .common: .common
        case .combined: .combined
        case .json: .json
        }
        let metrics = settings.metricsPath == nil ? nil : AccessLogMetrics()
        let destination: AccessLogDestination?
        switch settings.output {
        case nil: destination = nil
        case .standardOutput: destination = .standardOutput
        case .standardError: destination = .standardError
        case .file:
            let path = resolvedAccessLogPath!
            let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, mode_t(0o644))
            guard fd >= 0 else {
                let reason = String(cString: strerror(errno))
                throw ConfigFileError(key: "accessLog.path", "\"accessLog.path\": cannot open \(path): \(reason)")
            }
            close(fd)
            destination = .file(path: path)
        }
        let log: AccessLog
        if let destination {
            log = AccessLog(format: format, destination: destination, metrics: metrics,
                            options: AccessLogOptions(flushInterval: settings.flushInterval))
        } else if let metrics {
            log = AccessLog(metrics: metrics)
        } else {
            return (nil, nil)
        }
        let endpoint = settings.metricsPath.flatMap { path in metrics.map { MetricsEndpoint(metrics: $0, path: path) } }
        return (log, endpoint)
    }
}

extension Parser {
    /// `"accessLog": {"path": "logs/access.log" | "stdout" | "stderr" | null, "format":
    /// "common" | "combined" | "json", "metrics": "/metrics", "flushInterval": 1}`; a string
    /// alone is the path; `true` logs Common lines to standard output; `false`, `null` or
    /// `"enabled": false` turns it off.
    mutating func accessLog(_ value: Any, _ key: String) throws(ConfigFileError) -> ServerSettings.AccessLogSettings? {
        if value is NSNull { return nil }
        if Self.isBool(value) { return try bool(value, key) ? ServerSettings.AccessLogSettings() : nil }
        var result = ServerSettings.AccessLogSettings()
        if value is String {
            result.output = try accessLogOutput(value, key)
            return result
        }
        let object = try dictionary(value, key, expectation: "must be true, false, a path or an object")
        var enabled = true
        for name in object.keys.sorted() {
            let path = "\(key).\(name)"
            let element = object[name]!
            switch name {
            case "enabled":
                enabled = try bool(element, path)
            case "path":
                result.output = element is NSNull ? nil : try accessLogOutput(element, path)
            case "format":
                let text = try string(element, path)
                guard let format = ServerSettings.AccessLogSettings.Format(rawValue: text) else {
                    throw fail(path, "must be one of \(ServerSettings.AccessLogSettings.Format.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))")
                }
                result.format = format
            case "metrics":
                if element is NSNull {
                    result.metricsPath = nil
                } else if Self.isBool(element) {
                    result.metricsPath = try bool(element, path) ? "/metrics" : nil
                } else {
                    let text = try string(element, path)
                    guard text.hasPrefix("/"), !text.contains("?"), !text.contains("#") else {
                        throw fail(path, "must be a path starting with \"/\" (no query), true or false")
                    }
                    result.metricsPath = text
                }
            case "flushInterval":
                guard let interval = try seconds(element, path), interval > .zero else {
                    throw fail(path, "must be a positive number of seconds")
                }
                result.flushInterval = interval
            default:
                warn("unknown key \"\(path)\" ignored")
            }
        }
        guard enabled else { return nil }
        if result.output == nil, result.metricsPath == nil {
            throw fail("\(key).path", "is null and \"\(key).metrics\" is not set: nothing to record")
        }
        return result
    }

    func accessLogOutput(_ value: Any, _ key: String) throws(ConfigFileError) -> ServerSettings.AccessLogSettings.Output {
        let text = try string(value, key)
        switch text {
        case "": throw fail(key, "must be a file path, \"stdout\" or \"stderr\"")
        case "stdout": return .standardOutput
        case "stderr": return .standardError
        default: return .file(text)
        }
    }
}
