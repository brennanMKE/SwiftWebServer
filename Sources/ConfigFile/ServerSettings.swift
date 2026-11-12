/// The server's settings, as read from `http-config.json` (#0086, legacy #0023).
///
/// Every key of the file is optional: a missing key keeps the default documented on its
/// property here, so `{}` (or no file at all) is a working configuration. The README's
/// configuration reference lists the same keys and defaults.
///
/// The settings are plain values. ``ConfigFile`` parses them, the command line overrides
/// them, and the `+Components` extension turns them into the server's configuration values
/// and its middleware chain, registering only the components that are enabled.
public struct ServerSettings: Sendable, Equatable {
    /// Cleartext TCP transport (#0113).
    public enum Transport: String, Sendable, Hashable, CaseIterable {
        /// POSIX sockets and kqueue (`BSDSocketListener`). The default.
        case bsd
        /// Network.framework (`TCPListener`).
        case nw
    }

    /// HTTP/1.1 connection time limits (#0082); `nil` turns a limit off. Seconds in the file.
    public struct Timeouts: Sendable, Equatable {
        /// A request head must be complete this long after its first byte (`408`). Default 10 s.
        public var header: Duration? = .seconds(10)
        /// An idle keep-alive connection is closed after this long. Default 5 s. The legacy
        /// `keepAliveTimeout` key sets this.
        public var idle: Duration? = .seconds(5)
        /// Longest wait for request body bytes (`408`). Default 30 s.
        public var body: Duration? = .seconds(30)
        /// Longest wait for the client to accept response bytes. Default 30 s.
        public var send: Duration? = .seconds(30)
        /// Lingering close after an error response. Default 2 s.
        public var linger: Duration? = .seconds(2)

        public init() {}
    }

    /// What `4xx`/`5xx` responses without a body get (`ErrorPages`, #0085).
    public enum ErrorPagesSetting: Sendable, Equatable {
        /// No error pages: such responses keep their empty body.
        case off
        /// A small generated HTML page. The default.
        case generated
        /// Pages from files: status code to a path relative to ``ServerSettings/root``;
        /// statuses without a file get the generated page.
        case files([Int: String])
    }

    /// Numeric address to bind. Default `127.0.0.1` (loopback only); use `0.0.0.0` or `::`
    /// to serve the network.
    public var host = "127.0.0.1"
    /// TCP port. Default 8080; 0 picks a free port.
    public var port: UInt16 = 8080
    /// Directory whose files are served. Relative paths resolve against
    /// ``baseDirectory``. Default `Public`. The legacy key `path` is an alias.
    public var root = "Public"
    /// Directory that relative paths in the settings resolve against: the directory holding
    /// the config file, or the working directory when there is none. Not a key of the file.
    public var baseDirectory = "."
    /// Index files tried, in order, for a directory request. Default `["index.html"]`.
    /// A single string is accepted; the legacy key `defaultIndex` is an alias.
    public var index = ["index.html"]
    /// Extra or overriding MIME types, extension (no dot) to `Content-Type`, checked before the
    /// built-in table. Default none. The legacy array form
    /// `[{"contentType": …, "pathExtensions": […]}]` is accepted too.
    public var mimeTypes: [String: String] = [:]
    /// `Content-Type` for unknown extensions. Default `application/octet-stream`.
    public var defaultMimeType = "application/octet-stream"
    /// Path components answered with `403` wherever they appear, case-insensitively.
    /// Default `["http-config.json", ".git", ".DS_Store"]`.
    public var blockList = ["http-config.json", ".git", ".DS_Store"]
    /// Refuse every path component starting with `.` (except `.well-known`). Default true.
    public var blockDotfiles = true
    /// `Cache-Control: public, max-age=N` on file responses and `304`s; `nil` sends none.
    /// Default 3600. In the file: `"caching": {"enabled": true, "maxAge": 3600}`.
    public var maxAge: Int? = 3600
    /// Most connections served at once; more wait in the listen backlog. Default 1024.
    public var maxConnections = 1024
    /// Graceful-shutdown grace period for open connections; `nil` waits indefinitely.
    /// Default 10 s.
    public var drainTimeout: Duration? = .seconds(10)
    /// See ``Timeouts``.
    public var timeouts = Timeouts()
    /// Largest request body accepted; larger gets `413`. Default 10 MiB. The legacy key
    /// `maxRequestSize` is an alias.
    public var maxBodySize = 10 * 1024 * 1024
    /// Cleartext transport. Default ``Transport/bsd``.
    public var transport = Transport.bsd
    /// See ``ErrorPagesSetting``. Default ``ErrorPagesSetting/generated``. In the file:
    /// `true`, `false`, or `{"404": "errors/404.html"}`.
    public var errorPages = ErrorPagesSetting.generated

