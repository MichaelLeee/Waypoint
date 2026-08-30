//
//  AppDelegate.swift
//  Waypoint
//

import Cocoa
import CocoaLumberjack
import CocoaLumberjackSwift
import Combine

let statusItemLengthWithSpeed: CGFloat = 72

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusItem: NSStatusItem!
    @IBOutlet var checkForUpdateMenuItem: NSMenuItem!

    @IBOutlet var statusMenu: NSMenu!
    @IBOutlet var proxySettingMenuItem: NSMenuItem!
    @IBOutlet var autoStartMenuItem: NSMenuItem!

    @IBOutlet var proxyModeGlobalMenuItem: NSMenuItem!
    @IBOutlet var proxyModeDirectMenuItem: NSMenuItem!
    @IBOutlet var proxyModeRuleMenuItem: NSMenuItem!
    @IBOutlet var allowFromLanMenuItem: NSMenuItem!
    @IBOutlet var enhanceTunModeMenuItem: NSMenuItem!

    @IBOutlet var proxyModeMenuItem: NSMenuItem!
    @IBOutlet var showNetSpeedIndicatorMenuItem: NSMenuItem!
    @IBOutlet var dashboardMenuItem: NSMenuItem!
    @IBOutlet var separatorLineTop: NSMenuItem!
    @IBOutlet var sepatatorLineEndProxySelect: NSMenuItem!
    @IBOutlet var configSeparatorLine: NSMenuItem!
    @IBOutlet var logLevelMenuItem: NSMenuItem!
    @IBOutlet var httpPortMenuItem: NSMenuItem!
    @IBOutlet var socksPortMenuItem: NSMenuItem!
    @IBOutlet var apiPortMenuItem: NSMenuItem!
    @IBOutlet var ipMenuItem: NSMenuItem!
    @IBOutlet var remoteConfigAutoupdateMenuItem: NSMenuItem!
    @IBOutlet var copyExportCommandMenuItem: NSMenuItem!
    @IBOutlet var copyExportCommandExternalMenuItem: NSMenuItem!
    @IBOutlet var externalControlSeparator: NSMenuItem!
    @IBOutlet var connectionsMenuItem: NSMenuItem!

    var cancellables = Set<AnyCancellable>()
    private var trafficStreamTask: Task<Void, Never>?
    private var logStreamTask: Task<Void, Never>?
    var statusItemView: StatusItemViewProtocol!
    var isSpeedTesting = false

    var runAfterConfigReload: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Logger.log("applicationWillFinishLaunching")
        signal(SIGPIPE, SIG_IGN)
        // crash recorder
        failLaunchProtect()
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
        // setup menu item first
        statusItem = NSStatusBar.system.statusItem(withLength: statusItemLengthWithSpeed)
        statusItemView = StatusItemView.create(statusItem: statusItem)
        statusItemView.updateSize(width: statusItemLengthWithSpeed)
        statusMenu.delegate = self
        setupStatusMenuItemData()
        DispatchQueue.main.async {
            self.postFinishLaunching()
        }
    }

    func postFinishLaunching() {
        Logger.log("postFinishLaunching")
        defer {
            statusItem.menu = statusMenu
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                self.checkMenuIconVisable()
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
        ConfigManager.shared
            .$showNetSpeedIndicator
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
            .$showNetSpeedIndicator
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resetStreamApi()
                }
            }.store(in: &cancellables)

        Publishers.Merge3(ConfigManager.shared.$proxyPortAutoSet,
                          ConfigManager.shared.$isProxySetByOther,
                          ConfigManager.shared.$proxyShouldPaused)
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

        let configPublisher = ConfigManager.shared.$currentConfig
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
            .$isProxySetByOther
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
        let apiRequest = ApiRequest.shared
        trafficStreamTask = Task { [weak self] in
            for await traffic in apiRequest.trafficStream() {
                self?.statusItemView.updateSpeedLabel(up: traffic.up, down: traffic.down)
            }
        }
        logStreamTask = Task {
            for await entry in apiRequest.logStream() {
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
