//
//  MitmIdentity.swift
//  WaypointMitmEngine
//  A TLS identity is handed to the engine as raw DER so the engine itself
//  never depends on Security.framework or the keychain: the embedder keeps
//  its own authority and mints per-host leaves however it likes.
//

public struct MitmIdentity: Sendable {
    /// Full certificate DER (single leaf; chain to the root is the
    /// embedder's problem — a locally trusted root needs no intermediates).
    public let certificateDER: [UInt8]
    /// Private key DER (PKCS#8 or SEC1; BoringSSL auto-detects both).
    public let privateKeyDER: [UInt8]

    public init(certificateDER: [UInt8], privateKeyDER: [UInt8]) {
        self.certificateDER = certificateDER
        self.privateKeyDER = privateKeyDER
    }
}

/// Supplies the leaf identity for a host about to be impersonated. Called on
/// engine event-loop threads; implementations must be internally
/// synchronized (a lock-guarded class is fine) and should cache per host.
public protocol MitmIdentityProviding: Sendable {
    func identity(forHost host: String) throws -> MitmIdentity
}
