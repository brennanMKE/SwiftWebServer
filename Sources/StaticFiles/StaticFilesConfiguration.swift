public import Compression

/// Settings for ``StaticFiles`` (#0084). Immutable once the component is created.
public struct StaticFilesConfiguration: Sendable {
    /// What to do with symbolic links found while resolving a request path (#0014).
    public enum SymlinkPolicy: Sendable, Hashable {
        /// Follow links whose target stays inside the root; a link that resolves outside the
        /// root answers `403`. The default.
        case followWithinRoot
        /// Refuse any path that goes through a symbolic link (`403`), even one inside the root.
        case deny
        /// Follow every link, even out of the root. Only for trees whose links are trusted.
        case followAnywhere
    }

    /// File names tried, in order, for a request that names a directory (with a trailing `/`).
    public var indexFiles: [String] = ["index.html"]

    /// Path components that answer `403` wherever they appear in the path, compared
    /// case-insensitively (macOS volumes usually are) (#0013).
    public var blockedNames: [String] = ["http-config.json", ".git", ".DS_Store"]

    /// Refuse every component that starts with `.` (`403`), except `.well-known` (RFC 8615).
    public var blockDotfiles = true

    /// See ``SymlinkPolicy``.
    public var symlinkPolicy = SymlinkPolicy.followWithinRoot

    /// `Content-Type` for an extension the table does not know.
    public var defaultMIMEType = "application/octet-stream"

    /// Extra or overriding `Content-Type`s keyed by extension without the dot (any case),
    /// such as `["md": "text/markdown; charset=utf-8"]`. Checked before the built-in table.
    public var mimeTypes: [String: String] = [:]

    /// A `Cache-Control` value added to every file response and every `304`, such as
    /// `public, max-age=3600`; `nil` sends none (unless ``maxAge`` is set). Takes precedence
    /// over ``maxAge``.
    public var cacheControl: String?

    /// Freshness lifetime in seconds: when set and ``cacheControl`` is `nil`, file responses
    /// and `304`s carry `Cache-Control: public, max-age=<maxAge>` (the legacy `caching.maxAge`
    /// setting). `nil` (the default) sends none.
    public var maxAge: Int?

    /// The `Cache-Control` value sent: ``cacheControl``, else one built from ``maxAge``.
    public var effectiveCacheControl: String? {
        if let cacheControl { return cacheControl }
        if let maxAge { return "public, max-age=\(Swift.max(maxAge, 0))" }
        return nil
    }

    /// Files up to this size are read once into memory and served from the cache with
    /// pre-rendered headers; larger files are sent from an open descriptor with
    /// `HTTPResponseBody.file`.
    public var smallFileLimit = 64 * 1024

    /// Most resolved paths kept in the cache. Each holds either up to ``smallFileLimit``
    /// bytes or one open file descriptor. `0` turns the cache off.
    public var maxCachedEntries = 1024

    /// How long a cached entry is served before the next request for it re-checks the file
    /// with `realpath` and `stat`. Changes on disk are visible after at most this long.
    public var revalidationInterval = Duration.seconds(1)

    /// Encoded variants served from the cache (#0091); `nil` (the default) serves files as
    /// they are. When set, a cached file whose type is in
    /// ``CompressionConfiguration/mimeTypes`` gets its encoded variants built once, when it
    /// enters the cache: from a sidecar (``precompressedSidecars``) or, for files held in
    /// memory (≤ ``smallFileLimit``) of at least ``CompressionConfiguration/minimumSize``
    /// bytes, compressed at ``CompressionConfiguration/precompressionLevel``. Requests are
    /// negotiated on `Accept-Encoding` and answered with the stored variant, so a hit costs
    /// no compression. Variants carry `Content-Encoding`, `Vary: Accept-Encoding` and a
    /// suffixed strong `ETag` (`"…-br"`, `"…-gz"`, `"…-df"`) that conditional requests are
    /// evaluated against. Large files without sidecars are left to the `Compression`
    /// middleware, which streams them.
    public var compression: CompressionConfiguration?

    /// With ``compression`` set: serve `name.br` and `name.gz` found next to a file as its
    /// `br` and `gzip` variants (any size; read into memory up to ``smallFileLimit``, else
    /// sent from the open file). A sidecar must be a regular file (not a link) at least as
    /// new as the file it encodes; an older one is ignored. Sidecars are looked up when the
    /// file enters the cache, so replacing only a sidecar is seen once the file itself
    /// changes or its entry is evicted. Default true.
    public var precompressedSidecars = true

    public init() {}
}
