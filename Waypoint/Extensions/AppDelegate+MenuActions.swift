//
//  AppDelegate+MenuActions.swift
//  Waypoint
//
//  @IBAction targets for the status menu and window presentation.
//

import Cocoa
import WaypointNetworking

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
            // The checkmark follows the core's config, so the new value must
            // come from there too — the local persisted flag can disagree
            // (e.g. an imported config with allow-lan: true), which made
            // unchecking re-send "allowed".
            let enable = !(ConfigManager.shared.currentConfig?.allowLan ?? false)
            guard await ApiRequest.updateAllowLan(enable) else { return }
            guard let self else { return }
            self.syncConfig()
            ConfigManager.allowConnectFromLan = enable
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
        Logger.setLevel(level)
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
