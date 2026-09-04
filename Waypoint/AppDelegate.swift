//
//  AppDelegate.swift
//  Waypoint
//

import Cocoa
import Combine
import WaypointNetworking

// Responsibilities live in Extensions/AppDelegate+{Menu,Observers,
// ProxyLifecycle,MenuActions,CrashAndMemory,MenuDelegate}.swift; this file
// keeps the class declaration, stored state, and app lifecycle callbacks.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusItem: NSStatusItem!

    // The status menu is built programmatically in setupMenus(); the items
    // below mirror the menu structure that used to live in Main.storyboard.
    var statusMenu: NSMenu!
    var checkForUpdateMenuItem: NSMenuItem!
    var proxySettingMenuItem: NSMenuItem!
    var autoStartMenuItem: NSMenuItem!
    var proxyModeGlobalMenuItem: NSMenuItem!
    var proxyModeDirectMenuItem: NSMenuItem!
    var proxyModeRuleMenuItem: NSMenuItem!
    var allowFromLanMenuItem: NSMenuItem!
    var enhanceTunModeMenuItem: NSMenuItem!
    var proxyModeMenuItem: NSMenuItem!
    var showNetSpeedIndicatorMenuItem: NSMenuItem!
    var dashboardMenuItem: NSMenuItem!
    var separatorLineTop: NSMenuItem!
    var sepatatorLineEndProxySelect: NSMenuItem!
    var configSeparatorLine: NSMenuItem!
    var logLevelMenuItem: NSMenuItem!
    var httpPortMenuItem: NSMenuItem!
    var socksPortMenuItem: NSMenuItem!
    var apiPortMenuItem: NSMenuItem!
    var ipMenuItem: NSMenuItem!
    var remoteConfigAutoupdateMenuItem: NSMenuItem!
    var copyExportCommandMenuItem: NSMenuItem!
    var copyExportCommandExternalMenuItem: NSMenuItem!
    var externalControlSeparator: NSMenuItem!
    var connectionsMenuItem: NSMenuItem!

    var cancellables = Set<AnyCancellable>()
    // Replicates the old Zip(configPublisher, configPublisher.dropFirst())
    // pairing: the first config notification only primes the previous value.
    var configStreamPrimed = false
    var previousStreamedConfig: WaypointConfig?
    var lastSetByOtherObserved = false
    var trafficStreamTask: Task<Void, Never>?
    var logStreamTask: Task<Void, Never>?
    var statusItemView: StatusItemViewProtocol!
    var isSpeedTesting = false

    var runAfterConfigReload: (() -> Void)?

    // Main-actor only: written by startProxy's Task, polled by updateConfig's
    // Task, so a failed core start can surface its real error immediately.
    var lastCoreStartError: Error?

    // True while a core start attempt is between spawn and readiness.
    var coreStartInFlight = false

    // True while a TUN toggle is waiting for its restart to settle.
    var isTunToggleInFlight = false

    var editShortcutMonitor: Any?

    // The SwiftUI adaptor instantiates us on the main thread; the shared
    // reference is captured here because NSApp.delegate is SwiftUI's wrapper.
    override init() {
        super.init()
        Self.sharedRef = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Logger.log("applicationWillFinishLaunching")
        signal(SIGPIPE, SIG_IGN)
        // crash recorder
        failLaunchProtect()
        setupMenus()
        setupEditShortcutMonitor()
        NSAppleEventManager.shared()
            .setEventHandler(self,
                             andSelector: #selector(handleURL(event:reply:)),
                             forEventClass: AEEventClass(kInternetEventClass),
                             andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.log("applicationDidFinishLaunching")
        Logger.log("Appversion: \(AppVersionUtil.currentVersion) \(AppVersionUtil.currentBuild)")
        ProcessInfo.processInfo.disableSuddenTermination()
        // setup menu item first. When the SwiftUI MenuBarExtra comparison
        // flag is on, no NSStatusItem is created and statusItemView stays a
        // no-op so speed/status call sites remain safe.
        statusItemView = NullStatusItemView()
        if !Settings.useSwiftUIMenu {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItemVariableLength)
            statusItemView = StatusItemView.create(statusItem: statusItem)
        }
        setupStatusMenuItemData()
        DispatchQueue.main.async {
            self.postFinishLaunching()
        }
    }

    func postFinishLaunching() {
        Logger.log("postFinishLaunching")
        defer {
            if !Settings.useSwiftUIMenu {
                statusItem.menu = statusMenu
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    self.checkMenuIconVisable()
                }
            }
        }
        if #unavailable(macOS 10.15) {
            // dashboard is not support in macOS 10.15 below
            self.dashboardMenuItem.isHidden = true
            self.connectionsMenuItem.isHidden = true
        }
        AppVersionUtil.showUpgradeAlert()
        ICloudManager.shared.setup()

        if WebPortalManager.hasWebProtal {
            WebPortalManager.shared.addWebProtalMenuItem(&statusMenu)
        }
        AutoUpgardeManager.shared.setup()
        AutoUpgardeManager.shared.setupCheckForUpdatesMenuItem(checkForUpdateMenuItem)
        // install proxy helper
        _ = WaypointResourceManager.check()
        PrivilegedHelperManager.shared.checkInstall()
        ConfigFileManager.copySampleConfigIfNeed()

        PFMoveToApplicationsFolderIfNecessary()

        // claer not existed selected model
        removeUnExistProxyGroups()

        // Core logs/traffic are streamed over the REST API WebSocket (ApiRequest),
        // so no in-process logger setup is needed.
        setupData()
        runAfterConfigReload = { [weak self] in
            Task { await self?.applyRuntimeGeneralSettings() }
        }
        updateConfig(showNotification: false)
        updateLoggingLevel()

        // start watch config file change
        ConfigManager.watchCurrentConfigFile()

        RemoteConfigManager.shared.autoUpdateCheck()

        setupNetworkNotifier()
        KeyboardShortCutManager.setup()
        RemoteControlManager.setupMenuItem(separator: externalControlSeparator)

        showOnboardingIfNeeded()
    }

    /// First-run onboarding: only when no config has ever been imported.
    func showOnboardingIfNeeded() {
        guard RemoteConfigManager.shared.configs.isEmpty,
              !Persistence.onboardingCompleted else { return }
        Persistence.onboardingCompleted = true
        SwiftUIWindowController.create(title: NSLocalizedString("Welcome to Waypoint", comment: ""), content: OnboardingRootView())
            .showWindow(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return TerminalConfirmAction.run()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        Persistence.launchFailTimes = 0
        Logger.log("Waypoint will terminate")
        // Stop the core before the process dies so a root-spawned mihomo is
        // not orphaned; the helper tears down its own children on exit, but a
        // local (non-TUN) child would survive.
        CoreProcessManager.shared.stop()
        MitmProxyServer.shared.stop()
        if NetworkChangeNotifier.isCurrentSystemSetToWaypoint(looser: true) ||
            NetworkChangeNotifier.hasInterfaceProxySetToWaypoint() {
            Logger.log("Need Reset Proxy Setting again", level: .error)
            SystemProxyManager.shared.disableProxy()
        }
    }

    func checkMenuIconVisable() {
        guard let button = statusItem.button else { assertionFailure(); return }
        guard let window = button.window else { assertionFailure(); return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let onScreenRect = window.convertToScreen(buttonRect)
        var leftScreenX: CGFloat = 0
        for screen in NSScreen.screens where screen.frame.origin.x < leftScreenX {
            leftScreenX = screen.frame.origin.x
        }
        let isMenuIconHidden = onScreenRect.midX < leftScreenX

        var isCoverdByNotch = false
        if #available(macOS 12, *), NSScreen.screens.count == 1, let screen = NSScreen.screens.first, let leftArea = screen.auxiliaryTopLeftArea, let rightArea = screen.auxiliaryTopRightArea {
            if onScreenRect.minX > leftArea.maxX, onScreenRect.maxX < rightArea.minX {
                isCoverdByNotch = true
            }
        }

        Logger.log("checkMenuIconVisable: \(onScreenRect) \(leftScreenX), hidden: \(isMenuIconHidden), coverd by notch:\(isCoverdByNotch)")

        if isMenuIconHidden || isCoverdByNotch, !Settings.disableMenubarNotice {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("The status icon is coverd or hide by other app.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Never show again", comment: ""))
            if alert.runModal() == .alertSecondButtonReturn {
                Settings.disableMenubarNotice = true
            }
        }
    }
}
