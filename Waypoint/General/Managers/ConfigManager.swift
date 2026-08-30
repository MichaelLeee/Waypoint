//
//  ConfigManager.swift
//  Waypoint
//  Core runtime state. RxSwift (`BehaviorRelay`, `UserDefaults.rx.observe`) is
//  replaced with `@Observable` on a `@MainActor` singleton.
//

import Cocoa
import Observation
import WaypointCore

@MainActor
@Observable
final class ConfigManager {
    static let shared = ConfigManager()

    var apiPort = "9090"
    var allowExternalControl = false
    var apiSecret: String = ""
    var overrideApiURL: URL?
    var overrideSecret: String?

    var currentConfig: WaypointConfig?
    var isRunning = false
    var isProxySetByOther = false
    var proxyShouldPaused = false

    var proxyPortAutoSet: Bool = UserDefaults.standard.bool(forKey: "proxyPortAutoSet") {
        didSet { UserDefaults.standard.set(proxyPortAutoSet, forKey: "proxyPortAutoSet") }
    }

    var showNetSpeedIndicator: Bool = UserDefaults.standard.bool(forKey: "showNetSpeedIndicator") {
        didSet { UserDefaults.standard.set(showNetSpeedIndicator, forKey: "showNetSpeedIndicator") }
    }

    private init() {}

    static var selectConfigName: String {
        get {
            if shared.isRunning {
                return UserDefaults.standard.string(forKey: "selectConfigName") ?? "config"
            }
            return "config"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "selectConfigName")
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
        get {
            return WaypointProxyMode(rawValue: UserDefaults.standard.string(forKey: "selectOutBoundMode") ?? "") ?? .rule
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "selectOutBoundMode")
        }
    }

    static var allowConnectFromLan: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "allowConnectFromLan")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "allowConnectFromLan")
        }
    }

    // Pure UserDefaults access; safe from any thread (Logger reads it from init).
    nonisolated static var selectLoggingApiLevel: WaypointLogLevel {
        get {
            return WaypointLogLevel(rawValue: UserDefaults.standard.string(forKey: "selectLoggingApiLevel") ?? "") ?? .info
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "selectLoggingApiLevel")
        }
    }

    static func getConfigPath(configName: String, complete: ((String) -> Void)? = nil) {
        if ICloudManager.shared.useiCloud.value {
            ICloudManager.shared.getUrl { url in
                guard let url = url else {
                    return
                }
                let configPath = url.appendingPathComponent(Paths.configFileName(for: configName)).path
                complete?(configPath)
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
