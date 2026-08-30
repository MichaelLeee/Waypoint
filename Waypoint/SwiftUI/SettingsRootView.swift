//
//  SettingsRootView.swift
//  Waypoint
//

import AppKit
import KeyboardShortcuts
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case networkAPI = "network_api"
    case tunDNS = "tun_dns"
    case rewrite
    case ignoreLists = "ignore_lists"
    case shortcuts
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return NSLocalizedString("General", comment: "")
        case .networkAPI: return NSLocalizedString("Network & API", comment: "")
        case .tunDNS: return NSLocalizedString("TUN & DNS", comment: "")
        case .rewrite: return NSLocalizedString("Rewrite", comment: "")
        case .ignoreLists: return NSLocalizedString("Ignore Lists", comment: "")
        case .shortcuts: return NSLocalizedString("Shortcuts", comment: "")
        case .debug: return NSLocalizedString("Debug", comment: "")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .networkAPI: return "network"
        case .tunDNS: return "shield.lefthalf.filled"
        case .rewrite: return "pencil.and.outline"
        case .ignoreLists: return "list.bullet.rectangle"
        case .shortcuts: return "command"
        case .debug: return "wrench.and.screwdriver"
        }
    }
}

struct SettingsRootView: View {
    @State private var store = SettingsStore()
    @State private var pane: SettingsPane = .general
    @State private var reloadNote: String?
    @State private var reloadFailed = false
    @State private var showResetDefaultsAlert = false

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            sidebar
                .frame(width: 180)
            Divider()
            Group {
                switch pane {
                case .general: generalPane
                case .networkAPI: networkPane
                case .tunDNS: tunPane
                case .rewrite:
                    RewriteSettingsView(store: store)
                        .padding(.horizontal, 16)
                case .ignoreLists: ignoreListsPane
                case .shortcuts: shortcutsPane
                case .debug: debugPane
                }
            }
            .padding(.vertical, 8)
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $pane) {
            Section(NSLocalizedString("Settings", comment: "")) {
                ForEach(SettingsPane.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .tag(item)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    // MARK: - General

    private var generalPane: some View {
        @Bindable var store = store
        Form {
            Section(NSLocalizedString("Startup", comment: "")) {
                Toggle(NSLocalizedString("Launch at Login", comment: ""), isOn: $store.launchAtLogin)
            }
            Section(NSLocalizedString("Sync", comment: "")) {
                Toggle(
                    NSLocalizedString("Sync configs with iCloud", comment: ""),
                    isOn: $store.useICloud
                )
            }
            Section(NSLocalizedString("Notifications", comment: "")) {
                Toggle(
                    NSLocalizedString("Reduce alerts if notification permission is disabled", comment: ""),
                    isOn: $store.reduceNotifications
                )
            }
            Section(NSLocalizedString("Speed Test", comment: "")) {
                TextField(
                    NSLocalizedString("Benchmark URL", comment: ""),
                    text: $store.benchmarkUrl,
                    prompt: Text(Settings.defaultBenchmarkUrl)
                )
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Network & API

    private var networkPane: some View {
        @Bindable var store = store
        Form {
            Section(NSLocalizedString("Proxy Port (mixed)", comment: "")) {
                TextField("", text: $store.proxyPortText)
                    .textFieldStyle(.roundedBorder)
                Text(NSLocalizedString("0 means using the port from the config file.", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(NSLocalizedString("External Controller", comment: "")) {
                TextField(NSLocalizedString("Port", comment: ""), text: $store.apiPortText)
                    .textFieldStyle(.roundedBorder)
                Toggle(
                    NSLocalizedString("Allow LAN connections to API", comment: ""),
                    isOn: $store.apiPortAllowLan
                )
                SecureField(NSLocalizedString("Secret", comment: ""), text: $store.apiSecret)
                Toggle(
                    NSLocalizedString("Use this secret even if the config defines one", comment: ""),
                    isOn: $store.overrideConfigSecret
                )
            }
            Section {
                Toggle(isOn: $store.enableIPv6) {
                    VStack(alignment: .leading) {
                        Text("IPv6")
                        Text(NSLocalizedString("Applied to the running core immediately.", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - TUN & DNS

    private var tunPane: some View {
        @Bindable var store = store
        Form {
            Section(NSLocalizedString("Enhanced mode", comment: "")) {
                Toggle(isOn: $store.tunEnabled) {
                    VStack(alignment: .leading) {
                        Text("TUN Mode")
                        Text(NSLocalizedString(
                            "Root TUN stack captures all traffic; no system proxy needed.",
                            comment: ""
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $store.fakeIPEnabled) {
                    VStack(alignment: .leading) {
                        Text("Fake-IP DNS")
                        Text(NSLocalizedString(
                            "Fake-IP range 198.18.0.1/16 for near-zero DNS latency and accurate rules.",
                            comment: ""
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle(isOn: $store.killSwitchEnabled) {
                    VStack(alignment: .leading) {
                        Text(NSLocalizedString("Kill Switch", comment: ""))
                        Text(NSLocalizedString(
                            "Firewall-level guard: drops any traffic that tries to bypass Waypoint while the proxy is running.",
                            comment: ""
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(NSLocalizedString("Fail Safety", comment: ""))
            } footer: {
                Text(NSLocalizedString(
                    "Requires the privileged helper. The block is lifted automatically whenever Waypoint quits or the switch is turned off.",
                    comment: ""
                ))
            }
            Section {
                Toggle(isOn: $store.adBlockEnabled) {
                    VStack(alignment: .leading) {
                        Text(NSLocalizedString("Ad & Tracker Blocking", comment: ""))
                        Text(NSLocalizedString(
                            "Rejects ad and tracker domains via geosite categories before any connection is made.",
                            comment: ""
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(NSLocalizedString("Content Blocking", comment: ""))
            } footer: {
                Text(NSLocalizedString(
                    "Blocking rule data (geosite.dat) is downloaded by the core on first use and refreshed with it.",
                    comment: ""
                ))
            }
            Section(NSLocalizedString("Apply", comment: "")) {
                Button(NSLocalizedString("Reload Config Now", comment: "")) {
                    Task {
                        let ok = await store.reloadConfig()
                        reloadFailed = !ok
                        reloadNote = ok
                            ? NSLocalizedString("Configuration reloaded.", comment: "")
                            : NSLocalizedString("Reload failed — is the core running?", comment: "")
                    }
                }
                if let reloadNote {
                    Text(reloadNote)
                        .font(.caption)
                        .foregroundStyle(reloadFailed ? Color.red : Color.green)
                }
                Text(NSLocalizedString(
                    "Toggle changes take effect on config reload or app restart.",
                    comment: ""
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section {
                Button(NSLocalizedString("Flush Fake-IP Cache", comment: "")) {
                    Task { await store.flushFakeIPCache() }
                }
            } footer: {
                Text(NSLocalizedString(
                    "Clears cached Fake-IP mappings if domains resolve oddly after toggling.",
                    comment: ""
                ))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Ignore lists

    private var ignoreListsPane: some View {
        @Bindable var store = store
        Form {
            Section {
                listEditor(text: $store.proxyIgnoreListText)
                Button(NSLocalizedString("Restore Default Ignore List", comment: "")) {
                    store.resetIgnoreList()
                }
            } header: {
                Text("System Proxy Bypass")
            } footer: {
                Text(NSLocalizedString("Comma-separated hosts/CIDRs that bypass the system proxy.", comment: ""))
            }

            Section {
                listEditor(text: $store.ssidSuspendListText)
            } header: {
                Text("Suspend on Wi-Fi Networks")
            } footer: {
                Text(NSLocalizedString(
                    "Comma-separated Wi-Fi SSIDs where Waypoint pauses automatically.",
                    comment: ""
                ))
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            SSIDSuspendTool.shared.showNoticeOnNotPermission = true
            SSIDSuspendTool.shared.requestPermissionIfNeed()
            SSIDSuspendTool.shared.update()
        }
    }

    private func listEditor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.body.monospaced())
            .frame(height: 90)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }

    // MARK: - Shortcuts

    private var shortcutsPane: some View {
        Form {
            GroupBox(NSLocalizedString("Proxy", comment: "")) {
                shortcutRow(NSLocalizedString("Toggle System Proxy", comment: ""), .toggleSystemProxyMode)
                shortcutRow(NSLocalizedString("Copy Shell Command", comment: ""), .copyShellCommand)
                shortcutRow(NSLocalizedString("Copy Shell Command (External)", comment: ""), .copyExternalShellCommand)
            }
            GroupBox(NSLocalizedString("Mode", comment: "")) {
                shortcutRow(NSLocalizedString("Direct Mode", comment: ""), .modeDirect)
                shortcutRow(NSLocalizedString("Rule Mode", comment: ""), .modeRule)
                shortcutRow(NSLocalizedString("Global Mode", comment: ""), .modeGlobal)
            }
            GroupBox(NSLocalizedString("Other", comment: "")) {
                shortcutRow(NSLocalizedString("Open Menu", comment: ""), .openMenu)
                shortcutRow(NSLocalizedString("Open Log", comment: ""), .log)
                shortcutRow(NSLocalizedString("Open Dashboard", comment: ""), .dashboard)
                shortcutRow(NSLocalizedString("Open Connection Details", comment: ""), .nativeDashboard)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ label: String, _ name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(label)
            Spacer()
            ShortcutRecorderView(name: name)
                .frame(width: 160)
        }
    }

    // MARK: - Debug

    private var debugPane: some View {
        @Bindable var store = store
        Form {
            Section(NSLocalizedString("Update Channel", comment: "")) {
                Picker("", selection: $store.updateChannel) {
                    ForEach(AutoUpgardeManager.Channel.allCases, id: \.rawValue) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(!AutoUpgardeManager.shared.canSelectChannel)
                .labelsHidden()
            }
            Section(NSLocalizedString("Proxy Restore", comment: "")) {
                Toggle(
                    NSLocalizedString("Disable restoring proxy state on quit", comment: ""),
                    isOn: Binding(
                        get: { !Settings.disableRestoreProxy },
                        set: { Settings.disableRestoreProxy = !$0 }
                    )
                )
            }
            Section(NSLocalizedString("Files", comment: "")) {
                Button(NSLocalizedString("Open Log Folder", comment: "")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Logger.shared.logFolder()))
                }
                Button(NSLocalizedString("Open Local Config Folder", comment: "")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: kConfigFolderPath))
                }
                Button(NSLocalizedString("Open iCloud Config Folder", comment: "")) {
                    openICloudConfig()
                }
                Button(NSLocalizedString("Open Crash Reports", comment: "")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Logs/DiagnosticReports", isDirectory: true))
                }
            }
            Section(NSLocalizedString("Maintenance", comment: "")) {
                Button(NSLocalizedString("Update GeoIP Database", comment: "")) {
                    WaypointResourceManager.updateGeoIP()
                }
                Button(
                    NSLocalizedString("Uninstall Proxy Helper", comment: ""),
                    role: .destructive
                ) {
                    PrivilegedHelperManager.shared.removeInstallHelper()
                }
                Button(
                    NSLocalizedString("Reset All Settings…", comment: ""),
                    role: .destructive
                ) {
                    showResetDefaultsAlert = true
                }
                .confirmationDialog(
                    NSLocalizedString("Reset all settings?", comment: ""),
                    isPresented: $showResetDefaultsAlert
                ) {
                    Button(NSLocalizedString("Reset and Quit", comment: ""), role: .destructive) {
                        resetUserDefaultsAndQuit()
                    }
                } message: {
                    Text(NSLocalizedString("Click OK to quit the app and apply change.", comment: ""))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func openICloudConfig() {
        if ICloudManager.shared.icloudAvailable {
            ICloudManager.shared.getUrl { url in
                if let url {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            NSAlert.alert(with: NSLocalizedString("iCloud not available", comment: ""))
        }
    }

    private func resetUserDefaultsAndQuit() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        NSApplication.shared.terminate(nil)
    }
}

/// Bridges `KeyboardShortcuts.RecorderCocoa` into SwiftUI.
private struct ShortcutRecorderView: NSViewRepresentable {
    let name: KeyboardShortcuts.Name

    func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
        let view = KeyboardShortcuts.RecorderCocoa(for: name)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateNSView(_ nsView: KeyboardShortcuts.RecorderCocoa, context: Context) {}
}
