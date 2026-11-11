import HTTPCore

/// `Content-Type` by file extension: the legacy `Root/http-config.json` table plus common
/// types. Lookup compares the extension bytes case-insensitively against static strings, so
/// it allocates nothing. It runs only when a file enters the cache.
public enum MIMETypes {
    /// `(extension, content type)`; extensions are lowercase without the dot.
    public static let table: [(ext: StaticString, type: StaticString)] = [
        // The legacy table (Root/http-config.json), unchanged.
        ("html", "text/html"), ("htm", "text/html"),
        ("css", "text/css"),
        ("js", "text/javascript"),
        ("jpg", "image/jpeg"), ("jpeg", "image/jpeg"),
        ("png", "image/png"),
        ("gif", "image/gif"),
        ("svg", "image/svg+xml"),
        ("webp", "image/webp"),
        ("avif", "image/avif"),
        ("heic", "image/heic"),
        ("heif", "image/heif"),
        ("ico", "image/x-icon"),
        ("json", "application/json"),
        ("txt", "text/plain"),
        ("xml", "application/xml"),
        ("pdf", "application/pdf"),
        ("woff2", "font/woff2"),
        ("woff", "font/woff"),
        ("ttf", "font/ttf"),
        ("otf", "font/otf"),
        ("mp4", "video/mp4"),
        ("webm", "video/webm"),
        ("mp3", "audio/mpeg"),
        ("wav", "audio/wav"),
        ("ogg", "audio/ogg"),
        // Common additions.
        ("mjs", "text/javascript"),
        ("map", "application/json"),
        ("jsonld", "application/ld+json"),
        ("webmanifest", "application/manifest+json"),
        ("wasm", "application/wasm"),
        ("xhtml", "application/xhtml+xml"),
        ("rss", "application/rss+xml"),
        ("atom", "application/atom+xml"),
        ("csv", "text/csv"),
        ("md", "text/markdown"),
        ("ics", "text/calendar"),
        ("vtt", "text/vtt"),
        ("yaml", "application/yaml"), ("yml", "application/yaml"),
        ("apng", "image/apng"),
        ("bmp", "image/bmp"),
        ("tif", "image/tiff"), ("tiff", "image/tiff"),
        ("jxl", "image/jxl"),
        ("eot", "application/vnd.ms-fontobject"),
        ("m4a", "audio/mp4"),
        ("aac", "audio/aac"),
        ("flac", "audio/flac"),
        ("opus", "audio/ogg"),
        ("oga", "audio/ogg"),
        ("ogv", "video/ogg"),
        ("mov", "video/quicktime"),
        ("m4v", "video/mp4"),
        ("mpeg", "video/mpeg"), ("mpg", "video/mpeg"),
        ("ts", "video/mp2t"),
        ("m3u8", "application/vnd.apple.mpegurl"),
        ("zip", "application/zip"),
        ("gz", "application/gzip"),
        ("tar", "application/x-tar"),
        ("7z", "application/x-7z-compressed"),
        ("bz2", "application/x-bzip2"),
        ("xz", "application/x-xz"),
        ("epub", "application/epub+zip"),
        ("rtf", "application/rtf"),
        ("doc", "application/msword"),
        ("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
        ("xls", "application/vnd.ms-excel"),
        ("xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
        ("ppt", "application/vnd.ms-powerpoint"),
        ("pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
        ("dmg", "application/x-apple-diskimage"),
    ]

    /// The content type for `ext` (the bytes after the last `.`, any case), or `nil`.
    public static func lookup(extension ext: Span<UInt8>) -> StaticString? {
        guard ext.count > 0 else { return nil }
        for entry in table where entry.ext.utf8CodeUnitCount == ext.count {
            if ASCII.equalsCaseInsensitive(ext, entry.ext) { return entry.type }
        }
        return nil
    }

    /// The extension of the file name `name`: the bytes after its last `.`, or an empty range
    /// when there is none or the name starts with its only dot (`.profile`).
    static func extensionRange(of name: Span<UInt8>) -> Range<Int> {
        var i = name.count - 1
        while i > 0 {
            if name[i] == UInt8(ascii: ".") { return (i + 1)..<name.count }
            i -= 1
        }
        return name.count..<name.count
    }
}
