//
//  Persistence.swift
//  Waypoint
//
//  Single typed surface over UserDefaults. Every key the app persists is
//  declared in Persistence.Key; managers must not construct keys inline.
//  UserDefaults.standard is read inline on every access because a static
//  stored instance is not concurrency-safe under Swift 6 strict checking.
//  Codable values are stored as JSON data; a decode failure is logged and
//  treated as absent instead of crashing.
//

import Foundation

enum Persistence {
    // MARK: - Key inventory

    enum Key {
        // General preferences (Settings facade)
        static let mmdbDownloadUrl = "mmdbDownloadUrl"
        static let filterInterface = "filterInterface"
        static let disableNoti = "disableNoti"
        static let configAutoUpdateInterval = "configAutoUpdateInterval"
        static let proxyIgnoreList = "proxyIgnoreList"
        static let disableMenubarNotice = "disableMenubarNotice"
        static let proxyPort = "proxyPort"
        static let apiPort = "apiPort"
        static let apiPortAllowLan = "apiPortAllowLan"
        static let disableSSIDList = "disableSSIDList"
        static let enableIPV6 = "enableIPV6"
        static let useSwiftUIMenu = "useSwiftUIMenu"
        static let tunEnabled = "tunEnabled"
        static let fakeIPEnabled = "fakeIPEnabled"
        static let adBlockEnabled = "adBlockEnabled"
        static let killSwitchEnabled = "killSwitchEnabled"
        static let mitmEnabled = "mitmEnabled"
        static let mitmEnginePort = "mitmEnginePort"
        static let apiSecret = "api-secret"
        static let overrideConfigSecret = "overrideConfigSecret"
        static let builtInApiMode = "kBuiltInApiMode"
        static let benchMarkUrl = "benchMarkUrl"
        static let disableRestoreProxy = "kDisableRestoreProxy"

        // Config selection state
        static let proxyPortAutoSet = "proxyPortAutoSet"
        static let showNetSpeedIndicator = "showNetSpeedIndicator"
        static let selectConfigName = "selectConfigName"
        static let selectOutBoundMode = "selectOutBoundMode"
        static let allowConnectFromLan = "allowConnectFromLan"
        static let selectLoggingApiLevel = "selectLoggingApiLevel"

        // Remote configs / external control
        static let remoteConfigs = "kRemoteConfigs"
        /// Legacy single-config key; only read by the migration path.
        static let legacyRemoteConfigUrl = "kRemoteConfigUrl"
        static let autoUpdateEnable = "kAutoUpdateEnable"
        static let remoteControls = "kRemoteControls"
        static let selectedRemoteControlConfigID = "selectedRemoteControlConfigID"

        // Saved proxy group selections
        static let savedProxyModels = "SavedProxyModels"

        // System proxy restore state (SCNetwork dictionary)
        static let savedProxyInfo = "kSavedProxyInfo"

        // Update channel (AutoUpgardeManager.Channel.rawValue)
        static let upgradeChannel = "AutoUpgardeManager.current"

        // MITM rewrite rules
        static let mitmRewriteRules = "mitmRewriteRules"

        // UI state
        static let onboardingCompleted = "kOnboardingCompleted"
        static let statusMenuFontName = "kStatusMenuFontName"
        /// Window sizes are stored per-content-type: "<prefix><TypeName>".
        static let windowSizePrefix = "lastSize."
        static let lastVersionNumber = "org.waypnt.lastVersionNumber"

        // Crash protection
        static let launchFailTimes = "launch_fail_times"

        // iCloud
        static let userEnableiCloud = "kUserEnableiCloud"
    }

    // MARK: - Generic property-list access

    static func read<T: PropertyListValue>(_ key: String, default value: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? value
    }

    static func write<T: PropertyListValue>(_ value: T, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static func hasValue(forKey key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) != nil
    }

    static func string(forKey key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func removeValue(forKey key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Codable values (JSON blobs)

    static func loadCodable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Logger.log("failed to decode \(key): \(error)", level: .error)
            return nil
        }
    }

    static func saveCodable<T: Encodable>(_ value: T, forKey key: String) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            Logger.log("failed to encode \(key): \(error)", level: .error)
        }
    }

    // MARK: - Typed accessors
    // Plain computed statics: UserDefaults is thread-safe and these are read
    // from nonisolated contexts (e.g. Logger seeding its level).

    static var onboardingCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: Key.onboardingCompleted) }
        set { UserDefaults.standard.set(newValue, forKey: Key.onboardingCompleted) }
    }

    static var launchFailTimes: Int {
        get { UserDefaults.standard.object(forKey: Key.launchFailTimes) as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: Key.launchFailTimes) }
    }

    static var userEnableiCloud: Bool {
        get { UserDefaults.standard.bool(forKey: Key.userEnableiCloud) }
        set { UserDefaults.standard.set(newValue, forKey: Key.userEnableiCloud) }
    }

    static var statusMenuFontName: String? {
        get { UserDefaults.standard.string(forKey: Key.statusMenuFontName) }
        set { UserDefaults.standard.set(newValue, forKey: Key.statusMenuFontName) }
    }

    static var lastVersionNumber: String? {
        get { UserDefaults.standard.string(forKey: Key.lastVersionNumber) }
        set { UserDefaults.standard.set(newValue, forKey: Key.lastVersionNumber) }
    }

    static var proxyPortAutoSet: Bool {
        get { UserDefaults.standard.bool(forKey: Key.proxyPortAutoSet) }
        set { UserDefaults.standard.set(newValue, forKey: Key.proxyPortAutoSet) }
    }

    static var showNetSpeedIndicator: Bool {
        get { UserDefaults.standard.bool(forKey: Key.showNetSpeedIndicator) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showNetSpeedIndicator) }
    }

    static var selectConfigName: String {
        get { UserDefaults.standard.string(forKey: Key.selectConfigName) ?? "config" }
        set { UserDefaults.standard.set(newValue, forKey: Key.selectConfigName) }
    }

    static var selectOutBoundMode: WaypointProxyMode {
        get { WaypointProxyMode(rawValue: UserDefaults.standard.string(forKey: Key.selectOutBoundMode) ?? "") ?? .rule }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.selectOutBoundMode) }
    }

    static var allowConnectFromLan: Bool {
        get { UserDefaults.standard.bool(forKey: Key.allowConnectFromLan) }
        set { UserDefaults.standard.set(newValue, forKey: Key.allowConnectFromLan) }
    }

    static var selectLoggingApiLevel: WaypointLogLevel {
        get { WaypointLogLevel(rawValue: UserDefaults.standard.string(forKey: Key.selectLoggingApiLevel) ?? "") ?? .info }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.selectLoggingApiLevel) }
    }

    static var autoUpdateEnable: Bool {
        get { UserDefaults.standard.object(forKey: Key.autoUpdateEnable) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.autoUpdateEnable) }
    }

    static var selectedRemoteControlConfigID: String {
        get { UserDefaults.standard.string(forKey: Key.selectedRemoteControlConfigID) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Key.selectedRemoteControlConfigID) }
    }

    /// Raw SCNetwork proxy dictionary captured before the app takes over
    /// system proxy settings, used to restore the user's original state.
    static var savedProxyInfo: [String: Any] {
        get { UserDefaults.standard.dictionary(forKey: Key.savedProxyInfo) }
        set { UserDefaults.standard.set(newValue, forKey: Key.savedProxyInfo) }
    }

    static var upgradeChannelRaw: Int? {
        get { UserDefaults.standard.object(forKey: Key.upgradeChannel) as? Int }
        set { UserDefaults.standard.set(newValue, forKey: Key.upgradeChannel) }
    }
}
