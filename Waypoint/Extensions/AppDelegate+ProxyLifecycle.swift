//
//  AppDelegate+ProxyLifecycle.swift
//  Waypoint
//
//  Core (mihomo) process lifecycle and config reload orchestration.
//

import Cocoa
import WaypointNetworking

extension AppDelegate {
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
        Task {
            if !await ApiRequest.updateLogLevel(ConfigManager.selectLoggingApiLevel) {
                Logger.log("failed to update core log level", level: .error)
            }
        }
        for item in logLevelMenuItem.submenu?.items ?? [] {
            item.state = item.title.lowercased() == ConfigManager.selectLoggingApiLevel.rawValue ? .on : .off
        }
        NotificationCenter.default.post(name: .reloadDashboard, object: nil)
    }

    func startProxy() {
        // Guard concurrent starts too: isRunning only becomes true after full
        // startup success, so without this overlapping invocations (menu
        // toggle + config reload + network change) each kill the previous
        // attempt's core during the up-to-10s readiness window.
        if ConfigManager.shared.isRunning || coreStartInFlight { return }
        coreStartInFlight = true

        // Cleared synchronously so a stale failure from a previous attempt
        // can't abort an updateConfig poll that started before this Task.
        lastCoreStartError = nil

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
            defer { self.coreStartInFlight = false }
            MitmProxyServer.ensureRunning()
            let configPath: String = await withCheckedContinuation { continuation in
                ConfigManager.getEffectiveConfigPath(configName: ConfigManager.selectConfigName) {
                    continuation.resume(returning: $0)
                }
            }

            CoreProcessManager.shared.onUnexpectedExit = { [weak self] in
                ConfigManager.shared.isRunning = false
                MitmProxyServer.shared.stop()
                // The core held the pf anchor's pass rules; drop the lockout
                // immediately so the user keeps network access.
                Task { await KillSwitchManager.shared.clear() }
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
                lastCoreStartError = error
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

        let config = configName ?? ConfigManager.selectConfigName

        ProxyNameMeasurer.cleanCache()

        Task { [weak self] in
            guard let self else { return }
            // startProxy() launches the core asynchronously (readiness alone
            // can take up to 10s), so wait for it here instead of failing on
            // a synchronous isRunning check that would always be false. The
            // wait ends early once the start attempt reports a failure.
            var waitedNanos = 0
            while !ConfigManager.shared.isRunning,
                  lastCoreStartError == nil,
                  waitedNanos < 11_000_000_000 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                waitedNanos += 200_000_000
            }
            guard ConfigManager.shared.isRunning else {
                // The start attempt failed (its real error is posted by
                // startProxy's catch); surface the failure to this caller too.
                let err: ErrorString = lastCoreStartError?.localizedDescription
                    ?? NSLocalizedString("Proxy core is not running. Check the log for details.", comment: "")
                UpdateConfigAction.showError(text: err, configName: config)
                completeHandler?(err)
                return
            }
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
