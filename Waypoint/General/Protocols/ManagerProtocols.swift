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

extension CoreProcessManager: ProxyCoreControlling {}
extension SystemProxyManager: SystemProxyManaging {}
extension PrivilegedHelperManager: HelperInstalling {}
