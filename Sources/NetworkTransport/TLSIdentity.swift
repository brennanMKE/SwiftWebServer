import Foundation
import Security

/// A TLS server identity (certificate and private key) loaded from PKCS#12 **in memory only**
/// (#0072; reused by the TLS listener in #0087 and by ``QUICListener``).
///
/// `SecPKCS12Import` is always called with `kSecImportToMemoryOnly: true`. Without it, macOS
/// adds the key to the login keychain, and the first TLS signature then blocks on a
/// SecurityAgent prompt, so the handshake silently hangs (docs/spikes/quic-spike.md, gotcha 1;
/// AGENTS.md). Nothing here reads, adds or changes keychain items or trust settings.
public struct TLSIdentity: @unchecked Sendable {
    // @unchecked: SecIdentity is an immutable CoreFoundation object and safe to share.
    let secIdentity: SecIdentity
    /// The leaf certificate in DER form.
    public let certificateDER: [UInt8]

    /// Imports the first identity in a PKCS#12 bundle.
    public init(pkcs12 bytes: [UInt8], password: String) throws(TLSIdentityError) {
        var items: CFArray?
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecImportToMemoryOnly as String: true,
        ]
        let status = SecPKCS12Import(Data(bytes) as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw .importFailed(status: status) }
        guard let array = items as? [[String: Any]],
              let value = array.first?[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID()
        else { throw .noIdentity }
        let identity = value as! SecIdentity   // checked by the type ID above
        var certificate: SecCertificate?
        let copyStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard copyStatus == errSecSuccess, let certificate else { throw .importFailed(status: copyStatus) }
        self.secIdentity = identity
        self.certificateDER = [UInt8](SecCertificateCopyData(certificate) as Data)
    }

    /// Reads and imports a PKCS#12 file.
    public init(pkcs12Path path: String, password: String) throws(TLSIdentityError) {
        guard let data = FileManager.default.contents(atPath: path) else { throw .fileUnreadable(path: path) }
        try self.init(pkcs12: [UInt8](data), password: password)
    }

    /// The identity as Network.framework's `sec_identity_t`.
    func makeSecIdentity() -> sec_identity_t? {
        sec_identity_create(secIdentity)
    }
}

/// Why a ``TLSIdentity`` could not be loaded.
public enum TLSIdentityError: Error, Sendable, Hashable {
    /// The file could not be read.
    case fileUnreadable(path: String)
    /// `SecPKCS12Import` (or reading the certificate) failed with this `OSStatus`, for example
    /// `errSecAuthFailed` (-25293) for a wrong password.
    case importFailed(status: Int32)
    /// The bundle contained no identity.
    case noIdentity
}
