//
//  ManagerProtocols.swift
//  Waypoint
//  Abstractions for the impure managers, so the app can wire dependencies
//  at the composition root (AppDelegate) instead of reaching for .shared
//  everywhere. Conformed to by the concrete managers; tests can substitute
//  their own implementations.
//

import Combine
import Foundation

/// Core (mihomo) subprocess lifecycle. All members are main-actor isolated,
/// matching CoreProcessManager.
@MainActor
protocol ProxyCoreControlling: AnyObject {
    var isRunning: Bool { get }
    var onUnexpectedExit: (() -> Void)? { get set }
    func start(configPath: String,
               homeDir: String,
               externalController: String,
               secret: String,
               externalUI: String?) async throws
    func stop()
}

/// System-wide proxy (networksetup via the privileged helper).
/// Per-method isolation mirrors SystemProxyManager exactly.
protocol SystemProxyManaging: AnyObject {
    func saveProxy()
    @MainActor func enableProxy()
    func enableProxy(port: Int, socksPort: Int)
    @MainActor func disableProxy(forceDisable: Bool, complete: (() -> Void)?)
    func disableProxy(port: Int, socksPort: Int, forceDisable: Bool, complete: (() -> Void)?)
}

/// Privileged-helper install/status surface used by the composition root.
protocol HelperInstalling: AnyObject {
    var isHelperCheckFinished: CurrentValueSubject<Bool, Never> { get }
    func checkInstall()
    func helper(failture: ((String) -> Void)?) -> ProxyConfigRemoteProcessProtocol?
}

/// The privileged helper's XPC surface as the proxy managers use it.
///
/// The XPC protocol itself is declared in ObjC and reaches Swift through the
/// app target's bridging header, which is not part of the Waypoint module: a
/// test target can name this protocol but not that one. The adapter below
/// bridges the two, so a test can substitute a fake helper.
protocol PrivilegedProxyHelper: AnyObject {
    func getCurrentProxySetting(reply: @escaping ([String: Any]?) -> Void)
    func enableProxy(port: Int,
                     socksPort: Int,
                     filterInterface: Bool,
                     ignoreList: [String],
                     error: @escaping (String?) -> Void)
    func disableProxy(filterInterface: Bool, reply: @escaping (String?) -> Void)
    func restoreProxy(port: Int,
                      socksPort: Int,
                      info: [String: Any],
                      filterInterface: Bool,
                      error: @escaping (String?) -> Void)
    func setFirewallKillSwitch(rules: String, reply: @escaping (String?) -> Void)
    func clearFirewallKillSwitch(reply: @escaping (String?) -> Void)
}

/// Presents an XPC connection as a `PrivilegedProxyHelper`. The ObjC replies
/// carry untyped collections and `String!`, so the conversions live here rather
/// than at each call site in the managers.
final class PrivilegedProxyHelperAdapter: PrivilegedProxyHelper {
    private let helper: ProxyConfigRemoteProcessProtocol

    init(helper: ProxyConfigRemoteProcessProtocol) {
        self.helper = helper
    }

    func getCurrentProxySetting(reply: @escaping ([String: Any]?) -> Void) {
        helper.getCurrentProxySetting { info in reply(info as? [String: Any]) }
    }

    func enableProxy(port: Int,
                     socksPort: Int,
                     filterInterface: Bool,
                     ignoreList: [String],
                     error: @escaping (String?) -> Void) {
        helper.enableProxy(withPort: Int32(port),
                           socksPort: Int32(socksPort),
                           pac: nil,
                           filterInterface: filterInterface,
                           ignoreList: ignoreList,
                           error: error)
    }

    func disableProxy(filterInterface: Bool, reply: @escaping (String?) -> Void) {
        helper.disableProxy(withFilterInterface: filterInterface, reply: reply)
    }

    func restoreProxy(port: Int,
                      socksPort: Int,
                      info: [String: Any],
                      filterInterface: Bool,
                      error: @escaping (String?) -> Void) {
        helper.restoreProxy(withCurrentPort: Int32(port),
                            socksPort: Int32(socksPort),
                            info: info,
                            filterInterface: filterInterface,
                            error: error)
    }

    func setFirewallKillSwitch(rules: String, reply: @escaping (String?) -> Void) {
        helper.setFirewallKillSwitch(rules, reply: reply)
    }

    func clearFirewallKillSwitch(reply: @escaping (String?) -> Void) {
        helper.clearFirewallKillSwitch(reply)
    }
}

extension CoreProcessManager: ProxyCoreControlling {}
extension SystemProxyManager: SystemProxyManaging {}
extension PrivilegedHelperManager: HelperInstalling {}
