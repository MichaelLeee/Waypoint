//
//  AppDelegate.swift
//  Waypoint
//

import Cocoa
import CocoaLumberjack
import CocoaLumberjackSwift
import Combine
import WaypointNetworking

let statusItemLengthWithSpeed: CGFloat = 72

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
    private var trafficStreamTask: Task<Void, Never>?
    private var logStreamTask: Task<Void, Never>?
    var statusItemView: StatusItemViewProtocol!
    var isSpeedTesting = false

    var runAfterConfigReload: (() -> Void)?

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
            statusItem = NSStatusBar.system.statusItem(withLength: statusItemLengthWithSpeed)
            statusItemView = StatusItemView.create(statusItem: statusItem)
            statusItemView.updateSize(width: statusItemLengthWithSpeed)
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
              !UserDefaults.standard.bool(forKey: "kOnboardingCompleted") else { return }
        UserDefaults.standard.set(true, forKey: "kOnboardingCompleted")
        SwiftUIWindowController.create(title: NSLocalizedString("Welcome to Waypoint", comment: ""), content: OnboardingRootView())
            .showWindow(nil)
    }

    // MARK: Menus (previously Main.storyboard)

    func setupMenus() {
        NSApp.mainMenu = makeMainMenu()
        statusMenu = makeStatusMenu()
        statusMenu.delegate = self
    }

    private func item(_ title: String,
                      action: Selector? = nil,
                      key: String = "",
                      modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: NSLocalizedString(title, comment: ""),
                              action: action,
                              keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        if action != nil {
            item.target = self
        }
        return item
    }

    /// The hidden application menu, required so text fields in the SwiftUI
    /// windows keep standard Edit shortcuts (copy/paste/undo, ⌘W ...).
    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu(title: "Main Menu")

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "Waypoint")
        appMenu.addItem(withTitle: NSLocalizedString("Quit Waypoint", comment: ""),
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: NSLocalizedString("Edit", comment: ""))
        editMenu.addItem(withTitle: NSLocalizedString("Undo", comment: ""),
                         action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: NSLocalizedString("Redo", comment: ""),
                         action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: NSLocalizedString("Cut", comment: ""),
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: NSLocalizedString("Copy", comment: ""),
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: NSLocalizedString("Paste", comment: ""),
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: NSLocalizedString("Delete", comment: ""),
                         action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: NSLocalizedString("Select All", comment: ""),
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let findItem = NSMenuItem()
        editMenu.addItem(findItem)
        let findMenu = NSMenu(title: NSLocalizedString("Find", comment: ""))
        let findSubItems: [(String, Int, String, NSEvent.ModifierFlags)] = [
            (NSLocalizedString("Find…", comment: ""), 1, "f", .command),
            (NSLocalizedString("Find and Replace…", comment: ""), 12, "f", [.command, .option]),
            (NSLocalizedString("Find Next", comment: ""), 2, "g", .command),
            (NSLocalizedString("Find Previous", comment: ""), 3, "G", .command),
            (NSLocalizedString("Use Selection for Find", comment: ""), 7, "e", .command),
            (NSLocalizedString("Jump to Selection", comment: ""), -1, "j", .command),
        ]
        for (title, tag, key, modifiers) in findSubItems {
            let sub = NSMenuItem(title: title,
                                 action: tag == -1
                                     ? #selector(NSResponder.centerSelectionInVisibleArea(_:))
                                     // performFindPanelAction is an informal AppKit action with no Swift declaration.
                                     : Selector(("performFindPanelAction:")),
                                 keyEquivalent: key)
            sub.tag = tag
            sub.keyEquivalentModifierMask = modifiers
            findMenu.addItem(sub)
        }
        findItem.submenu = findMenu
        editMenu.addItem(withTitle: NSLocalizedString("Close", comment: ""),
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = editMenu

        return mainMenu
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        // Manual enable/disable control (Dashboard etc.); display-only items
        // are disabled explicitly below.
        menu.autoenablesItems = false

        proxyModeMenuItem = item("API Connect Error")
        let modeMenu = NSMenu()
        proxyModeGlobalMenuItem = item("Global",
                                       action: #selector(actionSwitchProxyMode(_:)),
                                       key: "g",
                                       modifiers: .option)
        proxyModeRuleMenuItem = item("Rule",
                                     action: #selector(actionSwitchProxyMode(_:)),
                                     key: "r",
                                     modifiers: .option)
        proxyModeDirectMenuItem = item("Direct",
                                       action: #selector(actionSwitchProxyMode(_:)),
                                       key: "d",
                                       modifiers: .option)
        modeMenu.addItem(proxyModeGlobalMenuItem)
        modeMenu.addItem(proxyModeRuleMenuItem)
        modeMenu.addItem(proxyModeDirectMenuItem)
        proxyModeMenuItem.submenu = modeMenu
        proxyModeMenuItem.isEnabled = false
        menu.addItem(proxyModeMenuItem)

        separatorLineTop = .separator()
        menu.addItem(separatorLineTop)
        sepatatorLineEndProxySelect = .separator()
        menu.addItem(sepatatorLineEndProxySelect)

        proxySettingMenuItem = item("Set as system proxy",
                                    action: #selector(actionSetSystemProxy(_:)),
                                    key: "s")
        menu.addItem(proxySettingMenuItem)

        enhanceTunModeMenuItem = item("Enhanced Mode",
                                      action: #selector(actionEnhanceTunMode(_:)),
                                      key: "e")
        menu.addItem(enhanceTunModeMenuItem)

        copyExportCommandMenuItem = item("Copy shell command",
                                         action: #selector(actionCopyExportCommand(_:)),
                                         key: "c")
        menu.addItem(copyExportCommandMenuItem)

        copyExportCommandExternalMenuItem = item("Copy shell command (External IP)",
                                                 action: #selector(actionCopyExportCommand(_:)),
                                                 key: "c",
                                                 modifiers: [.command, .option])
        copyExportCommandExternalMenuItem.isAlternate = true
        menu.addItem(copyExportCommandExternalMenuItem)

        menu.addItem(.separator())

        autoStartMenuItem = item("Start at login",
                                 action: #selector(actionStartAtLogin(_:)))
        menu.addItem(autoStartMenuItem)

        showNetSpeedIndicatorMenuItem = item("Show network indicator",
                                             action: #selector(actionShowNetSpeedIndicator(_:)))
        menu.addItem(showNetSpeedIndicatorMenuItem)

        allowFromLanMenuItem = item("Allow connect from Lan",
                                    action: #selector(actionAllowFromLan(_:)))
        menu.addItem(allowFromLanMenuItem)

        menu.addItem(.separator())

        menu.addItem(item("Benchmark", action: #selector(actionSpeedTest(_:)), key: "t"))

        dashboardMenuItem = item("Dashboard", action: #selector(actionDashboard(_:)), key: "d")
        dashboardMenuItem.isEnabled = false
        menu.addItem(dashboardMenuItem)

        connectionsMenuItem = item("Connection Details",
                                   action: #selector(actionConnections(_:)),
                                   key: "d",
                                   modifiers: [.command, .shift])
        menu.addItem(connectionsMenuItem)

        menu.addItem(.separator())

        let configsItem = item("Configs")
        let configsMenu = NSMenu()
        configSeparatorLine = .separator()
        configsMenu.addItem(configSeparatorLine)
        configsMenu.addItem(item("Open config folder",
                                 action: #selector(openConfigFolder(_:)),
                                 key: "o"))
        configsMenu.addItem(item("Reload config",
                                 action: #selector(actionUpdateConfig(_:)),
                                 key: "r"))
        configsMenu.addItem(item("Update external resources",
                                 action: #selector(actionUpdateExternalResource(_:)),
                                 key: "u",
                                 modifiers: [.command, .shift]))

        let remoteConfigItem = item("Remote config")
        let remoteConfigMenu = NSMenu()
        remoteConfigMenu.addItem(item("Manage",
                                      action: #selector(actionShowRemoteConfigManager(_:)),
                                      key: "m"))
        remoteConfigMenu.addItem(item("Update",
                                      action: #selector(actionUpdateRemoteConfig(_:)),
                                      key: "u"))
        remoteConfigAutoupdateMenuItem = item("Auto Update",
                                              action: #selector(actionAutoUpdateRemoteConfig(_:)))
        remoteConfigMenu.addItem(remoteConfigAutoupdateMenuItem)
        remoteConfigMenu.addItem(item("Set update interval",
                                      action: #selector(actionSetUpdateInterval(_:))))
        remoteConfigItem.submenu = remoteConfigMenu
        configsMenu.addItem(remoteConfigItem)

        let remoteControlItem = item("Remote controller")
        let remoteControlMenu = NSMenu()
        externalControlSeparator = .separator()
        remoteControlMenu.addItem(externalControlSeparator)
        remoteControlMenu.addItem(item(" Manage",
                                       action: #selector(actionShowExternalControlManager(_:))))
        remoteControlItem.submenu = remoteControlMenu
        configsMenu.addItem(remoteControlItem)

        configsItem.submenu = configsMenu
        menu.addItem(configsItem)

        menu.addItem(item("Settings", action: #selector(actionMoreSetting(_:))))

        let helpItem = item("Help")
        let helpMenu = NSMenu()
        helpMenu.addItem(item("About", action: #selector(actionShowAbout(_:))))
        checkForUpdateMenuItem = item("Check Update")
        helpMenu.addItem(checkForUpdateMenuItem)
        logLevelMenuItem = item("Log level")
        let logLevelMenu = NSMenu()
        for level in ["ERROR", "WARNING", "INFO", "DEBUG", "SILENT"] {
            logLevelMenu.addItem(item(level, action: #selector(actionSetLogLevel(_:))))
        }
        logLevelMenuItem.submenu = logLevelMenu
        helpMenu.addItem(logLevelMenuItem)
        helpMenu.addItem(item("Show Log", action: #selector(actionShowLog(_:)), key: "l"))
        let portsItem = item("Ports")
        let portsMenu = NSMenu()
        httpPortMenuItem = item("http port:")
        socksPortMenuItem = item("socks port:")
        apiPortMenuItem = item("api port:")
        ipMenuItem = item("IP:")
        for portItem in [httpPortMenuItem, socksPortMenuItem, apiPortMenuItem, ipMenuItem] {
            portItem?.isEnabled = false
            if let portItem {
                portsMenu.addItem(portItem)
            }
        }
        portsItem.submenu = portsMenu
        helpMenu.addItem(portsItem)
        helpItem.submenu = helpMenu
        menu.addItem(helpItem)

        menu.addItem(item("Quit", action: #selector(actionQuit(_:)), key: "q"))

        return menu
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return TerminalConfirmAction.run()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        UserDefaults.standard.set(0, forKey: "launch_fail_times")
        Logger.log("Waypoint will terminate")
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

    func setupStatusMenuItemData() {
        enhanceTunModeMenuItem.state = Settings.tunEnabled ? .on : .off
        // The remaining publishers drive the NSStatusItem view only.
        guard !Settings.useSwiftUIMenu else { return }
        ConfigManager.shared
            .showNetSpeedIndicatorPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.showNetSpeedIndicatorMenuItem.state = show ? .on : .off
                    let statusItemLength: CGFloat = show ? statusItemLengthWithSpeed : 25
                    self.statusItem.length = statusItemLength
                    self.statusItemView.updateSize(width: statusItemLength)
                    self.statusItemView.showSpeedContainer(show: show)
                }
            }.store(in: &cancellables)

        statusItemView.updateViewStatus(enableProxy: ConfigManager.shared.proxyPortAutoSet)
    }

    func setupData() {
        SSIDSuspendTool.shared.setup()
        ConfigManager.shared
            .showNetSpeedIndicatorPublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resetStreamApi()
                }
            }.store(in: &cancellables)

        Publishers.Merge3(ConfigManager.shared.proxyPortAutoSetPublisher,
                          ConfigManager.shared.isProxySetByOtherPublisher,
                          ConfigManager.shared.proxyShouldPausedPublisher)
            .receive(on: DispatchQueue.main)
            .map { _ -> NSControl.StateValue in
                MainActor.assumeIsolated {
                    if (ConfigManager.shared.isProxySetByOther || ConfigManager.shared.proxyShouldPaused) && ConfigManager.shared.proxyPortAutoSet {
                        return .mixed
                    }
                    return ConfigManager.shared.proxyPortAutoSet ? .on : .off
                }
            }.removeDuplicates()
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.proxySettingMenuItem.state = status
                    self.statusItemView.updateViewStatus(enableProxy: status == .on)
                }
            }.store(in: &cancellables)

        let configPublisher = ConfigManager.shared.currentConfigPublisher
        Publishers.Zip(configPublisher, configPublisher.dropFirst())
            .filter { $1 != nil }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] old, config in
                MainActor.assumeIsolated {
                    guard let self, let config else { return }
                    self.proxyModeDirectMenuItem.state = .off
                    self.proxyModeGlobalMenuItem.state = .off
                    self.proxyModeRuleMenuItem.state = .off

                    switch config.mode {
                    case .direct: self.proxyModeDirectMenuItem.state = .on
                    case .global: self.proxyModeGlobalMenuItem.state = .on
                    case .rule: self.proxyModeRuleMenuItem.state = .on
                    }
                    self.allowFromLanMenuItem.state = config.allowLan ? .on : .off

                    self.proxyModeMenuItem.title = "\(NSLocalizedString("Proxy Mode", comment: "")) (\(config.mode.name))"

                    if old?.usedHttpPort != config.usedHttpPort || old?.usedSocksPort != config.usedSocksPort {
                        Logger.log("port config updated,new: \(config.usedHttpPort),\(config.usedSocksPort)")
                        if ConfigManager.shared.proxyPortAutoSet {
                            SystemProxyManager.shared.enableProxy(port: config.usedHttpPort, socksPort: config.usedSocksPort)
                        }
                    }

                    self.httpPortMenuItem.title = "Http Port: \(config.usedHttpPort)"
                    self.socksPortMenuItem.title = "Socks Port: \(config.usedSocksPort)"
                    self.apiPortMenuItem.title = "Api Port: \(ConfigManager.shared.apiPort)"
                    self.ipMenuItem.title = "IP: \(NetworkChangeNotifier.getPrimaryIPAddress() ?? "")"

                    if RemoteControlManager.selectConfig == nil {
                        WaypointStatusTool.checkPortConfig(cfg: config)
                    }
                }
            }.store(in: &cancellables)

        if !PrivilegedHelperManager.shared.isHelperCheckFinished.value &&
            ConfigManager.shared.proxyPortAutoSet {
            PrivilegedHelperManager.shared.isHelperCheckFinished
                .first { $0 }
                .receive(on: DispatchQueue.main)
                .sink { _ in
                    MainActor.assumeIsolated {
                        if ConfigManager.shared.proxyPortAutoSet {
                            SystemProxyManager.shared.enableProxy()
                        }
                    }
                }.store(in: &cancellables)
        } else if ConfigManager.shared.proxyPortAutoSet {
            SystemProxyManager.shared.enableProxy()
        }

        LaunchAtLogin.shared
            .isEnableVirable
            .receive(on: DispatchQueue.main)
            .sink { enable in
                MainActor.assumeIsolated {
                    AppDelegate.shared.autoStartMenuItem.state = enable ? .on : .off
                }
            }.store(in: &cancellables)

        remoteConfigAutoupdateMenuItem.state = RemoteConfigManager.autoUpdateEnable ? .on : .off

        if !PrivilegedHelperManager.shared.isHelperCheckFinished.value {
            proxySettingMenuItem.target = nil
            PrivilegedHelperManager.shared.isHelperCheckFinished
                .first { $0 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.proxySettingMenuItem.target = self
                    }
                }.store(in: &cancellables)
        }
    }

    func setupNetworkNotifier() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            NetworkChangeNotifier.start()
        }

        NotificationCenter.default
            .publisher(for: .systemNetworkStatusDidChange)
            .receive(on: DispatchQueue.main)
            .delay(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated {
                    guard NetworkChangeNotifier.getPrimaryInterface() != nil else { return }
                    let proxySetted = NetworkChangeNotifier.isCurrentSystemSetToWaypoint()
                    ConfigManager.shared.isProxySetByOther = !proxySetted
                    if !proxySetted && ConfigManager.shared.proxyPortAutoSet {
                        let proxiesSetting = NetworkChangeNotifier.getRawProxySetting()
                        Logger.log("Proxy changed by other process!, current:\(proxiesSetting), is Interface Set: \(NetworkChangeNotifier.hasInterfaceProxySetToWaypoint())", level: .warning)
                    }
                }
            }.store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(resetProxySettingOnWakeupFromSleep),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        NotificationCenter.default
            .publisher(for: .systemNetworkStatusIPUpdate)
            .map { _ in NetworkChangeNotifier.getPrimaryIPAddress(allowIPV6: false) }
            .prepend(NetworkChangeNotifier.getPrimaryIPAddress(allowIPV6: false))
            .removeDuplicates()
            .dropFirst()
            .filter { $0 != nil }
            .receive(on: DispatchQueue.main)
            .debounce(for: .seconds(5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.healthCheckOnNetworkChange()
                }
            }.store(in: &cancellables)

        ConfigManager.shared
            .isProxySetByOtherPublisher
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated {
                    guard ConfigManager.shared.proxyPortAutoSet, !ConfigManager.shared.proxyShouldPaused else { return }
                    let rawProxy = NetworkChangeNotifier.getRawProxySetting()
                    Logger.log("proxy changed to no Waypoint setting: \(rawProxy)", level: .warning)
                    WaypointNotifier.postProxyChangeByOtherAppNotice()
                }
            }.store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .systemNetworkStatusIPUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    if RemoteControlManager.selectConfig != nil {
                        self?.resetStreamApi()
                    }
                }
            }.store(in: &cancellables)
    }

    func updateProxyList(withMenus menus: [NSMenuItem]) {
        let startIndex = statusMenu.items.firstIndex(of: separatorLineTop)! + 1
        let endIndex = statusMenu.items.firstIndex(of: sepatatorLineEndProxySelect)!
        sepatatorLineEndProxySelect.isHidden = menus.isEmpty
        for _ in 0 ..< endIndex - startIndex {
            statusMenu.removeItem(at: startIndex)
        }
        for each in menus {
            statusMenu.insertItem(each, at: startIndex)
        }
    }

    func updateConfigFiles() {
        guard let menu = configSeparatorLine.menu else { return }
        MenuItemFactory.generateSwitchConfigMenuItems {
            items in
            let lineIndex = menu.items.firstIndex(of: self.configSeparatorLine)!
            for _ in 0 ..< lineIndex {
                menu.removeItem(at: 0)
            }
            for item in items.reversed() {
                menu.insertItem(item, at: 0)
            }
        }
    }

    func updateLoggingLevel() {
        Task { _ = await ApiRequest.updateLogLevel(ConfigManager.selectLoggingApiLevel) }
        for item in logLevelMenuItem.submenu?.items ?? [] {
            item.state = item.title.lowercased() == ConfigManager.selectLoggingApiLevel.rawValue ? .on : .off
        }
        NotificationCenter.default.post(name: .reloadDashboard, object: nil)
    }

    func startProxy() {
        if ConfigManager.shared.isRunning { return }

        if !Settings.isApiSecretSet {
            if #available(macOS 11.0, *), let password = SecCreateSharedWebCredentialPassword() as? String {
                Settings.apiSecret = password
            } else {
                Settings.apiSecret = UUID().uuidString
            }
        }

        let secret = ConfigManager.shared.overrideSecret ?? Settings.apiSecret
        let port = Settings.apiPort > 0 ? Settings.apiPort : 9090
        let apiAddr = Settings.apiPortAllowLan ? "0.0.0.0:\(port)" : "127.0.0.1:\(port)"

        var externalUI: String?
        if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html", inDirectory: "dashboard") {
            externalUI = URL(fileURLWithPath: htmlPath).deletingLastPathComponent().path
        }

        Logger.log("Trying start proxy, allow lan: \(ConfigManager.allowConnectFromLan) custom port: \(Settings.proxyPort)")

        Task { [weak self] in
            guard let self else { return }
            MitmProxyServer.ensureRunning()
            let configPath: String = await withCheckedContinuation { continuation in
                ConfigManager.getEffectiveConfigPath(configName: ConfigManager.selectConfigName) {
                    continuation.resume(returning: $0)
                }
            }

            CoreProcessManager.shared.onUnexpectedExit = { [weak self] in
                ConfigManager.shared.isRunning = false
                MitmProxyServer.shared.stop()
                self?.proxyModeMenuItem.isEnabled = false
                self?.dashboardMenuItem.isEnabled = false
                WaypointNotifier.postConfigErrorNotice(msg: "mihomo core exited unexpectedly.")
            }

            do {
                try await CoreProcessManager.shared.start(configPath: configPath,
                                                          homeDir: kConfigFolderPath,
                                                          externalController: apiAddr,
                                                          secret: secret,
                                                          externalUI: externalUI)
                ConfigManager.shared.allowExternalControl = !apiAddr.contains("127.0.0.1") && !apiAddr.contains("localhost")
                ConfigManager.shared.apiPort = String(port)
                ConfigManager.shared.apiSecret = secret
                ConfigManager.shared.isRunning = true
                self.proxyModeMenuItem.isEnabled = true
                self.dashboardMenuItem.isEnabled = true
                if Settings.killSwitchEnabled {
                    if let killSwitchError = await KillSwitchManager.shared.applyNow() {
                        Logger.log("kill switch failed: \(killSwitchError)", level: .error)
                    }
                }
            } catch {
                ConfigManager.shared.isRunning = false
                self.proxyModeMenuItem.isEnabled = false
                Logger.log(error.localizedDescription, level: .error)
                WaypointNotifier.postConfigErrorNotice(msg: error.localizedDescription)
            }
            Logger.log("Start proxy done")
        }
    }

    func applyRuntimeGeneralSettings() async {
        await selectAllowLanWithMenory()
        await ApiRequest.updateIPv6(Settings.enableIPV6)
        if Settings.proxyPort > 0 {
            await ApiRequest.updateProxyPort(Settings.proxyPort)
        }
    }

    func syncConfig() {
        Task {
            ConfigManager.shared.currentConfig = await ApiRequest.requestConfig()
        }
    }

    func resetStreamApi() {
        trafficStreamTask?.cancel()
        logStreamTask?.cancel()
        let apiRequest = ApiRequest.client
        trafficStreamTask = Task { [weak self] in
            for await traffic in await apiRequest.trafficStream() {
                self?.statusItemView.updateSpeedLabel(up: traffic.up, down: traffic.down)
            }
        }
        logStreamTask = Task {
            for await entry in await apiRequest.logStream(level: ConfigManager.selectLoggingApiLevel.rawValue) {
                Logger.log(entry.log, level: WaypointLogLevel(rawValue: entry.level) ?? .unknow)
            }
        }
    }

    func updateConfig(configName: String? = nil, showNotification: Bool = true, completeHandler: ((ErrorString?) -> Void)? = nil) {
        startProxy()
        guard ConfigManager.shared.isRunning else { return }

        let config = configName ?? ConfigManager.selectConfigName

        ProxyNameMeasurer.cleanCache()

        Task { [weak self] in
            guard let self else { return }
            var err: ErrorString?
            do {
                try await ApiRequest.requestConfigUpdate(configName: config)
            } catch {
                err = error.localizedDescription
            }

            defer {
                completeHandler?(err)
            }

            if let err {
                UpdateConfigAction.showError(text: err, configName: config)
            } else {
                self.syncConfig()
                self.resetStreamApi()
                self.runAfterConfigReload?()
                self.runAfterConfigReload = nil
                if showNotification {
                    WaypointNotifier
                        .post(title: NSLocalizedString("Reload Config Succeed", comment: ""),
                              info: NSLocalizedString("Success", comment: ""))
                }

                if let newConfigName = configName {
                    ConfigManager.selectConfigName = newConfigName
                }
                self.selectProxyGroupWithMemory()
                await self.selectOutBoundModeWithMenory()
                MenuItemFactory.recreateProxyMenuItems()
                NotificationCenter.default.post(name: .reloadDashboard, object: nil)
            }
        }
    }

    @objc func resetProxySettingOnWakeupFromSleep() {
        guard !ConfigManager.shared.isProxySetByOther,
              ConfigManager.shared.proxyPortAutoSet else { return }
        guard NetworkChangeNotifier.getPrimaryInterface() != nil else { return }
        if !NetworkChangeNotifier.isCurrentSystemSetToWaypoint() {
            let rawProxy = NetworkChangeNotifier.getRawProxySetting()
            Logger.log("Resting proxy setting, current:\(rawProxy)", level: .warning)
            SystemProxyManager.shared.disableProxy()
            SystemProxyManager.shared.enableProxy()
        }

        if RemoteControlManager.selectConfig != nil {
            resetStreamApi()
        }
    }

    @objc func healthCheckOnNetworkChange() {
        Task {
            guard let proxyResp = await ApiRequest.getMergedProxyData() else { return }

            var providers = Set<WaypointProxyName>()

            let groups = proxyResp.proxyGroups.filter(\.type.isAutoGroup)
            for group in groups {
                group.all?.compactMap {
                    proxyResp.providerNamesByProxy[$0]
                }.forEach {
                    providers.insert($0)
                }
            }

            for group in groups {
                Logger.log("Start auto health check for group \(group.name)")
            }
            for provider in providers {
                Logger.log("Start auto health check for provider \(provider)")
            }

            await withTaskGroup(of: Void.self) { taskGroup in
                for group in groups {
                    // Capture the Sendable name, not the non-Sendable group.
                    let name = group.name
                    taskGroup.addTask { await ApiRequest.healthCheck(proxy: name) }
                }
                for provider in providers {
                    taskGroup.addTask { await ApiRequest.healthCheck(proxy: provider) }
                }
            }
        }
    }
}

// MARK: Main actions

extension AppDelegate {
    @IBAction func actionDashboard(_ sender: NSMenuItem?) {
        SwiftUIWindowController.create(
            title: "Dashboard",
            content: DashboardRootView()
        ).showWindow(sender)
    }

    @IBAction func actionConnections(_ sender: NSMenuItem?) {
        SwiftUIWindowController.create(
            title: "Connections",
            content: ConnectionsRootView()
        ).showWindow(sender)
    }

    @IBAction func actionAllowFromLan(_ sender: NSMenuItem) {
        Task { [weak self] in
            await ApiRequest.updateAllowLan(!ConfigManager.allowConnectFromLan)
            guard let self else { return }
            self.syncConfig()
            ConfigManager.allowConnectFromLan.toggle()
        }
    }

    @IBAction func actionEnhanceTunMode(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        Settings.tunEnabled = enable
        sender.state = enable ? .on : .off
        // The tun block is injected at config-derivation time, so the core
        // must fully restart; a hot reload is not enough.
        CoreProcessManager.shared.stop()
        ConfigManager.shared.isRunning = false
        startProxy()
        Task { [weak self, enable] in
            // CoreProcessManager probes readiness for up to 10s before
            // settling isRunning; give the start attempt time to settle.
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard ConfigManager.shared.isRunning else { continue }
                return
            }
            guard let self, !ConfigManager.shared.isRunning else { return }
            // Start failed (e.g. helper unavailable); revert the toggle.
            Settings.tunEnabled = !enable
            self.enhanceTunModeMenuItem.state = enable ? .off : .on
            WaypointNotifier
                .post(title: NSLocalizedString("Enhanced Mode Failed", comment: ""),
                      info: NSLocalizedString("Failed to apply Enhanced Mode. Please install the helper tool first.", comment: ""))
        }
    }

    @IBAction func actionStartAtLogin(_ sender: NSMenuItem) {
        LaunchAtLogin.shared.isEnabled = !LaunchAtLogin.shared.isEnabled
    }

    @IBAction func actionSwitchProxyMode(_ sender: NSMenuItem) {
        let mode: WaypointProxyMode
        switch sender {
        case proxyModeGlobalMenuItem:
            mode = .global
        case proxyModeDirectMenuItem:
            mode = .direct
        case proxyModeRuleMenuItem:
            mode = .rule
        default:
            return
        }
        switchProxyMode(mode: mode)
    }

    func switchProxyMode(mode: WaypointProxyMode) {
        let config = ConfigManager.shared.currentConfig?.copy()
        config?.mode = mode
        Task {
            _ = await ApiRequest.updateOutBoundMode(mode)
            ConfigManager.shared.currentConfig = config
            ConfigManager.selectOutBoundMode = mode
            MenuItemFactory.recreateProxyMenuItems()
        }
    }

    @IBAction func actionShowNetSpeedIndicator(_ sender: NSMenuItem) {
        ConfigManager.shared.showNetSpeedIndicator = !(sender.state == .on)
    }

    @IBAction func actionSetSystemProxy(_ sender: Any?) {
        var canSaveProxy = true
        if ConfigManager.shared.proxyPortAutoSet && ConfigManager.shared.proxyShouldPaused {
            ConfigManager.shared.proxyPortAutoSet = false
        } else if ConfigManager.shared.isProxySetByOther {
            // should reset proxy to waypoint
            ConfigManager.shared.isProxySetByOther = false
            ConfigManager.shared.proxyPortAutoSet = true
            // clear then reset.
            canSaveProxy = false
            SystemProxyManager.shared.disableProxy(port: 0, socksPort: 0, forceDisable: true)
        } else {
            ConfigManager.shared.proxyPortAutoSet = !ConfigManager.shared.proxyPortAutoSet
        }

        if ConfigManager.shared.proxyPortAutoSet {
            if canSaveProxy {
                SystemProxyManager.shared.saveProxy()
            }
            SystemProxyManager.shared.enableProxy()
        } else {
            SystemProxyManager.shared.disableProxy()
        }
    }

    @IBAction func actionCopyExportCommand(_ sender: NSMenuItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let port = ConfigManager.shared.currentConfig?.usedHttpPort ?? 0
        let socksport = ConfigManager.shared.currentConfig?.usedSocksPort ?? 0
        let localhost = "127.0.0.1"
        let isLocalhostCopy = sender == copyExportCommandMenuItem
        let ip = isLocalhostCopy ? localhost :
            NetworkChangeNotifier.getPrimaryIPAddress() ?? localhost
        pasteboard.setString("export https_proxy=http://\(ip):\(port) http_proxy=http://\(ip):\(port) all_proxy=socks5://\(ip):\(socksport)", forType: .string)
    }

    @IBAction func actionSpeedTest(_ sender: Any) {
        if isSpeedTesting {
            WaypointNotifier.postSpeedTestingNotice()
            return
        }
        WaypointNotifier.postSpeedTestBeginNotice()

        isSpeedTesting = true

        Task { [weak self] in
            let resp = await ApiRequest.getMergedProxyData()
            let group = DispatchGroup()

            for (name, _) in resp?.enclosingProviderResp?.providers ?? [:] {
                group.enter()
                Task {
                    await ApiRequest.healthCheck(proxy: name)
                    group.leave()
                }
            }

            for p in resp?.proxiesMap["GLOBAL"]?.all ?? [] {
                group.enter()
                Task {
                    _ = await ApiRequest.getProxyDelay(proxyName: p)
                    group.leave()
                }
            }
            group.notify(queue: DispatchQueue.main) { [weak self] in
                MainActor.assumeIsolated {
                    WaypointNotifier.postSpeedTestFinishNotice()
                    self?.isSpeedTesting = false
                }
            }
        }
    }

    @IBAction func actionUpdateExternalResource(_ sender: Any) {
        UpdateExternalResourceAction.run()
    }

    @IBAction func actionQuit(_ sender: Any) {
        NSApplication.shared.terminate(self)
    }

    @IBAction func actionMoreSetting(_ sender: Any) {
        SwiftUIWindowController.create(
            title: "Settings",
            content: SettingsRootView()
        ).showWindow(sender)
    }
}

// MARK: Help actions

extension AppDelegate {
    @IBAction func actionShowLog(_ sender: Any?) {
        NSWorkspace.shared.open(URL(fileURLWithPath: Logger.shared.logFilePath()))
    }

    @IBAction func actionShowAbout(_ sender: Any?) {
        SwiftUIWindowController.create(
            title: "About",
            content: AboutView()
        ).showWindow(sender)
    }
}

// MARK: Manager windows

extension AppDelegate {
    @IBAction func actionShowRemoteConfigManager(_ sender: Any?) {
        SwiftUIWindowController.create(
            title: NSLocalizedString("Remote config", comment: ""),
            minimumSize: CGSize(width: 460, height: 260),
            content: RemoteConfigRootView()
        ).showWindow(sender)
    }

    @IBAction func actionShowExternalControlManager(_ sender: Any?) {
        SwiftUIWindowController.create(
            title: NSLocalizedString("Remote controller", comment: ""),
            minimumSize: CGSize(width: 460, height: 220),
            content: ExternalControlRootView()
        ).showWindow(sender)
    }
}

// MARK: Config actions

extension AppDelegate {
    @IBAction func openConfigFolder(_ sender: Any) {
        if ICloudManager.shared.useiCloud.value {
            Task {
                let url: URL? = await withCheckedContinuation { continuation in
                    ICloudManager.shared.getUrl { continuation.resume(returning: $0) }
                }
                if let url {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: kConfigFolderPath))
        }
    }

    @IBAction func actionUpdateConfig(_ sender: AnyObject) {
        updateConfig()
    }

    @IBAction func actionSetLogLevel(_ sender: NSMenuItem) {
        let level = WaypointLogLevel(rawValue: sender.title.lowercased()) ?? .unknow
        ConfigManager.selectLoggingApiLevel = level
        dynamicLogLevel = level.toDDLogLevel()
        updateLoggingLevel()
        resetStreamApi()
    }

    @IBAction func actionAutoUpdateRemoteConfig(_ sender: Any) {
        RemoteConfigManager.autoUpdateEnable = !RemoteConfigManager.autoUpdateEnable
        remoteConfigAutoupdateMenuItem.state = RemoteConfigManager.autoUpdateEnable ? .on : .off
    }

    @IBAction func actionUpdateRemoteConfig(_ sender: Any) {
        RemoteConfigManager.shared.updateCheck(ignoreTimeLimit: true, showNotification: true)
    }

    @IBAction func actionSetUpdateInterval(_ sender: Any) {
        RemoteConfigManager.showAdd()
    }
}

// MARK: crash hanlder

extension AppDelegate {
    func failLaunchProtect() {
        #if DEBUG
            return
        #else
            UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": false])
            let x = UserDefaults.standard
            var launch_fail_times = 0
            if let xx = x.object(forKey: "launch_fail_times") as? Int { launch_fail_times = xx }
            launch_fail_times += 1
            x.set(launch_fail_times, forKey: "launch_fail_times")
            if launch_fail_times > 3 {
                // consecutive crashes — reset state for a clean launch
                ConfigFileManager.backupAndRemoveConfigFile()
                try? FileManager.default.removeItem(atPath: kConfigFolderPath + "Country.mmdb")
                if let domain = Bundle.main.bundleIdentifier {
                    UserDefaults.standard.removePersistentDomain(forName: domain)
                    UserDefaults.standard.synchronize()
                }
                WaypointNotifier.post(title: "Fail on launch protect", info: "You origin Config has been renamed", notiOnly: false)
            }
            DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + Double(Int64(5 * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)) {
                x.set(0, forKey: "launch_fail_times")
            }
        #endif
    }
}

// MARK: Memory

extension AppDelegate {
    func selectProxyGroupWithMemory() {
        let copy = [SavedProxyModel](ConfigManager.selectedProxyRecords)
        for item in copy {
            guard item.config == ConfigManager.selectConfigName else { continue }
            Logger.log("Auto selecting \(item.group) \(item.selected)", level: .debug)
            Task {
                let success = await ApiRequest.updateProxyGroup(group: item.group, selectProxy: item.selected)
                if !success {
                    ConfigManager.selectedProxyRecords.removeAll { model -> Bool in
                        return model.key == item.key
                    }
                }
            }
        }
    }

    func removeUnExistProxyGroups() {
        let action: (([String]) -> Void) = { list in
            let unexists = ConfigManager.selectedProxyRecords.filter {
                !list.contains($0.config)
            }
            ConfigManager.selectedProxyRecords.removeAll {
                unexists.contains($0)
            }
        }

        if ICloudManager.shared.useiCloud.value {
            Task {
                let list: [String] = await withCheckedContinuation { continuation in
                    ICloudManager.shared.getConfigFilesList { continuation.resume(returning: $0) }
                }
                action(list)
            }
        } else {
            let list = ConfigManager.getConfigFilesList()
            action(list)
        }
    }

    func selectOutBoundModeWithMenory() async {
        _ = await ApiRequest.updateOutBoundMode(ConfigManager.selectOutBoundMode)
        ConnectionManager.closeAllConnection()
        syncConfig()
    }

    func selectAllowLanWithMenory() async {
        await ApiRequest.updateAllowLan(ConfigManager.allowConnectFromLan)
        syncConfig()
    }

    func hasMenuSelected() -> Bool {
        if #available(macOS 11, *) {
            return statusMenu.items.contains { $0.state == .on }
        } else {
            return true
        }
    }
}

// MARK: NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        MenuItemFactory.refreshExistingMenuItems()
        updateConfigFiles()
        syncConfig()
        NotificationCenter.default.post(name: .proxyMeneViewShowLeftPadding,
                                        object: nil,
                                        userInfo: ["show": hasMenuSelected()])
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        menu.items.forEach {
            ($0.view as? ProxyGroupMenuHighlightDelegate)?.highlight(item: item)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menu.items.forEach {
            ($0.view as? ProxyGroupMenuHighlightDelegate)?.highlight(item: nil)
        }
    }
}

// MARK: URL Scheme

extension AppDelegate {
    @objc func handleURL(event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
            return
        }

        guard let components = URLComponents(string: url),
              let scheme = components.scheme,
              scheme.hasPrefix("waypoint"),
              let host = components.host
        else { return }

        if host == "install-config" {
            guard let url = components.queryItems?.first(where: { item in
                item.name == "url"
            })?.value else { return }

            var userInfo = ["url": url]
            if let name = components.queryItems?.first(where: { item in
                item.name == "name"
            })?.value {
                userInfo["name"] = name
            }

            remoteConfigAutoupdateMenuItem.menu?.performActionForItem(at: 0)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(name: Notification.Name(rawValue: "didGetUrl"), object: nil, userInfo: userInfo)
            }
        } else if host == "update-config" {
            updateConfig()
        }
    }
}
