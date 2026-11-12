public import Compression

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
    /// ``tls``. In the file: `"http3": {"enabled": true, "port": 8443, "altSvcMaxAge": 86400,
    /// "qpackMaxTableCapacity": 4096, "qpackBlockedStreams": 16}`.
    public var http3: HTTP3Settings?
    /// HTTP/2 (#0119). On by default: TLS listeners offer `h2` and `http/1.1` via ALPN.
    /// `nil` (`"http2": false`) serves HTTP/1.1 only. Cleartext h2c is a separate opt-in
    /// (``HTTP2Settings/cleartext``). In the file:
    /// `"http2": {"enabled": true, "cleartext": false, "maxConcurrentStreams": 100, …}`.
    public var http2: HTTP2Settings? = HTTP2Settings()
    /// Response compression (#0091). `nil` (the default) compresses nothing. In the file:
    /// `"compression": true`, or an object (see ``CompressionSettings``). The legacy
    /// `"enableCompression": true` is the same as `"compression": true`.
    public var compression: CompressionSettings?

    /// The `Compression` component and precompressed static files.
    public struct CompressionSettings: Sendable, Equatable {
        /// Codings, minimum size, MIME types and levels.
        public var configuration = CompressionConfiguration()
        /// Cache encoded variants of small static files (compressed once). Default true.
        public var precompress = true
        /// Serve `file.br` / `file.gz` sidecars as variants. Default true.
        public var sidecars = true

        public init() {}
    }

    /// Virtual hosts (#0092): sites selected by `Host`, each with its own root. Empty (the
    /// default) serves ``root`` for every host. In the file:
    /// `"hosts": [{"names": ["a.test"], "root": "sites/a"}, {"default": true, "root": "Public"}]`.
    public var hosts: [HostSettings] = []

    /// Authentication (#0093): Basic and bearer tokens for path prefixes. Empty (the default)
    /// registers no `Authenticator`. In the file:
    /// `"auth": [{"paths": ["/admin"], "realm": "Admin", "basic": {"file": "users.htpasswd"}}]`.
    public var auth: [AuthSettings] = []

    /// Reverse-proxy mounts (#0124), after auth and before the static files. In the file:
    /// `"proxy": [{"path": "/api", "upstream": "http://127.0.0.1:9000"}]`. Sites of ``hosts``
    /// can have their own (`hosts[].proxy`), tried before these.
    public var proxy: [ProxySettings] = []

    /// The access log (#0125): `AccessLog` outermost in the chain, so it records the final
    /// status of every response. `nil` (the default) logs nothing. In the file:
    /// `"accessLog": {"path": "logs/access.log", "format": "combined", "metrics": "/metrics"}`.
    public var accessLog: AccessLogSettings?

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
        /// QPACK dynamic table capacity offered to clients' encoders, in bytes (#0106,
        /// `SETTINGS_QPACK_MAX_TABLE_CAPACITY`). 0 (the default) decodes with the static table
        /// only.
        public var qpackMaxTableCapacity: Int = 0
        /// Request streams that may wait for QPACK inserts at once
        /// (`SETTINGS_QPACK_BLOCKED_STREAMS`). Default 0; only used with a table capacity.
        public var qpackBlockedStreams: Int = 0

        public init(port: UInt16? = nil, altSvcMaxAge: Int = 86_400,
                    qpackMaxTableCapacity: Int = 0, qpackBlockedStreams: Int = 0) {
            self.port = port
            self.altSvcMaxAge = altSvcMaxAge
            self.qpackMaxTableCapacity = qpackMaxTableCapacity
            self.qpackBlockedStreams = qpackBlockedStreams
        }
    }

    /// HTTP/2 settings (#0119). Plain values: the executable turns them into the `HTTP2`
    /// target's `HTTP2Configuration`, so this target does not link HTTP/2.
    public struct HTTP2Settings: Sendable, Equatable {
        /// Serve cleartext connections that start with the HTTP/2 preface (prior knowledge,
        /// RFC 9113 §3.3). Default false: the cleartext listener then speaks only HTTP/1.1 and
        /// reads no bytes ahead to choose a protocol. Turning it on routes every cleartext
        /// connection through protocol sniffing and a replay wrapper.
        public var cleartext = false
        /// `SETTINGS_MAX_CONCURRENT_STREAMS`. Default 100.
        public var maxConcurrentStreams = 100
        /// `SETTINGS_INITIAL_WINDOW_SIZE`, each stream's receive window. Default 65,535.
        public var initialWindowSize = 65_535
        /// Largest request body on HTTP/2; `nil` (the default) uses ``ServerSettings/maxBodySize``.
        public var maxRequestBodySize: Int?
        /// Overrides of the HTTP/2 abuse limits (#0056); unset fields keep the defaults.
        public var abuseLimits = AbuseLimitOverrides()

        public static let maxSupportedConcurrentStreams = 1 << 16
        public static let maxWindowSize = Int(Int32.max)

        public init() {}
    }

    /// `http2.abuseLimits`: each field `nil` keeps the `HTTP2AbuseLimits` default; for the
    /// optional limits, `.some(nil)` (JSON `null`) turns the limit off.
    public struct AbuseLimitOverrides: Sendable, Equatable {
        /// Rate window. Default 10 s.
        public var window: Duration?
        /// Default 100.
        public var maxResetStreamsPerWindow: Int??
        /// Default 1,000.
        public var maxControlFramesPerWindow: Int??
        /// Default 100.
        public var maxEmptyFramesPerWindow: Int??
        /// Default 10,000.
        public var maxWindowUpdatesPerWindow: Int??
        /// Default 1,000.
        public var maxSmallDataFramesPerWindow: Int??
        /// Default 256 bytes.
        public var smallDataFrameSize: Int?
        /// Default 30 s.
        public var windowStallTimeout: Duration??
        /// Default 100,000.
        public var maxStreamsPerConnection: Int??

        public init() {}
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
