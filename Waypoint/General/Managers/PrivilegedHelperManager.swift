//
//  PrivilegedHelperManager.swift
//  Waypoint
//

import AppKit
import Combine
import ServiceManagement

// @unchecked: XPC connection state is confined to the main thread.
class PrivilegedHelperManager: @unchecked Sendable {
    // Thread-safe: sent from XPC reply queues and main alike.
    let isHelperCheckFinished = CurrentValueSubject<Bool, Never>(false)
    // Written on the main thread from the launch-time install check; read by
    // the main-thread settings UI.
    private(set) var lastHelperStatus: HelperStatus?
    private var cancelInstallCheck = false
    private var useLegacyInstall = false

    private var connection: NSXPCConnection?
    private var _helper: ProxyConfigRemoteProcessProtocol?
    static let machServiceName = "org.waypnt.waypoint.ProxyConfigHelper"
    static let daemonPlistName = "org.waypnt.waypoint.ProxyConfigHelper.plist"
    static let shared = PrivilegedHelperManager()
    init() {}

    // MARK: - Public

    func checkInstall() {
        Logger.log("checkInstall", level: .debug)
        getHelperStatus { [weak self] status in
            Logger.log("check result: \(status)", level: .debug)
            guard let self = self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.handleCheckResult(status)
                }
            }
        }
    }

    @MainActor private func handleCheckResult(_ status: HelperStatus) {
        lastHelperStatus = status
        switch status {
        case .noFound:
            if #available(macOS 13, *) {
                let url = URL(string: "/Library/LaunchDaemons/\(PrivilegedHelperManager.machServiceName).plist")!
                if SMAppService.statusForLegacyPlist(at: url) == .requiresApproval {
                    promptLoginItemsApproval()
                }
            }
            handleCheckResult(.needUpdate)
        case .needUpdate:
            Logger.log("need to install helper", level: .debug)
            notifyInstall()
        case .installed:
            isHelperCheckFinished.send(true)
        case .needsApproval:
            promptLoginItemsApproval()
        }
    }

    func resetConnection() {
        connection?.invalidate()
        connection = nil
        _helper = nil
    }

    /// Install the helper daemon via SMAppService. SMJobBless is deprecated
    /// and its authorization path kept failing with kSMErrorAuthorizationFailure
    /// even with the canonical AuthorizationCopyRights dance on recent macOS;
    /// SMAppService handles the admin prompt itself and registers the daemon
    /// from the launchd plist embedded in the app bundle at
    /// Contents/Library/LaunchDaemons.
    private func installHelperDaemon() -> DaemonInstallResult {
        Logger.log("installHelperDaemon", level: .info)

        defer {
            resetConnection()
        }

        let service = SMAppService.daemon(plistName: PrivilegedHelperManager.daemonPlistName)
        if service.status == .enabled {
            // Registered but the XPC version check failed to get here: the app
            // bundle was most likely rebuilt after registration, leaving
            // launchd holding a stale code-signature requirement. Start from a
            // clean registration.
            Logger.log("daemon registered but stale; re-registering", level: .info)
            try? service.unregister()
        }
        do {
            try service.register()
        } catch {
            // A daemon with this identifier can be registered from a previous,
            // differently signed build (e.g. the app moved from Xcode
            // DerivedData to /Applications). SMAppService then reports
            // .notRegistered yet refuses to replace the stale record; drop it
            // and try once more before giving up.
            Logger.log("daemon register failed: \(error); retrying after unregister", level: .error)
            try? service.unregister()
            do {
                try service.register()
            } catch {
                Logger.log("daemon register failed after unregister: \(error)", level: .error)
                return .registerError(error.localizedDescription)
            }
        }

        Logger.log("\(PrivilegedHelperManager.machServiceName) installed successfully", level: .info)
        return .success
    }

    func helper(failture: ((String) -> Void)? = nil) -> ProxyConfigRemoteProcessProtocol? {
        connection = NSXPCConnection(machServiceName: PrivilegedHelperManager.machServiceName, options: NSXPCConnection.Options.privileged)
        connection?.remoteObjectInterface = NSXPCInterface(with: ProxyConfigRemoteProcessProtocol.self)
        connection?.invalidationHandler = {
            Logger.log("XPC Connection Invalidated")
        }
        connection?.resume()
        guard let helper = connection?.remoteObjectProxyWithErrorHandler({ error in
            Logger.log("Helper connection was closed with error: \(error)")
            failture?(error.localizedDescription)
        }) as? ProxyConfigRemoteProcessProtocol else { return nil }
        return helper
    }

    enum HelperStatus {
        case installed
        case noFound
        case needUpdate
        case needsApproval
    }

    private func getHelperStatus(callback: @escaping @Sendable (HelperStatus) -> Void) {
        // Runs at most once: whichever of the timeout task or the XPC reply
        // lands first decides the reported status.
        let once = OnceReplyBox()
        let reply: @Sendable (HelperStatus) -> Void = { status in
            once.run { callback(status) }
        }

        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/" + PrivilegedHelperManager.machServiceName)
        guard
            let helperBundleInfo = CFBundleCopyInfoDictionaryForURL(helperURL as CFURL) as? [String: Any],
            let helperVersion = helperBundleInfo["CFBundleShortVersionString"] as? String else {
            Logger.log("check helper status fail")
            reply(.noFound)
            return
        }
        let legacyFileExists = FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/\(PrivilegedHelperManager.machServiceName)")
        if !legacyFileExists {
            // The modern daemon runs the helper from inside the app bundle, so
            // registration state lives in SMAppService, not the file system.
            switch SMAppService.daemon(plistName: PrivilegedHelperManager.daemonPlistName).status {
            case .requiresApproval:
                reply(.needsApproval)
                return
            case .enabled:
                break
            default:
                reply(.noFound)
                return
            }
        }
        let timeout: TimeInterval = 15
        let time = Date()

        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            Logger.log("check helper timeout time: \(timeout)")
            reply(.noFound)
        }

        helper()?.getVersion { installedHelperVersion in
            Logger.log("helper version \(installedHelperVersion ?? "") require version \(helperVersion)", level: .debug)
            let versionMatch = installedHelperVersion == helperVersion
            let interval = Date().timeIntervalSince(time)
            Logger.log("check helper using time: \(interval)")
            reply(versionMatch ? .installed : .needUpdate)
        }
    }
}

