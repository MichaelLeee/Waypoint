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

    private var authRef: AuthorizationRef?
    private var connection: NSXPCConnection?
    private var _helper: ProxyConfigRemoteProcessProtocol?
    static let machServiceName = "org.waypnt.waypoint.ProxyConfigHelper"
    static let shared = PrivilegedHelperManager()
    init() {
        initAuthorizationRef()
    }

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
        }
    }

    func resetConnection() {
        connection?.invalidate()
        connection = nil
        _helper = nil
    }

    private func initAuthorizationRef() {
        // Create an empty AuthorizationRef
        let status = AuthorizationCreate(nil, nil, AuthorizationFlags(), &authRef)
        if status != OSStatus(errAuthorizationSuccess) {
            Logger.log("initAuthorizationRef AuthorizationCreate failed", level: .error)
            return
        }
    }

    /// Install new helper daemon
    private func installHelperDaemon() -> DaemonInstallResult {
        Logger.log("installHelperDaemon", level: .info)

        defer {
            resetConnection()
        }

        // Create authorization reference for the user
        var authRef: AuthorizationRef?
        var authStatus = AuthorizationCreate(nil, nil, [], &authRef)

        // Check if the reference is valid
        guard authStatus == errAuthorizationSuccess else {
            Logger.log("Authorization failed: \(authStatus)", level: .error)
            return .authorizationFail
        }

        // Ask user for the admin privileges to install the
        var authItem = AuthorizationItem(name: (kSMRightBlessPrivilegedHelper as NSString).utf8String!, valueLength: 0, value: nil, flags: 0)
        var authRights = withUnsafeMutablePointer(to: &authItem) { pointer in
            AuthorizationRights(count: 1, items: pointer)
        }
        // Without .preAuthorize: pre-authorizing only CHECKS the right without
        // acquiring it, so the ref handed to SMJobBless carries no rights and
        // bless fails with kSMErrorAuthorizationFailure. extendRights +
        // interactionAllowed grants the right interactively (admin prompt).
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights]
        authStatus = AuthorizationCreate(&authRights, nil, flags, &authRef)
        defer {
            if let ref = authRef {
                AuthorizationFree(ref, [])
            }
        }
        // Check if the authorization went succesfully
        guard authStatus == errAuthorizationSuccess else {
            Logger.log("Couldn't obtain admin privileges: \(authStatus)", level: .error)
            return .getAdminFail
        }

        // Launch the privileged helper using SMJobBless tool
        var error: Unmanaged<CFError>?
        if SMJobBless(kSMDomainSystemLaunchd, PrivilegedHelperManager.machServiceName as CFString, authRef, &error) == false {
            let blessError = error!.takeRetainedValue() as Error
            Logger.log("Bless Error: \(blessError)", level: .error)
            return .blessError((blessError as NSError).code)
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
        let helperFileExists = FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/\(PrivilegedHelperManager.machServiceName)")
        if !helperFileExists {
            reply(.noFound)
            return
        }
        let timeout: TimeInterval = helperFileExists ? 15 : 5
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

private enum AppAuthorizationRights {
    nonisolated(unsafe) static let rightName: NSString = "\(PrivilegedHelperManager.machServiceName).config" as NSString
    // NSString/CFString/[String: Any] constants are immutable; marked unchecked
    // for strict-concurrency only.
    nonisolated(unsafe) static let rightDefaultRule: Dictionary = adminRightsRule
    nonisolated(unsafe) static let rightDescription: CFString = "ProxyConfigHelper wants to configure your proxy setting'" as CFString
    nonisolated(unsafe) static let adminRightsRule: [String: Any] = ["class": "user",
                                                 "group": "admin",
                                                 "timeout": 0,
                                                 "version": 1]
}

private enum DaemonInstallResult {
    case success
    case authorizationFail
    case getAdminFail
    case blessError(Int)

    var alertContent: String {
        switch self {
        case .success:
            return ""
        case .authorizationFail: return "Failed to create authorization!"
        case .getAdminFail: return "Failed to get admin authorization!"
        case let .blessError(code):
            switch code {
            case kSMErrorInternalFailure: return "blessError: kSMErrorInternalFailure"
            case kSMErrorInvalidSignature: return "blessError: kSMErrorInvalidSignature"
            case kSMErrorAuthorizationFailure: return "blessError: kSMErrorAuthorizationFailure"
            case kSMErrorToolNotValid: return "blessError: kSMErrorToolNotValid"
            case kSMErrorJobNotFound: return "blessError: kSMErrorJobNotFound"
            case kSMErrorServiceUnavailable: return "blessError: kSMErrorServiceUnavailable"
            case kSMErrorJobMustBeEnabled: return "Waypoint Helper is disabled by other process. Please run \"sudo launchctl enable system/\(PrivilegedHelperManager.machServiceName)\" in your terminal. The command has been copied to your pasteboard"
            case kSMErrorInvalidPlist: return "blessError: kSMErrorInvalidPlist"
            default:
                return "bless unknown error:\(code)"
            }
        }
    }

    func shouldRetryLegacyWay() -> Bool {
        switch self {
        case .success: return false
        case let .blessError(code):
            switch code {
            case kSMErrorJobMustBeEnabled:
                return false
            default:
                return true
            }
        default:
            return true
        }
    }

    func alertAction() {
        switch self {
        case let .blessError(code):
            switch code {
            case kSMErrorJobMustBeEnabled:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("sudo launchctl enable system/\(PrivilegedHelperManager.machServiceName)", forType: .string)
            default:
                break
            }
        default:
            break
        }
    }
}
