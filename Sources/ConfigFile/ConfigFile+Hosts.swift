#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import HTTPCore
import StaticFiles
import VirtualHosts

// The `hosts` key (#0092): several sites on one listener, each with its own root.

extension ServerSettings {
    /// One site of the `hosts` key.
    public struct HostSettings: Sendable, Equatable {
        /// Host names (`example.com`, `*.example.com`); matched without the port,
        /// case-insensitively. Punycode for internationalized names.
        public var names: [String]
        /// The site's root, relative to ``ServerSettings/baseDirectory``.
        public var root: String
        /// The site that answers unknown hosts and requests without one. At most one.
        public var isDefault: Bool

        public init(names: [String], root: String, isDefault: Bool = false) {
            self.names = names
            self.root = root
            self.isDefault = isDefault
        }
    }

    /// The `VirtualHosts` for ``hosts``: each site is `StaticFiles` over its own root with the
    /// shared file settings. Unknown hosts get the default site or `421`.
    func makeVirtualHosts() throws(ConfigFileError) -> VirtualHosts {
        var sites: [VirtualHost] = []
        for (offset, host) in hosts.enumerated() {
            let root = Self.resolve(host.root, against: baseDirectory)
            let key = "hosts[\(offset)].root"
            let files: StaticFiles
            do {
                files = try StaticFiles(root: root, configuration: staticFilesConfiguration)
            } catch {
                switch error {
                case .rootUnavailable(let code):
                    throw ConfigFileError(key: key, "cannot serve \(key) \(root): \(String(cString: strerror(code)))")
                case .rootNotADirectory:
                    throw ConfigFileError(key: key, "cannot serve \(key) \(root): not a directory")
                }
            }
            sites.append(VirtualHost(host.names, isDefault: host.isDefault, handler: files))
        }
        do {
            return try VirtualHosts(sites)
        } catch {
            throw ConfigFileError(key: "hosts", "\"hosts\": \(error)")
        }
    }
}

extension Parser {
    /// `"hosts": [{"names": ["a.test", "*.a.test"], "root": "sites/a", "default": true}]`;
    /// `"name": "a.test"` is accepted for a single name.
    mutating func hosts(_ value: Any, _ key: String) throws(ConfigFileError) -> [ServerSettings.HostSettings] {
        guard let array = value as? [Any] else { throw fail(key, "must be an array of {\"names\", \"root\"} objects") }
        var result: [ServerSettings.HostSettings] = []
        for (offset, element) in array.enumerated() {
            let path = "\(key)[\(offset)]"
            let object = try dictionary(element, path)
            var names: [String] = []
            var root: String?
            var isDefault = false
            for name in object.keys.sorted() {
                let field = "\(path).\(name)"
                let item = object[name]!
                switch name {
                case "names": names += try strings(item, field)
                case "name": names.append(try string(item, field))
                case "root":
                    let text = try string(item, field)
                    guard !text.isEmpty else { throw fail(field, "must not be empty") }
                    root = text
                case "default": isDefault = try bool(item, field)
                default: warn("unknown key \"\(field)\" ignored")
                }
            }
            guard let root else { throw fail("\(path).root", "must be set to the site's directory") }
            guard !names.isEmpty || isDefault else { throw fail("\(path).names", "must list at least one host name (or set \"default\": true)") }
            result.append(ServerSettings.HostSettings(names: names, root: root, isDefault: isDefault))
        }
        if result.filter(\.isDefault).count > 1 { throw fail(key, "may have only one \"default\": true site") }
        // Check the names now, so a bad one fails the file like any other bad value.
        do {
            _ = try VirtualHosts(result.map { VirtualHost($0.names, isDefault: $0.isDefault, handler: NotFoundHandler()) })
        } catch {
            throw fail(key, "is invalid: \(error)")
        }
        return result
    }
}