extension PrivilegedHelperManager {
    @MainActor private func notifyInstall() {
        guard showInstallHelperAlert() else { exit(0) }

        if cancelInstallCheck {
            return
        }

        if useLegacyInstall {
            useLegacyInstall = false
            legacyInstallHelper()
            if !cancelInstallCheck {
                checkInstall()
            }
            return
        }

        let result = installHelperDaemon()
        if case .success = result {
            handleFreshInstallApproval()
            return
        }
        result.alertAction()
        useLegacyInstall = result.shouldRetryLegacyWay()
        NSAlert.alert(with: result.alertContent)
        if !cancelInstallCheck {
            checkInstall()
        }
    }

    /// A freshly blessed daemon is registered but stays disabled until the user
    /// approves it in Login Items (macOS 13+); XPC connections fail until then,
    /// which used to surface only as "proxy helper unavailable" on next feature
    /// use. Check and prompt right after install instead of waiting for relaunch.
    @MainActor private func handleFreshInstallApproval() {
        if SMAppService.daemon(plistName: PrivilegedHelperManager.daemonPlistName).status == .requiresApproval {
            promptLoginItemsApproval()
            return
        }
        if #available(macOS 13, *) {
            let plistURL = URL(fileURLWithPath: "/Library/LaunchDaemons/\(PrivilegedHelperManager.machServiceName).plist")
            if SMAppService.statusForLegacyPlist(at: plistURL) == .requiresApproval {
                promptLoginItemsApproval()
                return
            }
        }
        checkInstall()
    }

    @MainActor private func promptLoginItemsApproval() {
        let alert = NSAlert()
        let notice = NSLocalizedString("Waypoint use a daemon helper to setup your system proxy. Please enable Waypoint in the Login Items under the Allow in the Background section and relaunch the app", comment: "")
        let addition = NSLocalizedString("If you can not find Waypoint in the settings, you can try reset daemon", comment: "")
        alert.messageText = notice + "\n" + addition
        alert.addButton(withTitle: NSLocalizedString("Open System Login Item Setting", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Reset Daemon", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        } else {
            removeInstallHelper()
        }
    }

    @MainActor private func showInstallHelperAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Waypoint needs to install/update a helper tool with administrator privileges, otherwise Waypoint won't be able to configure system proxy.", comment: "")
        alert.alertStyle = .warning
        if useLegacyInstall {
            alert.addButton(withTitle: NSLocalizedString("Legacy Install", comment: ""))
        } else {
            alert.addButton(withTitle: NSLocalizedString("Install", comment: ""))
        }
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertThirdButtonReturn:
            cancelInstallCheck = true
            isHelperCheckFinished.send(true)
            Logger.log("cancelInstallCheck = true", level: .error)
            return true
        default:
            return false
        }
    }
}

private final class OnceReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

private enum DaemonInstallResult {
    case success
    case registerError(String)

    var alertContent: String {
        switch self {
        case .success:
            return ""
        case let .registerError(message):
            return "Failed to install the proxy helper daemon: \(message)"
        }
    }

    func shouldRetryLegacyWay() -> Bool {
        switch self {
        case .success: return false
        case .registerError: return true
        }
    }

    func alertAction() {}
}
