import Foundation
import Synchronization

/// The local test identity created by `scripts/make-test-identity.sh` (#0072): a self-signed
/// `localhost` / `127.0.0.1` / `::1` certificate and a PKCS#12 bundle in the gitignored
/// `.test-identity/` folder at the repository root.
///
/// ``load()`` runs the script when the identity is missing, so TLS and QUIC tests work on a
/// fresh checkout. It only reads bytes: callers import them in memory
/// (`TLSIdentity(pkcs12:password:)` in NetworkTransport uses `kSecImportToMemoryOnly`).
/// Nothing here touches the keychain or trust settings (AGENTS.md).
public enum TestIdentity {
    /// The fixed password of `server.p12`.
    public static let password = "sws-test-password"

    /// The files of the identity.
    public struct Material: Sendable {
        /// `server.p12`: the PKCS#12 identity, encrypted with ``TestIdentity/password``.
        public var pkcs12: [UInt8]
        /// `cert.der`: the certificate, for pinning in test clients.
        public var certificateDER: [UInt8]
        /// The folder the files were read from.
        public var directory: String
    }

    /// Why the identity is unavailable.
    public enum Failure: Error, Sendable, CustomStringConvertible {
        case scriptFailed(status: Int32, output: String)
        case missingFile(String)

        public var description: String {
            switch self {
            case .scriptFailed(let status, let output):
                "scripts/make-test-identity.sh exited \(status): \(output)"
            case .missingFile(let path):
                "test identity file missing after running scripts/make-test-identity.sh: \(path)"
            }
        }
    }

    /// The repository root, derived from this source file's location.
    public static var repositoryRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HTTPTestSupport
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repository root
            .path
    }

    /// `<repository root>/.test-identity`.
    public static var directory: String { repositoryRoot + "/.test-identity" }

    private static let cache = Mutex<Material?>(nil)

    /// Returns the identity files, generating them first if they are missing. The result is
    /// cached for the process; concurrent callers in one process run the script at most once.
    public static func load() throws(Failure) -> Material {
        try cache.withLock { cached throws(Failure) -> Material in
            if let cached { return cached }
            let material = try loadOrGenerate()
            cached = material
            return material
        }
    }

    private static func loadOrGenerate() throws(Failure) -> Material {
        let p12Path = directory + "/server.p12"
        let derPath = directory + "/cert.der"
        if !FileManager.default.fileExists(atPath: p12Path) || !FileManager.default.fileExists(atPath: derPath) {
            try runScript()
        }
        guard let p12 = FileManager.default.contents(atPath: p12Path) else { throw .missingFile(p12Path) }
        guard let der = FileManager.default.contents(atPath: derPath) else { throw .missingFile(derPath) }
        return Material(pkcs12: [UInt8](p12), certificateDER: [UInt8](der), directory: directory)
    }

    /// Runs the (idempotent, atomic) script. It only invokes openssl on files.
    private static func runScript() throws(Failure) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [repositoryRoot + "/scripts/make-test-identity.sh"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw .scriptFailed(status: -1, output: "\(error)")
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw .scriptFailed(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
        }
    }
}
