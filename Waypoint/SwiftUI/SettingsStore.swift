//
//  SettingsStore.swift
//  Waypoint
//

import AppKit
import Observation
import Foundation

@MainActor
@Observable
final class SettingsStore {
    // General
    var launchAtLogin = LaunchAtLogin.shared.isEnabled {
        didSet { LaunchAtLogin.shared.isEnabled = launchAtLogin }
    }
    var useICloud = ICloudManager.shared.userEnableiCloud {
        didSet { ICloudManager.shared.userEnableiCloud = useICloud }
    }
    var reduceNotifications = Settings.disableNoti {
        didSet { Settings.disableNoti = reduceNotifications }
    }
    var benchmarkUrl = Settings.benchMarkUrl {
        didSet { if benchmarkUrl.isUrlVaild() || benchmarkUrl.isEmpty { Settings.benchMarkUrl = benchmarkUrl } }
    }

    var proxyIgnoreListText = Settings.proxyIgnoreList.joined(separator: ",") {
        didSet { commitList(proxyIgnoreListText) { Settings.proxyIgnoreList = $0 } }
    }
    var ssidSuspendListText = Settings.disableSSIDList.joined(separator: ",") {
        didSet { commitList(ssidSuspendListText) { Settings.disableSSIDList = $0 } }
    }

    // Network & API
    var proxyPortText = Settings.proxyPort > 0 ? "\(Settings.proxyPort)" : "" {
        didSet {
            guard let port = Int(proxyPortText), port != Settings.proxyPort else { return }
            Settings.proxyPort = port
            Task { await ApiRequest.updateProxyPort(port) }
        }
    }
    var apiPortText = Settings.apiPort > 0 ? "\(Settings.apiPort)" : "" {
        didSet {
            guard let port = Int(apiPortText) else { return }
            Settings.apiPort = port
        }
    }
    var apiPortAllowLan = Settings.apiPortAllowLan {
        didSet { Settings.apiPortAllowLan = apiPortAllowLan }
    }
    var apiSecret = Settings.apiSecret {
        didSet { Settings.apiSecret = apiSecret }
    }
    var overrideConfigSecret = Settings.overrideConfigSecret {
        didSet { Settings.overrideConfigSecret = overrideConfigSecret }
    }
    var enableIPv6 = Settings.enableIPV6 {
        didSet {
            Settings.enableIPV6 = enableIPv6
            Task { await ApiRequest.updateIPv6(enableIPv6) }
        }
    }

    // TUN & DNS
    var tunEnabled = Settings.tunEnabled {
        didSet {
            Settings.tunEnabled = tunEnabled
            // Keep the status-bar menu checkmark in sync.
            AppDelegate.shared.enhanceTunModeMenuItem?.state = tunEnabled ? .on : .off
        }
    }
    var fakeIPEnabled = Settings.fakeIPEnabled {
        didSet { Settings.fakeIPEnabled = fakeIPEnabled }
    }
    var adBlockEnabled = Settings.adBlockEnabled {
        didSet { Settings.adBlockEnabled = adBlockEnabled }
    }
    var killSwitchEnabled = Settings.killSwitchEnabled {
        didSet {
            guard killSwitchEnabled != Settings.killSwitchEnabled else { return }
            Settings.killSwitchEnabled = killSwitchEnabled
            Task { [killSwitchEnabled] in
                if !killSwitchEnabled {
                    await KillSwitchManager.shared.clear()
                } else if ConfigManager.shared.isRunning {
                    if let error = await KillSwitchManager.shared.applyNow() {
                        Logger.log("kill switch failed: \(error)", level: .error)
                    }
                }
            }
        }
    }

    // Update channel (mirrors AutoUpgardeManager.current)
    var updateChannel = AutoUpgardeManager.shared.selectedChannel {
        didSet { AutoUpgardeManager.shared.selectedChannel = updateChannel }
    }

    // MITM & rewrite
    var mitmEnabled = Settings.mitmEnabled {
        didSet {
            guard mitmEnabled != Settings.mitmEnabled else { return }
            Settings.mitmEnabled = mitmEnabled
            if mitmEnabled {
                _ = MitmProxyServer.ensureRunning()
            } else {
                MitmProxyServer.shared.stop()
            }
            if ConfigManager.shared.isRunning {
                Task { await reloadConfig() }
            }
        }
    }
    private(set) var rewriteRules = RewriteRuleStore.load()
    var mitmCertificateNote: String?

    private var rewriteReloadWorkItem: DispatchWorkItem?

    func addRewriteRule() {
        rewriteRules.append(RewriteRule(kind: .requestHeader,
                                        host: "",
                                        headerKey: "",
                                        headerValue: ""))
        touchRewriteRules()
    }

    func deleteRewriteRule(at offsets: IndexSet) {
        rewriteRules.remove(atOffsets: offsets)
        touchRewriteRules()
    }

    /// Field-level edit from the rules UI; persists immediately and schedules
    /// a debounced core reload so typing doesn't spam mihomo.
    func updateRewriteRule(at index: Int, mutate: (inout RewriteRule) -> Void) {
        guard rewriteRules.indices.contains(index) else { return }
        var rule = rewriteRules[index]
        mutate(&rule)
        rewriteRules[index] = rule
        touchRewriteRules()
    }

    private func touchRewriteRules() {
        RewriteRuleStore.save(rewriteRules)
        MitmProxyServer.ensureRunning()
        rewriteReloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.reloadConfig() }
        }
        rewriteReloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    func installMitmCertificate() {
        mitmCertificateNote = MitmCertificateAuthority.shared.installAndTrust()
    }

    func exportMitmCertificate() {
        do {
            let url = try MitmCertificateAuthority.shared.exportCertificate()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            mitmCertificateNote = NSLocalizedString("Certificate exported.", comment: "")
        } catch {
            mitmCertificateNote = error.localizedDescription
        }
    }

    func resetIgnoreList() {
        proxyIgnoreListText = Settings.proxyIgnoreListDefaultValue.joined(separator: ",")
    }

    private func commitList(_ text: String, apply: ([String]) -> Void) {
        let items = text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        apply(items)
    }

    func reloadConfig() async -> Bool {
        MitmProxyServer.ensureRunning()
        do {
            try await ApiRequest.requestConfigUpdate(configName: ConfigManager.selectConfigName)
            return true
        } catch {
            Logger.log("reload config failed: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    func flushFakeIPCache() async {
        await ApiRequest.resetFakeIpCache()
    }
}