    /// The TLS listener (#0089). `nil` (the default) serves cleartext only. In the file:
    /// `"tls": {"identity": "server.p12", "password": "…", "port": 8443}`.
    public var tls: TLSSettings?
    /// The HTTP/3 (QUIC) listener (#0089, #0103). `nil` (the default) serves no HTTP/3. Needs
    /// ``tls``. In the file: `"http3": {"enabled": true, "port": 8443, "altSvcMaxAge": 86400}`.
    public var http3: HTTP3Settings?

    /// Virtual hosts (#0092): sites selected by `Host`, each with its own root. Empty (the
    /// default) serves ``root`` for every host. In the file:
    /// `"hosts": [{"names": ["a.test"], "root": "sites/a"}, {"default": true, "root": "Public"}]`.
    public var hosts: [HostSettings] = []

    /// Authentication (#0093): Basic and bearer tokens for path prefixes. Empty (the default)
    /// registers no `Authenticator`. In the file:
    /// `"auth": [{"paths": ["/admin"], "realm": "Admin", "basic": {"file": "users.htpasswd"}}]`.
    public var auth: [AuthSettings] = []

    /// The TLS listener's identity and port.
    public struct TLSSettings: Sendable, Equatable {
        /// Where the PKCS#12 password comes from.
        public enum Password: Sendable, Equatable {
            /// The password itself (`"password"`).
            case literal(String)
            /// The name of an environment variable holding it (`"passwordEnv"`).
            case environment(String)
        }

        /// PKCS#12 identity file (certificate and private key), relative to
        /// ``ServerSettings/baseDirectory``. Loaded in memory only; never added to a keychain.
        public var identity: String
        /// The identity's password.
        public var password: Password
        /// TCP port of the TLS listener. Default 8443; 0 picks a free one.
        public var port: UInt16 = 8443

        public init(identity: String, password: Password, port: UInt16 = 8443) {
            self.identity = identity
            self.password = password
            self.port = port
        }
    }

    /// The HTTP/3 listener's port and its `Alt-Svc` advertisement.
    public struct HTTP3Settings: Sendable, Equatable {
        /// UDP port of the QUIC listener; `nil` (the default) is the TLS listener's port number,
        /// including the one picked when the TLS port is 0.
        public var port: UInt16?
        /// `ma` of the `Alt-Svc` header sent on TLS responses, in seconds. Default 86400.
        public var altSvcMaxAge: Int = 86_400

        public init(port: UInt16? = nil, altSvcMaxAge: Int = 86_400) {
            self.port = port
            self.altSvcMaxAge = altSvcMaxAge
        }
    }

    public init() {}

    /// The TLS identity path resolved against ``baseDirectory``.
    public var resolvedIdentityPath: String? {
        tls.map { Self.resolve($0.identity, against: baseDirectory) }
    }

    /// The TLS identity's password, reading `environment` for `passwordEnv`. Throws when the
    /// variable is not set.
    public func tlsPassword(environment: [String: String]) throws(ConfigFileError) -> String? {
        guard let tls else { return nil }
        switch tls.password {
        case .literal(let password):
            return password
        case .environment(let name):
            guard let password = environment[name] else {
                throw ConfigFileError(key: "tls.passwordEnv", "\"tls.passwordEnv\": environment variable \(name) is not set")
            }
            return password
        }
    }

    /// Checks the settings as a whole, after command-line overrides: HTTP/3 needs TLS, and the
    /// cleartext and TLS listeners (both TCP) need different ports.
    public func validate() throws(ConfigFileError) {
        if http3 != nil, tls == nil {
            throw ConfigFileError(key: "http3", "\"http3\" needs \"tls\": HTTP/3 uses the TLS identity")
        }
        if let tls, tls.port != 0, tls.port == port {
            throw ConfigFileError(key: "tls.port", "\"tls.port\" \(tls.port) is the cleartext port too; both are TCP")
        }
    }

    /// ``root`` resolved against ``baseDirectory``.
    public var resolvedRoot: String {
        Self.resolve(root, against: baseDirectory)
    }

    /// `path` itself when absolute, else `base/path`.
    public static func resolve(_ path: String, against base: String) -> String {
        if path.hasPrefix("/") || base.isEmpty || base == "." { return path }
        return base.hasSuffix("/") ? base + path : base + "/" + path
    }
}
