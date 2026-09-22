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

    /// Usable directly so a test can build an isolated instance with its own
    /// helperProvider; `shared` remains the app's single instance.
    init() {}

    /// Resolves the privileged helper. Production points this at the XPC
    /// connection in PrivilegedHelperManager; a test substitutes a fake so the
    /// composition and reply paths below run without a helper installed. The
    /// argument is the connection's failure handler, which may fire before the
    /// reply block does.
    var helperProvider: (_ failure: ((String) -> Void)?) -> PrivilegedProxyHelper? = { failure in
        guard let helper = PrivilegedHelperManager.shared.helper(failture: failure) else { return nil }
        return PrivilegedProxyHelperAdapter(helper: helper)
    }

    /// Installs the anchor with rules for the current runtime shape
    /// (TUN vs system proxy, allow-LAN). Returns nil on success.
    func applyNow() async -> String? {
        let rules = Self.buildRules()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // The XPC error handler and the reply block can both fire for one
            // call; the box makes the first win and the second a no-op.
            let reply = OnceBox<String?> { continuation.resume(returning: $0) }
            guard let helper = helperProvider({ message in
                reply.resume("proxy helper unavailable: \(message)")
            }) else {
                reply.resume("proxy helper unavailable")
                return
            }
            helper.setFirewallKillSwitch(rules: rules) { errorMessage in
                reply.resume(errorMessage)
            }
        }
    }

    /// Removes the anchor. Returns nil on success, otherwise an error string.
    @discardableResult
    func clear() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let reply = OnceBox<String?> { continuation.resume(returning: $0) }
            guard let helper = helperProvider({ _ in
                reply.resume("proxy helper unavailable")
            }) else {
                reply.resume("proxy helper unavailable")
                return
            }
            helper.clearFirewallKillSwitch { errorMessage in
                reply.resume(errorMessage)
            }
        }
    }
}

extension KillSwitchManager {
    /// The full anchor ruleset; composition lives in WaypointCore so it is
    /// unit-testable without a helper. `Settings.tunEnabled` is also what makes
    /// `CoreProcessManager` spawn the core through the helper, i.e. as root.
    static func buildRules() -> String {
        KillSwitchRules.compose(uid: getuid(),
                                allowsLan: ConfigManager.allowConnectFromLan,
                                coreRunsAsRoot: Settings.tunEnabled)
    }
}
