#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import HTTPCore

/// What identifies one version of a file: when any of these change, cached bytes, headers
/// and the ETag are stale.
struct FileIdentity: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    var size: Int64
    var mtimeSeconds: Int64
    var mtimeNanoseconds: Int64

    init(_ info: stat) {
        device = UInt64(truncatingIfNeeded: info.st_dev)
        inode = UInt64(truncatingIfNeeded: info.st_ino)
        size = Int64(info.st_size)
        #if canImport(Darwin)
        mtimeSeconds = Int64(info.st_mtimespec.tv_sec)
        mtimeNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        #else
        mtimeSeconds = Int64(info.st_mtim.tv_sec)
        mtimeNanoseconds = Int64(info.st_mtim.tv_nsec)
        #endif
    }

    /// Modification time in nanoseconds since the epoch (clamped at zero).
    var mtimeTotalNanoseconds: UInt64 {
        let (product, overflow) = UInt64(clamping: mtimeSeconds).multipliedReportingOverflow(by: 1_000_000_000)
        return overflow ? .max : product &+ UInt64(clamping: mtimeNanoseconds)
    }
}

/// Where a request path leads.
enum Resolution: Equatable {
    /// A regular file at the canonical `path`; `name` (the requested or index file name) picks
    /// the content type.
    case file(path: [UInt8], name: [UInt8], identity: FileIdentity)
    /// A directory requested without its trailing `/`: `301` to `location`.
    case redirect(location: [UInt8])
    case notFound
    case forbidden
    case badRequest
}

/// Maps request paths to files under a canonical root (#0014, #0015). Cold path: runs when
/// a path is not cached and once per revalidation interval for a cached one, and may
/// allocate.
struct PathResolver: Sendable {
    /// `realpath` of the root, without a trailing `/` (except for `/` itself).
    let root: [UInt8]
    let blockList: BlockList
    let symlinkPolicy: StaticFilesConfiguration.SymlinkPolicy
    let indexFiles: [[UInt8]]

    init(root: [UInt8], configuration: StaticFilesConfiguration) {
        self.root = root
        blockList = BlockList(names: configuration.blockedNames, blockDotfiles: configuration.blockDotfiles)
        symlinkPolicy = configuration.symlinkPolicy
        indexFiles = configuration.indexFiles.map { Array($0.utf8) }
    }

    func resolve(path raw: Span<UInt8>, query: Span<UInt8>) -> Resolution {
        let decoded: DecodedPath
        do {
            decoded = try DecodedPath.decode(raw, blockList: blockList)
        } catch .malformed {
            return .badRequest
        } catch {
            return .forbidden
        }
        var lexical = root
        if !decoded.relative.isEmpty {
            if lexical != [UInt8(ascii: "/")] { lexical.append(UInt8(ascii: "/")) }
            lexical.append(contentsOf: decoded.relative)
        }
        let target: (real: [UInt8], info: stat)
        switch check(lexical) {
        case .found(let real, let info): target = (real, info)
        case .refused(let resolution): return resolution
        }
        switch target.info.st_mode & S_IFMT {
        case S_IFREG:
            // `/file.txt/` names a directory that does not exist.
            if decoded.trailingSlash { return .notFound }
            return .file(path: target.real, name: Array(decoded.lastComponent), identity: FileIdentity(target.info))
        case S_IFDIR:
            guard decoded.trailingSlash else {
                return .redirect(location: decoded.redirectLocation(query: query))
            }
            for index in indexFiles {
                var candidate = lexical
                if candidate.last != UInt8(ascii: "/") { candidate.append(UInt8(ascii: "/")) }
                candidate.append(contentsOf: index)
                switch check(candidate) {
                case .found(let real, let info) where info.st_mode & S_IFMT == S_IFREG:
                    return .file(path: real, name: index, identity: FileIdentity(info))
                case .found, .refused(.notFound):
                    continue
                case .refused(let resolution):
                    return resolution
                }
            }
            return .notFound
        default:
            return .notFound
        }
    }

    enum Checked {
        case found(real: [UInt8], info: stat)
        case refused(Resolution)
    }

    /// Canonicalizes `lexical` with `realpath`, applies the symlink policy, containment and
    /// the block list to the canonical path, and `stat`s it.
    func check(_ lexical: [UInt8]) -> Checked {
        if symlinkPolicy == .deny, let refusal = firstSymlink(in: lexical) { return .refused(refusal) }
        guard let real = Self.realPath(lexical) else { return .refused(errno == EACCES ? .forbidden : .notFound) }
        if let relative = relativeToRoot(real) {
            let allowed = relative.withUnsafeBufferPointer { blockList.allows(path: $0.span) }
            guard allowed else { return .refused(.forbidden) }
        } else if symlinkPolicy != .followAnywhere {
            return .refused(.forbidden)
        }
        var info = stat()
        let status = Self.withCString(real) { stat($0, &info) }
        guard status == 0 else { return .refused(errno == EACCES ? .forbidden : .notFound) }
        return .found(real: real, info: info)
    }

    /// The part of `real` after the root and its `/`, or `nil` when `real` is outside it.
    func relativeToRoot(_ real: [UInt8]) -> ArraySlice<UInt8>? {
        if root == [UInt8(ascii: "/")] {
            return real.first == UInt8(ascii: "/") ? real.dropFirst() : nil
        }
        guard real.count >= root.count, real[..<root.count].elementsEqual(root) else { return nil }
        if real.count == root.count { return real[real.count...] }
        guard real[root.count] == UInt8(ascii: "/") else { return nil }   // `/srv/public2` is not in `/srv/public`
        return real[(root.count + 1)...]
    }

    /// `.forbidden` when a component of `lexical` below the root is a symbolic link,
    /// `.notFound` when one is missing, `nil` when there are no links.
    func firstSymlink(in lexical: [UInt8]) -> Resolution? {
        var end = root.count + 1
        while end <= lexical.count {
            if end == lexical.count || lexical[end] == UInt8(ascii: "/") {
                var info = stat()
                let status = Self.withCString(Array(lexical[..<end])) { lstat($0, &info) }
                if status != 0 { return errno == EACCES ? .forbidden : .notFound }
                if info.st_mode & S_IFMT == S_IFLNK { return .forbidden }
            }
            end += 1
        }
        return nil
    }

    /// `realpath(3)` of `path`, or `nil` with `errno` set.
    static func realPath(_ path: [UInt8]) -> [UInt8]? {
        var output = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let resolved = withCString(path) { input in
            output.withUnsafeMutableBufferPointer { realpath(input, $0.baseAddress) != nil }
        }
        guard resolved else { return nil }
        let length = output.firstIndex(of: 0) ?? output.count
        return output[..<length].map { UInt8(bitPattern: $0) }
    }

    /// Calls `body` with `path` as a NUL-terminated C string. `path` never contains NUL:
    /// decoding rejects it.
    static func withCString<R>(_ path: [UInt8], _ body: (UnsafePointer<CChar>) -> R) -> R {
        var terminated = path
        terminated.append(0)
        return terminated.withUnsafeBufferPointer { bytes in
            bytes.withMemoryRebound(to: CChar.self) { body($0.baseAddress!) }
        }
    }
}
