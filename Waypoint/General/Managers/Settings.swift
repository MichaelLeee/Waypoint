//
//  Settings.swift
//  Waypoint
//

import Foundation
enum Settings {
    // UserDefaults-backed computed statics. The @UserDefault property wrapper
    // was replaced: its synthesized backing storage defeats nonisolated(unsafe)
    // and fails strict-concurrency checks on static stored properties.

    private static func read<T: PropertyListValue>(_ key: String, default value: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? value
    }

    private static func write<T: PropertyListValue>(_ value: T, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static let defaultMmdbDownloadUrl = "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb"
    static var mmdbDownloadUrl: String {
        get { read("mmdbDownloadUrl", default: defaultMmdbDownloadUrl) }
        set { write(newValue, forKey: "mmdbDownloadUrl") }
    }

    static var filterInterface: Bool {
        get { read("filterInterface", default: true) }
        set { write(newValue, forKey: "filterInterface") }
    }

    static var disableNoti: Bool {
        get { read("disableNoti", default: false) }
        set { write(newValue, forKey: "disableNoti") }
    }

    static var configAutoUpdateInterval: TimeInterval {
        get { read("configAutoUpdateInterval", default: 48 * 60 * 60) }
        set { write(newValue, forKey: "configAutoUpdateInterval") }
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
        get { read("proxyIgnoreList", default: proxyIgnoreListDefaultValue) }
        set { write(newValue, forKey: "proxyIgnoreList") }
    }

    static var disableMenubarNotice: Bool {
        get { read("disableMenubarNotice", default: false) }
        set { write(newValue, forKey: "disableMenubarNotice") }
    }

    static var proxyPort: Int {
        get { read("proxyPort", default: 0) }
        set { write(newValue, forKey: "proxyPort") }
    }

    static var apiPort: Int {
        get { read("apiPort", default: 0) }
        set { write(newValue, forKey: "apiPort") }
    }

    static var apiPortAllowLan: Bool {
        get { read("apiPortAllowLan", default: false) }
        set { write(newValue, forKey: "apiPortAllowLan") }
    }

    static var disableSSIDList: [String] {
        get { read("disableSSIDList", default: []) }
        set { write(newValue, forKey: "disableSSIDList") }
    }

    static var enableIPV6: Bool {
        get { read("enableIPV6", default: false) }
        set { write(newValue, forKey: "enableIPV6") }
    }

    static var tunEnabled: Bool {
        get { read("tunEnabled", default: false) }
        set { write(newValue, forKey: "tunEnabled") }
    }

    static var fakeIPEnabled: Bool {
        get { read("fakeIPEnabled", default: false) }
        set { write(newValue, forKey: "fakeIPEnabled") }
    }

    static var adBlockEnabled: Bool {
        get { read("adBlockEnabled", default: false) }
        set { write(newValue, forKey: "adBlockEnabled") }
    }

    static var killSwitchEnabled: Bool {
        get { read("killSwitchEnabled", default: false) }
        set { write(newValue, forKey: "killSwitchEnabled") }
    }

    static var mitmEnabled: Bool {
        get { read("mitmEnabled", default: false) }
        set { write(newValue, forKey: "mitmEnabled") }
    }

    /// Port the intercept engine actually bound last time (it scans upward if
    /// the preferred port is taken); config injection must match it.
    static var mitmEnginePort: Int {
        get { read("mitmEnginePort", default: 6153) }
        set { write(newValue, forKey: "mitmEnginePort") }
    }

    static let apiSecretKey = "api-secret"

    static var isApiSecretSet: Bool {
        return UserDefaults.standard.object(forKey: apiSecretKey) != nil
    }

    static var apiSecret: String {
        get { read(apiSecretKey, default: "") }
        set { write(newValue, forKey: apiSecretKey) }
    }

    static var overrideConfigSecret: Bool {
        get { read("overrideConfigSecret", default: false) }
        set { write(newValue, forKey: "overrideConfigSecret") }
    }

    static var builtInApiMode: Bool {
        get { read("kBuiltInApiMode", default: true) }
        set { write(newValue, forKey: "kBuiltInApiMode") }
    }

    static let disableShowCurrentProxyInMenu = !AppDelegate.isAboveMacOS14

    static let defaultBenchmarkUrl = "http://cp.cloudflare.com/generate_204"
    static var benchMarkUrl: String {
        get { read("benchMarkUrl", default: defaultBenchmarkUrl) }
        set {
            let trimmed = newValue.isEmpty ? defaultBenchmarkUrl : newValue
            write(trimmed, forKey: "benchMarkUrl")
        }
    }

    static var disableRestoreProxy: Bool {
        get { read("kDisableRestoreProxy", default: false) }
        set { write(newValue, forKey: "kDisableRestoreProxy") }
    }
}
