//
//  MenuBarMenuView.swift
//  Waypoint
//  SwiftUI comparison version of the status menu (Settings.useSwiftUIMenu).
//  Rendered via MenuBarExtra(.window) instead of NSStatusItem + NSMenu.
//

import AppKit
import SwiftUI

/// No-op status view used while the MenuBarExtra flag is on, so the legacy
/// call sites (speed labels, status tint) stay safe without an NSStatusItem.
@MainActor
final class NullStatusItemView: StatusItemViewProtocol {
    func updateViewStatus(enableProxy: Bool) {}
    func updateSpeedLabel(up: Int, down: Int) {}
    func showSpeedContainer(show: Bool) {}
    func updateSize(width: CGFloat) {}
}

@MainActor
@Observable
final class MenuBarMenuStore {
    var proxyGroups: [WaypointProxy] = []
    var configNames: [String] = []
    var launchAtLogin = LaunchAtLogin.shared.isEnabled {
        didSet { LaunchAtLogin.shared.isEnabled = launchAtLogin }
    }
    var isSpeedTesting = false

    init() {
        refresh()
    }

    func refresh() {
        if ICloudManager.shared.useiCloud.value {
            ICloudManager.shared.getConfigFilesList { [weak self] list in
                self?.configNames = list
            }
        } else {
            configNames = ConfigManager.getConfigFilesList()
        }
        Task { [weak self] in
            guard let resp = await ApiRequest.getMergedProxyData() else { return }
            self?.proxyGroups = resp.proxyGroups
        }
    }

    func selectProxy(group: WaypointProxy, proxy: String) {
        Task {
            guard await ApiRequest.updateProxyGroup(group: group.name, selectProxy: proxy) else { return }
            let newModel = SavedProxyModel(group: group.name, selected: proxy, config: ConfigManager.selectConfigName)
            ConfigManager.selectedProxyRecords.removeAll { $0.key == newModel.key }
            ConfigManager.selectedProxyRecords.append(newModel)
            ConnectionManager.closeConnection(for: group.name)
            MenuItemFactory.refreshExistingMenuItems()
            refresh()
        }
    }

    func switchProxyMode(mode: WaypointProxyMode) {
        let config = ConfigManager.shared.currentConfig?.copy()
        config?.mode = mode
        Task {
            _ = await ApiRequest.updateOutBoundMode(mode)
            ConfigManager.shared.currentConfig = config
            ConfigManager.selectOutBoundMode = mode
            MenuItemFactory.recreateProxyMenuItems()
            refresh()
        }
    }

    func toggleSystemProxy() {
        AppDelegate.shared.actionSetSystemProxy(nil)
    }

    func toggleEnhancedMode() {
        // Reuses the AppDelegate action: full core restart + revert on failure,
        // and keeps the (hidden) menu item checkmark in sync.
        AppDelegate.shared.actionEnhanceTunMode(AppDelegate.shared.enhanceTunModeMenuItem)
    }

    func copyExportCommand(external: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let port = ConfigManager.shared.currentConfig?.usedHttpPort ?? 0
        let socksPort = ConfigManager.shared.currentConfig?.usedSocksPort ?? 0
        let localhost = "127.0.0.1"
        let ip = external ? NetworkChangeNotifier.getPrimaryIPAddress() ?? localhost : localhost
        pasteboard.setString("export https_proxy=http://\(ip):\(port) http_proxy=http://\(ip):\(port) all_proxy=socks5://\(ip):\(socksport)", forType: .string)
    }

