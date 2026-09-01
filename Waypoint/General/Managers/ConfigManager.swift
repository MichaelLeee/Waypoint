//
//  ConfigManager.swift
//  Waypoint
//  Core runtime state. RxSwift (`BehaviorRelay`, `UserDefaults.rx.observe`) is
//  replaced with `@Observable` on a `@MainActor` singleton.
//

import Cocoa
import Observation
import WaypointCore

// AppKit-side observers (menu bar UI) watch these instead of the old
// CurrentValueSubject bridge; SwiftUI reads the @Observable properties.
extension Notification.Name {
    static let waypointCurrentConfigDidChange = Notification.Name("org.waypnt.waypoint.currentConfigDidChange")
    static let waypointProxyStatusDidChange = Notification.Name("org.waypnt.waypoint.proxyStatusDidChange")
    static let waypointShowNetSpeedIndicatorDidChange = Notification.Name("org.waypnt.waypoint.showNetSpeedIndicatorDidChange")
}

@MainActor
@Observable
final class ConfigManager {
    static let shared = ConfigManager()

    var apiPort = "9090"
    var allowExternalControl = false
    var apiSecret: String = ""
    var overrideApiURL: URL?
    var overrideSecret: String?

    var currentConfig: WaypointConfig? {
        didSet {
            NotificationCenter.default.post(name: .waypointCurrentConfigDidChange, object: nil)
        }
    }
    var isRunning = false
    var isProxySetByOther = false {
        didSet {
            NotificationCenter.default.post(name: .waypointProxyStatusDidChange, object: nil)
        }
    }
    var proxyShouldPaused = false {
        didSet {
            NotificationCenter.default.post(name: .waypointProxyStatusDidChange, object: nil)
        }
    }

    var proxyPortAutoSet: Bool = Persistence.proxyPortAutoSet {
        didSet {
            Persistence.proxyPortAutoSet = proxyPortAutoSet
            NotificationCenter.default.post(name: .waypointProxyStatusDidChange, object: nil)
        }
    }

    var showNetSpeedIndicator: Bool = Persistence.showNetSpeedIndicator {
        didSet {
            Persistence.showNetSpeedIndicator = showNetSpeedIndicator
            NotificationCenter.default.post(name: .waypointShowNetSpeedIndicatorDidChange, object: nil)
        }
    }

    private init() {}

    static var selectConfigName: String {
        get {
            // Always honor the stored selection: returning a hard-coded
            // "config" while the core is down made every cold start load the
            // default file instead of the user's selected one.
            return Persistence.selectConfigName
        }
        set {
            Persistence.selectConfigName = newValue
            watchCurrentConfigFile()
        }
    }

    static func watchCurrentConfigFile() {
        if ICloudManager.shared.useiCloud.value {
            ICloudManager.shared.getUrl { url in
                guard let url = url else { return }
                let configUrl = url.appendingPathComponent(Paths.configFileName(for: selectConfigName))
                ConfigFileManager.shared.watchFile(path: configUrl.path)
            }
        } else {
            ConfigFileManager.shared.watchFile(path: Paths.localConfigPath(for: selectConfigName))
        }
    }

    static var apiUrl: String {
        if let override = shared.overrideApiURL {
            return override.absoluteString
        }
        return "http://127.0.0.1:\(shared.apiPort)"
    }

    static var webSocketUrl: String {
        if let override = shared.overrideApiURL, var comp = URLComponents(url: override, resolvingAgainstBaseURL: true) {
            if comp.scheme == "https" {
                comp.scheme = "wss"
            } else {
                comp.scheme = "ws"
            }
            return comp.url?.absoluteString ?? ""
        }
        return "ws://127.0.0.1:\(shared.apiPort)"
    }

    static var selectedProxyRecords = SavedProxyModel.loadsFromUserDefault() {
        didSet {
            SavedProxyModel.save(selectedProxyRecords)
        }
    }

    static var selectOutBoundMode: WaypointProxyMode {
        get { Persistence.selectOutBoundMode }
        set { Persistence.selectOutBoundMode = newValue }
    }

    static var allowConnectFromLan: Bool {
        get { Persistence.allowConnectFromLan }
        set { Persistence.allowConnectFromLan = newValue }
    }

    // Pure UserDefaults access; safe from any thread (Logger reads it from init).
    nonisolated static var selectLoggingApiLevel: WaypointLogLevel {
        get { Persistence.selectLoggingApiLevel }
        set { Persistence.selectLoggingApiLevel = newValue }
    }

    static func getConfigPath(configName: String, complete: ((String) -> Void)? = nil) {
        if ICloudManager.shared.useiCloud.value {
            ICloudManager.shared.getUrl { url in
                if let url = url {
                    let configPath = url.appendingPathComponent(Paths.configFileName(for: configName)).path
                    complete?(configPath)
                } else {
                    // iCloud unavailable (or the URL request failed); without
                    // this fallback the caller's continuation would hang.
                    complete?(Paths.localConfigPath(for: configName))
                }
            }
        } else {
            let filePath = Paths.localConfigPath(for: configName)
            complete?(filePath)
        }
    }

    static func getEffectiveConfigPath(configName: String, complete: @escaping (String) -> Void) {
        getConfigPath(configName: configName) { sourcePath in
            complete(TunConfig.effectivePath(from: sourcePath, configName: configName))
        }
    }
}

extension ConfigManager {
    static func getConfigFilesList() -> [String] {
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(atPath: kConfigFolderPath)
            return fileURLs
                .filter { String($0.split(separator: ".").last ?? "") == "yaml" }
                .map { $0.split(separator: ".").dropLast().joined(separator: ".") }
        } catch {
            return ["config"]
        }
    }
}
