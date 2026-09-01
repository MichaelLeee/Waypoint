//
//  AppDelegate+Observers.swift
//  Waypoint
//
//  Menu/status-item data bindings: NotificationCenter publishers replacing
//  the old ConfigManager Combine bridge.
//

import Cocoa
import Combine
import WaypointNetworking

extension AppDelegate {
    func setupStatusMenuItemData() {
        enhanceTunModeMenuItem.state = Settings.tunEnabled ? .on : .off
        // The remaining publishers drive the NSStatusItem view only.
        guard !Settings.useSwiftUIMenu else { return }
        NotificationCenter.default
            .publisher(for: .waypointShowNetSpeedIndicatorDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let show = ConfigManager.shared.showNetSpeedIndicator
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
        NotificationCenter.default
            .publisher(for: .waypointShowNetSpeedIndicatorDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resetStreamApi()
                }
            }.store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .waypointProxyStatusDidChange)
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

        NotificationCenter.default
            .publisher(for: .waypointCurrentConfigDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard configStreamPrimed else {
                        configStreamPrimed = true
                        previousStreamedConfig = ConfigManager.shared.currentConfig
                        return
                    }
                    let old = previousStreamedConfig
                    let config = ConfigManager.shared.currentConfig
                    previousStreamedConfig = config
                    guard let config else { return }
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

        NotificationCenter.default
            .publisher(for: .waypointProxyStatusDidChange)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated {
                    let setByOther = ConfigManager.shared.isProxySetByOther
                    guard setByOther != lastSetByOtherObserved else { return }
                    lastSetByOtherObserved = setByOther
                    guard setByOther else { return }
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
}
