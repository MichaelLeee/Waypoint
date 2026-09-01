//
//  MitmProxyServer.swift
//  Waypoint
//  Local interception engine mihomo forwards matched hosts through as an HTTP
//  proxy entry. Terminates CONNECT tunnels with locally issued leaf certs,
//  opens its own TLS session to the real host, and applies header-level
//  RewriteRules in between.
//  The engine itself (NIO + NIOSSL, platform-neutral) lives in the
//  WaypointMitmEngine package; this wrapper adapts it to app types
//  (RewriteRule, Settings, keychain-backed certificate authority) and keeps
//  lifecycle on the main thread.
//

import Foundation
import WaypointMitmEngine

// Lifecycle state is touched only from the main thread.
final class MitmProxyServer: @unchecked Sendable {
    static let shared = MitmProxyServer()

    static let portRangeStart = MitmEngine.portRangeStart
    static let portRangeEnd = MitmEngine.portRangeEnd

    struct EngineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Port the engine bound after a successful `start`; 0 when stopped.
    var port: UInt16 { engine.port }

    private let engine = MitmEngine()

    private init() {}

    // MARK: - Lifecycle

    @discardableResult
    func start(rules newRules: [RewriteRule]) throws -> UInt16 {
        assert(Thread.isMainThread)
        guard Settings.mitmEnabled else { return 0 }
        let engineRules = newRules.map(\.engineRule)
        if engine.isRunning {
            engine.updateRules(engineRules)
            return engine.port
        }
        do {
            return try engine.start(rules: engineRules,
                                    identityProvider: MitmCertificateAuthority.shared)
        } catch {
            throw EngineError(message: NSLocalizedString(
                "No free port available for the intercept proxy (\(Self.portRangeStart)–\(Self.portRangeEnd)).",
                comment: ""
            ))
        }
    }

    func stop() {
        assert(Thread.isMainThread)
        engine.stop()
    }

    var isRunning: Bool { engine.isRunning }

    /// Starts the engine when MITM is enabled (and syncs the bound port into
    /// settings so config injection matches), no-op otherwise. Call before any
    /// effective-config generation. Returns the bound port (0 = not running).
    @discardableResult
    static func ensureRunning() -> UInt16 {
        dispatchPrecondition(condition: .onQueue(.main))
        guard Settings.mitmEnabled else {
            shared.stop()
            return 0
        }
        do {
            let boundPort = try shared.start(rules: RewriteRuleStore.load())
            if boundPort > 0, Settings.mitmEnginePort != Int(boundPort) {
                Settings.mitmEnginePort = Int(boundPort)
            }
            return boundPort
        } catch {
            Logger.log("MITM engine failed to start: \(error.localizedDescription)", level: .error)
            return 0
        }
    }
}
