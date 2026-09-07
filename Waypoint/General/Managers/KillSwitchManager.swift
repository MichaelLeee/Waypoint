//
//  KillSwitchManager.swift
//  Waypoint
//  System-wide kill switch: while the proxy is up, a pf anchor drops any
//  egress traffic that would bypass Waypoint. The rules text is composed here
//  and executed by the privileged helper (pfctl needs root); the helper also
//  tears everything down on disconnect/crash so the machine can't be locked
//  out of the network.
//

import Foundation
import WaypointCore

@MainActor
final class KillSwitchManager {
    static let shared = KillSwitchManager()

    private init() {}

    /// Installs the anchor with rules for the current runtime shape
    /// (TUN vs system proxy, allow-LAN). Returns nil on success.
    func applyNow() async -> String? {
        let rules = Self.buildRules()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // The XPC error handler and the reply block can both fire for one
            // call; the box makes the first win and the second a no-op.
            let reply = ReplyBox(fallback: "proxy helper unavailable", continuation: continuation)
            guard let helper = PrivilegedHelperManager.shared.helper(failture: { message in
                reply.resume(returning: "proxy helper unavailable: \(message)")
            }) else {
                reply.resume(returning: "proxy helper unavailable")
                return
            }
            helper.setFirewallKillSwitch(rules) { errorMessage in
                reply.resume(returning: errorMessage)
            }
        }
    }

    /// Removes the anchor. Returns nil on success, otherwise an error string.
    @discardableResult
    func clear() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let reply = ReplyBox(fallback: "proxy helper unavailable", continuation: continuation)
            guard let helper = PrivilegedHelperManager.shared.helper(failture: { _ in
                reply.resume(returning: "proxy helper unavailable")
            }) else {
                reply.resume(returning: "proxy helper unavailable")
                return
            }
            helper.clearFirewallKillSwitch { errorMessage in
                reply.resume(returning: errorMessage)
            }
        }
    }
}

/// Resumes the wrapped continuation at most once, from whichever callback
/// (XPC error handler or reply block) lands first.
private final class ReplyBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<T, Never>
    private let fallback: T

    init(fallback: T, continuation: CheckedContinuation<T, Never>) {
        self.fallback = fallback
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(returning: value)
    }
}

extension KillSwitchManager {
    /// The full anchor ruleset; composition lives in WaypointCore so it is
    /// unit-testable without a helper.
    static func buildRules() -> String {
        KillSwitchRules.compose(uid: getuid(), allowsLan: ConfigManager.allowConnectFromLan)
    }
}