    func speedTest() {
        if isSpeedTesting { return }
        isSpeedTesting = true
        AppDelegate.shared.actionSpeedTest(NSApplication.shared)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            self?.isSpeedTesting = false
        }
    }

    func selectConfig(_ name: String) {
        AppDelegate.shared.updateConfig(configName: name, showNotification: false) { err in
            if err == nil {
                ConnectionManager.closeAllConnection()
            }
        }
    }
}
struct MenuBarMenuView: View {
    @State private var store = MenuBarMenuStore()
    private var configManager = ConfigManager.shared

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                Divider()
                proxyGroupsSection
                Divider()
                proxyModeSection
                togglesSection
                Divider()
                actionsSection
                Divider()
                configsSection
                Divider()
                helpSection
                Divider()
                HStack {
                    Spacer()
                    Button(NSLocalizedString("Quit", comment: "")) {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q")
                }
            }
            .padding(12)
        }
        .frame(width: 300, height: 420)
        .onAppear { store.refresh() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(configManager.isRunning ? "WaypointConnected" : "WaypointDisconnected")
                .resizable()
                .frame(width: 14, height: 14)
            Text(configManager.isRunning
                 ? NSLocalizedString("Connected", comment: "")
                 : NSLocalizedString("Disconnected", comment: ""))
                .font(.headline)
            Spacer()
        }
    }

    @ViewBuilder
    private var proxyGroupsSection: some View {
        if configManager.isRunning {
            let groups = visibleGroups
            if !groups.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("Proxy Groups", comment: ""))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(groups, id: \.name) { group in
                        groupRow(group)
                    }
                }
            }
        }
    }

    private var visibleGroups: [WaypointProxy] {
        let mode = configManager.currentConfig?.mode ?? .rule
        return store.proxyGroups.filter { group in
            if group.name == "GLOBAL" && mode != .global { return false }
            return WaypointProxyType.isProxyGroup(group)
        }
    }

    @ViewBuilder
    private func groupRow(_ group: WaypointProxy) -> some View {
        if group.type == .select, let all = group.all, let now = group.now {
            HStack {
                Text(group.name).lineLimit(1)
                Spacer()
                Picker(group.name, selection: proxySelection(group: group, current: now)) {
                    ForEach(all, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 150)
            }
        } else {
            HStack {
                Text(group.name).lineLimit(1)
                Spacer()
                Text(group.now ?? "-")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func proxySelection(group: WaypointProxy, current: String) -> Binding<String> {
        Binding(
            get: { current },
            set: { newValue in store.selectProxy(group: group, proxy: newValue) }
        )
    }

    private var proxyModeSection: some View {
        Picker(selection: Binding(
            get: { configManager.currentConfig?.mode ?? .rule },
            set: { store.switchProxyMode(mode: $0) }
        )) {
            ForEach([WaypointProxyMode.rule, .global, .direct], id: \.self) { mode in
                Text(mode.name).tag(mode)
            }
        } label: {
            Text(NSLocalizedString("Proxy Mode", comment: ""))
                .font(.callout)
        }
        .pickerStyle(.segmented)
        .disabled(!configManager.isRunning)
    }

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(NSLocalizedString("Set as system proxy", comment: ""), isOn: Binding(
                get: { configManager.proxyPortAutoSet },
                set: { _ in store.toggleSystemProxy() }
            ))
            Toggle(NSLocalizedString("Enhanced Mode", comment: ""), isOn: Binding(
                get: { Settings.tunEnabled },
                set: { _ in store.toggleEnhancedMode() }
            ))
            Toggle(NSLocalizedString("Allow connect from Lan", comment: ""), isOn: Binding(
                get: { configManager.currentConfig?.allowLan ?? false },
                set: { _ in AppDelegate.shared.actionAllowFromLan(NSMenuItem()) }
            ))
            Toggle(NSLocalizedString("Start at login", comment: ""), isOn: $store.launchAtLogin)
            Toggle(NSLocalizedString("Show network indicator", comment: ""), isOn: Binding(
                get: { configManager.showNetSpeedIndicator },
                set: { _ in configManager.showNetSpeedIndicator.toggle() }
            ))
        }
        .font(.callout)
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(NSLocalizedString("Copy shell command", comment: "")) {
                store.copyExportCommand(external: false)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Button(NSLocalizedString("Benchmark", comment: "")) {
                store.speedTest()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(store.isSpeedTesting)
            Button(NSLocalizedString("Dashboard", comment: "")) {
                AppDelegate.shared.actionDashboard(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(!configManager.isRunning)
            Button(NSLocalizedString("Connection Details", comment: "")) {
                AppDelegate.shared.actionConnections(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(!configManager.isRunning)
        }
    }

    private var configsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: Binding(
                get: { ConfigManager.selectConfigName },
                set: { store.selectConfig($0) }
            )) {
                ForEach(store.configNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            } label: {
                Text(NSLocalizedString("Configs", comment: ""))
                    .font(.callout)
            }
            HStack {
                Button(NSLocalizedString("Reload config", comment: "")) {
                    AppDelegate.shared.updateConfig()
                }
                Button(NSLocalizedString("Settings", comment: "")) {
                    AppDelegate.shared.actionMoreSetting(NSApplication.shared)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    private var helpSection: some View {
        HStack {
            Picker(selection: Binding(
                get: { ConfigManager.selectLoggingApiLevel },
                set: { newLevel in
                    let item = NSMenuItem(title: newLevel.rawValue.uppercased(),
                                          action: nil, keyEquivalent: "")
                    AppDelegate.shared.actionSetLogLevel(item)
                }
            )) {
                ForEach([WaypointLogLevel.error, .warning, .info, .debug, .silent], id: \.self) { level in
                    Text(level.rawValue.uppercased()).tag(level)
                }
            } label: {
                Text(NSLocalizedString("Log level", comment: ""))
                    .font(.callout)
            }
            Spacer()
            Button(NSLocalizedString("Show Log", comment: "")) {
                AppDelegate.shared.actionShowLog(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }
}
