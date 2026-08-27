//
//  MitmCertificateAuthority.swift
//  Waypoint
//  Keychain-backed local root CA plus an in-memory leaf factory. Only the
//  root persists (key via application tag, cert via label) so the user has
//  to trust it once; leaf identities carry fully ephemeral keys and never
//  touch the keychain.
//  Thread-safety: NSLock instead of an actor — the MITM engine mints leaf
//  identities from its per-tunnel worker threads, where an actor hop onto
//  the main queue would be both illegal under Swift 6 isolation rules and
//  wrong for latency. Every entry point takes the lock; keychain calls are
//  already internally serialized but stay inside it for coherent snapshots.
//

import Foundation
import Security

// @unchecked: all mutable state is guarded by `lock`.
final class MitmCertificateAuthority: @unchecked Sendable {
    static let shared = MitmCertificateAuthority()

    static let caTag = "org.waypnt.waypoint.mitm.ca"
    static let caCommonName = "Waypoint Local Root CA"

    private let lock = NSLock()
    private var caPrivateKey: SecKey?
    private var caCertificate: SecCertificate?
    /// host -> issued leaf; caches so repeat CONNECTs skip re-signing.
    private var leafIdentities: [String: LeafIdentity] = [:]

    /// Certificate + key bundle handed to the MITM engine's TLS server leg.
    struct LeafIdentity {
        let certificate: SecCertificate
        let privateKey: SecKey
    }

    enum AuthorityError: LocalizedError {
        case keyUnavailable(OSStatus)
        case certificateGeneration(String)
        case notInitialized

        var errorDescription: String? {
            switch self {
            case .keyUnavailable(let status):
                return "MITM CA keychain access failed (\(status))"
            case .certificateGeneration(let detail):
                return "MITM certificate generation failed: \(detail)"
            case .notInitialized:
                return "MITM CA is not initialized"
            }
        }
    }

    private static func statusCode(of error: Unmanaged<CFError>?) -> OSStatus {
        guard let error else { return -1 }
        return OSStatus(CFErrorGetCode(error.takeRetainedValue()))
    }

    // MARK: - Root authority

    /// Loads or creates the CA key and its self-signed certificate.
    func ensureAuthority() throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureAuthorityLocked()
    }

    private func ensureAuthorityLocked() throws {
        if caPrivateKey != nil, caCertificate != nil { return }

        let key = try loadOrCreateCAKey()
        let point = try externalPoint(of: key)

        if let existing = loadCACertificate(), Self.certificateBelongs(existing, point) {
            caPrivateKey = key
            caCertificate = existing
            return
        }

        let tbs = X509.buildTBSCertificate(
            template: .init(commonName: Self.caCommonName, isCertificateAuthority: true),
            uncompressedPoint: point
        )
        let der = try X509.sign(tbs: tbs, privateKey: key)
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw AuthorityError.certificateGeneration("root DER was rejected by SecCertificateCreateWithData")
        }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: Self.caCommonName,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
            throw AuthorityError.keyUnavailable(addStatus)
        }

        caPrivateKey = key
        caCertificate = cert
    }

    func certificateData() throws -> Data {
        try ensureAuthorityLocked()
        guard let caCertificate else { throw AuthorityError.notInitialized }
        return SecCertificateCopyData(caCertificate) as Data
    }

    /// Writes the root certificate next to the app's config folder for manual
    /// inspection/import, returning its path.
    @discardableResult
    func exportCertificate() throws -> URL {
        let data = try certificateData()
        let directory = URL(fileURLWithPath: kConfigFolderPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("WaypointRootCA.cer")
        try data.write(to: url)
        return url
    }

    /// Attempts user-level trust promotion. Returns nil on success, otherwise
    /// a message and falls back to exporting the .cer for Keychain Access.
    func installAndTrust() -> String? {
        do {
            try ensureAuthority()
            guard let caCertificate else { throw AuthorityError.notInitialized }
            // sec_trust_settings_for_certificate and the
            // kSecTrustSettingsResult* constants are not exported to Swift;
            // the documented string value of the trustRoot result is
            // unchanged. Recent SDKs import the settings parameter as a
            // trust-settings array and the API as throwing.
            let settings: CFArray = [
                [kSecTrustSettingsResult as String: "trustRoot"],
            ] as CFArray
            let status = SecTrustSettingsSetTrustSettings(caCertificate, SecTrustSettingsDomain.user, settings)
            if status == errSecSuccess {
                return nil
            }
            Logger.log("SecTrustSettingsSetTrustSettings failed: \(status)", level: .error)
            _ = try exportCertificate()
            return NSLocalizedString(
                "Automatic trust setup failed. A certificate file was exported — double-click it and choose \"Always Trust\".",
                comment: ""
            )
        } catch {
            return error.localizedDescription
        }
    }

    func removeAuthority() {
        lock.lock()
        defer { lock.unlock() }
        leafIdentities.removeAll()
        caPrivateKey = nil
        caCertificate = nil
        var deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.caTag,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        deleteQuery = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: Self.caCommonName,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }

    // MARK: - Leaf identities

    /// Builds (and caches) a TLS identity for `host`, signed by the local CA.
    /// The leaf key is ephemeral — it never enters the keychain. Safe to call
    /// from the engine's tunnel threads.
    func identity(forHost host: String) throws -> LeafIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let cached = leafIdentities[host] { return cached }
        try ensureAuthorityLocked()
        guard let caPrivateKey else { throw AuthorityError.notInitialized }

        let parameters: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var keyError: Unmanaged<CFError>?
        guard let leafKey = SecKeyCreateRandomKey(parameters as CFDictionary, &keyError) else {
            throw AuthorityError.certificateGeneration(
                "leaf key (\(Self.statusCode(of: keyError)))"
            )
        }
        let point = try externalPoint(of: leafKey)
        let tbs = X509.buildTBSCertificate(
            template: .init(commonName: host, isCertificateAuthority: false, dnsNames: [host]),
            uncompressedPoint: point
        )
        let der = try X509.sign(tbs: tbs, privateKey: caPrivateKey)
        guard let leafCert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw AuthorityError.certificateGeneration("leaf DER rejected for \(host)")
        }
        let identity = LeafIdentity(certificate: leafCert, privateKey: leafKey)
        leafIdentities[host] = identity
        return identity
    }

    // MARK: - Internals

    private func loadOrCreateCAKey() throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: Self.caTag,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let key = item {
            return key as! SecKey
        }
        guard status == errSecItemNotFound else {
            throw AuthorityError.keyUnavailable(status)
        }
        let createAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: Self.caTag,
            kSecAttrLabel as String: Self.caCommonName,
        ]
        var keyError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(createAttributes as CFDictionary, &keyError) else {
            throw AuthorityError.keyUnavailable(Self.statusCode(of: keyError))
        }
        return key
    }

    private func loadCACertificate() -> SecCertificate? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: Self.caCommonName,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let ref = item else {
            return nil
        }
        // CFTypeRef -> SecCertificateRef: the compiler rejects both `as!` and
        // `as?` here (the cast "always succeeds"), so use an unchecked downcast.
        return unsafeDowncast(ref, to: SecCertificate.self)
    }

    private func externalPoint(of key: SecKey) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw AuthorityError.keyUnavailable(Self.statusCode(of: error))
        }
        return [UInt8](data)
    }

    /// Compares the key material of `certificate` against `uncompressedPoint`.
    private static func certificateBelongs(_ certificate: SecCertificate, _ uncompressedPoint: [UInt8]) -> Bool {
        guard let key = SecCertificateCopyKey(certificate),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return false }
        return [UInt8](data) == uncompressedPoint
    }
}
