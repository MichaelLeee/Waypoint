//
//  Settings.swift
//  Waypoint
//

import Foundation

/// General preference facade. Keys live in Persistence.Key; storage is via
/// Persistence. Statics are computed (not stored) so they stay usable from
/// nonisolated contexts under Swift 6 strict concurrency.
enum Settings {
    static let defaultMmdbDownloadUrl = "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb"
    static var mmdbDownloadUrl: String {
        get { Persistence.read(Persistence.Key.mmdbDownloadUrl, default: defaultMmdbDownloadUrl) }
        set { Persistence.write(newValue, forKey: Persistence.Key.mmdbDownloadUrl) }
    }

    static var filterInterface: Bool {
        get { Persistence.read(Persistence.Key.filterInterface, default: true) }
        set { Persistence.write(newValue, forKey: Persistence.Key.filterInterface) }
    }

    static var disableNoti: Bool {
        get { Persistence.read(Persistence.Key.disableNoti, default: false) }
        set { Persistence.write(newValue, forKey: Persistence.Key.disableNoti) }
    }

    static var configAutoUpdateInterval: TimeInterval {
        get { Persistence.read(Persistence.Key.configAutoUpdateInterval, default: 48 * 60 * 60) }
        set { Persistence.write(newValue, forKey: Persistence.Key.configAutoUpdateInterval) }
    }

    static let proxyIgnoreListDefaultValue = ["192.168.0.0/16",
                                              "10.0.0.0/8",
                                              "172.16.0.0/12",
                                              "127.0.0.1",
                                              "localhost",
                                              "*.local",
                                              "timestamp.apple.com",
                                              "sequoia.apple.com",
                                              "seed-sequoia.siri.apple.com"]
    static var proxyIgnoreList: [String] {
        get { Persistence.read(Persistence.Key.proxyIgnoreList, default: proxyIgnoreListDefaultValue) }
        set { Persistence.write(newValue, forKey: Persistence.Key.proxyIgnoreList) }
    }

    static var disableMenubarNotice: Bool {
        get { Persistence.read(Persistence.Key.disableMenubarNotice, default: false) }
        set { Persistence.write(newValue, forKey: Persistence.Key.disableMenubarNotice) }
    }

    static var proxyPort: Int {
        get { Persistence.read(Persistence.Key.proxyPort, default: 0) }
        set { Persistence.write(newValue, forKey: Persistence.Key.proxyPort) }
    }

    static var apiPort: Int {
        get { Persistence.read(Persistence.Key.apiPort, default: 0) }
        set { Persistence.write(newValue, forKey: Persistence.Key.apiPort) }
    }

    static var apiPortAllowLan: Bool {
        get { Persistence.read(Persistence.Key.apiPortAllowLan, default: false) }
        set { Persistence.write(newValue, forKey: Persistence.Key.apiPortAllowLan) }
    }

    static var disableSSIDList: [String] {
        get { Persistence.read(Persistence.Key.disableSSIDList, default: []) }
        set { Persistence.write(newValue, forKey: Persistence.Key.disableSSIDList) }
    }

    static var enableIPV6: Bool {
        get { Persistence.read(Persistence.Key.enableIPV6, default: false) }
        set { Persistence.write(newValue, forKey: Persistence.Key.enableIPV6) }
    }

    /// Comparison flag: render the status menu with a SwiftUI MenuBarExtra
    /// instead of the legacy NSStatusItem + NSMenu.
    static var useSwiftUIMenu: Bool {
        get { Persistence.read(Persistence.Key.useSwiftUIMenu, default: false) }
        set { Persistence.write(newValue, forKey: Persistence.Key.useSwiftUIMenu) }
    }

    static var tunEnabled: Bool {
        get { Persistence.read(Persistence.Key.tunEnabled, default: false) }
        set { Persistence.write(newValue, forKey: Persistence.Key.tunEnabled) }
    }

    static var fakeIPEnabled: Bool {
        get { Persistence.read(Persistence.Key.fakeIPEnabled, default: false) }
        set { Persistence.write(newValue, forKey: Persistence.Key.fakeIPEnabled) }
    }

    static var adBlockEnabled: Bool {
        get { Persistence.read(Persistence.Key.adBlockEnabled, default: false) }
        set { Persistence.write(newValue, forKey: Persistence.Key.adBlockEnabled) }
    }

    static var killSwitchEnabled: Bool {
        get { Persistence.read(Persistence.Key.killSwitchEnabled, default: false) }
        set { Persistence.write(newValue, forKey: Persistence.Key.killSwitchEnabled) }
    }

    static var mitmEnabled: Bool {
        get { Persistence.read(Persistence.Key.mitmEnabled, default: false) }
        set { Persistence.write(newValue, forKey: Persistence.Key.mitmEnabled) }
    }

    /// Port the intercept engine actually bound last time (it scans upward if
    /// the preferred port is taken); config injection must match it.
    static var mitmEnginePort: Int {
        get { Persistence.read(Persistence.Key.mitmEnginePort, default: 6153) }
        set { Persistence.write(newValue, forKey: Persistence.Key.mitmEnginePort) }
    }

    static var isApiSecretSet: Bool {
        return Persistence.hasValue(forKey: Persistence.Key.apiSecret)
    }

    static var apiSecret: String {
        get { Persistence.read(Persistence.Key.apiSecret, default: "") }
        set { Persistence.write(newValue, forKey: Persistence.Key.apiSecret) }
    }

    static var overrideConfigSecret: Bool {
        get { Persistence.read(Persistence.Key.overrideConfigSecret, default: false) }
        set { Persistence.write(newValue, forKey: Persistence.Key.overrideConfigSecret) }
    }

    static var builtInApiMode: Bool {
        get { Persistence.read(Persistence.Key.builtInApiMode, default: true) }
        set { Persistence.write(newValue, forKey: Persistence.Key.builtInApiMode) }
    }

    static let disableShowCurrentProxyInMenu = !AppDelegate.isAboveMacOS14

    static let defaultBenchmarkUrl = "http://cp.cloudflare.com/generate_204"
    static var benchMarkUrl: String {
        get { Persistence.read(Persistence.Key.benchMarkUrl, default: defaultBenchmarkUrl) }
        set {
            let trimmed = newValue.isEmpty ? defaultBenchmarkUrl : newValue
            Persistence.write(trimmed, forKey: Persistence.Key.benchMarkUrl)
        }
    }

    static var disableRestoreProxy: Bool {
        get { Persistence.read(Persistence.Key.disableRestoreProxy, default: false) }
        set { Persistence.write(newValue, forKey: Persistence.Key.disableRestoreProxy) }
    }
}
