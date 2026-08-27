//
//  RemoteConfigManager.swift
//  Waypoint
//

import Cocoa

@MainActor
final class RemoteConfigManager {
    var configs: [RemoteConfigModel] = []
    var refreshActivity: NSBackgroundActivityScheduler?

    static let shared = RemoteConfigManager()

    private init() {
        if let savedConfigs = UserDefaults.standard.object(forKey: "kRemoteConfigs") as? Data {
            let decoder = JSONDecoder()
            if let loadedConfig = try? decoder.decode([RemoteConfigModel].self, from: savedConfigs) {
                configs = loadedConfig
            } else {
                assertionFailure()
            }
        }
        migrateOldRemoteConfig()
        setupAutoUpdateTimer()
    }

    func saveConfigs() {
        Logger.log("Saving Remote Config Setting")
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(configs) {
            UserDefaults.standard.set(encoded, forKey: "kRemoteConfigs")
        }
    }

    func migrateOldRemoteConfig() {
        if let url = UserDefaults.standard.string(forKey: "kRemoteConfigUrl"),
           let name = URL(string: url)?.host {
            configs.append(RemoteConfigModel(url: url, name: name))
            UserDefaults.standard.removeObject(forKey: "kRemoteConfigUrl")
            saveConfigs()
        }
    }

    func setupAutoUpdateTimer() {
        refreshActivity?.invalidate()
        refreshActivity = nil
        guard RemoteConfigManager.autoUpdateEnable else {
            Logger.log("autoUpdateEnable did not enable,autoUpateTimer invalidated.")
            return
        }
        Logger.log("set up autoUpateTimer")

        refreshActivity = NSBackgroundActivityScheduler(identifier: "com.Waypoint.configupdate")
        refreshActivity?.repeats = true
        refreshActivity?.interval = 60 * 60 * 2 // Two hour
        refreshActivity?.tolerance = 60 * 60

        refreshActivity?.schedule { [weak self] completionHandler in
            completionHandler(NSBackgroundActivityScheduler.Result.finished)
            Task { @MainActor [weak self] in
                self?.autoUpdateCheck()
            }
        }
    }

    static var autoUpdateEnable: Bool {
        get {
            return UserDefaults.standard.object(forKey: "kAutoUpdateEnable") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "kAutoUpdateEnable")
            Task { @MainActor in
                RemoteConfigManager.shared.setupAutoUpdateTimer()
            }
        }
    }

    func autoUpdateCheck() {
        guard RemoteConfigManager.autoUpdateEnable else { return }
        Logger.log("Tigger config auto update check")
        updateCheck()
    }

    func updateCheck(ignoreTimeLimit: Bool = false, showNotification: Bool = false) {
        let currentConfigName = ConfigManager.selectConfigName

        let group = DispatchGroup()

        for config in configs {
            if config.updating { continue }
            let timeLimitNoMantians = Date().timeIntervalSince(config.updateTime ?? Date(timeIntervalSince1970: 0)) < Settings.configAutoUpdateInterval

            if timeLimitNoMantians && !ignoreTimeLimit {
                Logger.log("[Auto Upgrade] Bypassing \(config.name) due to time check")
                continue
            }
            Logger.log("[Auto Upgrade] Requesting \(config.name)")
            let isCurrentConfig = config.name == currentConfigName
            config.updating = true
            group.enter()
            Task {
                let error = await RemoteConfigManager.updateConfig(config: config)
                defer { group.leave() }
                config.updating = false
                if error == nil {
                    config.updateTime = Date()
                }

                if isCurrentConfig {
                    if let error {
                        // Fail
                        if showNotification {
                            WaypointNotifier
                                .post(title: NSLocalizedString("Remote Config Update Fail", comment: ""),
                                      info: "\(config.name): \(error)")
                        }

                    } else {
                        // Success
                        if showNotification {
                            let info = "\(config.name): \(NSLocalizedString("Succeed!", comment: ""))"
                            WaypointNotifier
                                .post(title: NSLocalizedString("Remote Config Update", comment: ""), info: info)
                        }
                        // The surrounding Task may resume off-main; the
                        // AppDelegate is main-confined, so hop explicitly.
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                AppDelegate.shared.updateConfig(showNotification: false)
                            }
                        }
                    }
                }
                Logger.log("[Auto Upgrade] Finish \(config.name) result: \(error ?? "succeed")")
            }
        }

        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.saveConfigs()
            }
        }
    }

    /// Downloads a remote config. Returns (config text or nil, suggested filename).
    nonisolated static func getRemoteConfigData(config: RemoteConfigModel) async -> (String?, String?) {
        guard let url = URL(string: config.url) else {
            assertionFailure()
            Logger.log("[getRemoteConfigData] url incorrect,\(config.name) \(config.url)")
            return (nil, nil)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.cachePolicy = .reloadIgnoringCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                return (nil, nil)
            }
            return (String(data: data, encoding: .utf8), response.suggestedFilename)
        } catch {
            Logger.log(error.localizedDescription, level: .warning)
            return (nil, nil)
        }
    }

    nonisolated static func updateConfig(config: RemoteConfigModel) async -> String? {
        let (configString, suggestedFilename) = await getRemoteConfigData(config: config)
        guard let newConfig = configString else {
            return NSLocalizedString("Download fail", comment: "")
        }

        let verifyRes = verifyConfig(string: newConfig)
        if let error = verifyRes {
            return NSLocalizedString("Remote Config Format Error", comment: "") + ": " + error
        }

        await MainActor.run {
            if let suggestName = suggestedFilename, config.isPlaceHolderName {
                let name = URL(fileURLWithPath: suggestName).deletingPathExtension().lastPathComponent
                if !shared.configs.contains(where: { $0.name == name }) {
                    config.name = name
                }
            }
            config.isPlaceHolderName = false

            if ICloudManager.shared.useiCloud.value {
                ConfigFileManager.shared.stopWatchConfigFile()
            }
            if config.name == ConfigManager.selectConfigName {
                ConfigFileManager.shared.pauseForNextChange()
            }
        }

        let resultBox = ResultBox<String?>()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: @Sendable (String?) -> Void = { err in
                resultBox.value = err
                continuation.resume()
            }
            if ICloudManager.shared.useiCloud.value {
                ICloudManager.shared.getUrl { url in
                    guard let url = url else {
                        done(nil)
                        return
                    }
                    let saveUrl = url.appendingPathComponent(Paths.configFileName(for: config.name))
                    Self.performSave(savePath: saveUrl.path, newConfig: newConfig, complete: done)
                }
            } else {
                let savePath = Paths.localConfigPath(for: config.name)
                Self.performSave(savePath: savePath, newConfig: newConfig, complete: done)
            }
        }
        // ResultBox<String?> stores T? internally, so flatten the double optional.
        return resultBox.value.flatMap { $0 }
    }

    nonisolated private static func performSave(savePath: String, newConfig: String, complete: @escaping @Sendable (String?) -> Void) {
        do {
            if FileManager.default.fileExists(atPath: savePath) {
                try FileManager.default.removeItem(atPath: savePath)
            }
            try newConfig.write(to: URL(fileURLWithPath: savePath), atomically: true, encoding: .utf8)
            complete(nil)
        } catch let err {
            complete(err.localizedDescription)
        }
    }

    nonisolated static func verifyConfig(string: String) -> ErrorString? {
        if let err = CoreProcessManager.testConfig(configString: string, homeDir: kConfigFolderPath) {
            Logger.log(err, level: .error)
            return err
        }
        return nil
    }

    static func showAdd() {
        let alertView = NSAlert()
        alertView.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alertView.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alertView.messageText = NSLocalizedString("Update remote config update interval", comment: "")
        let setupView = RemoteConfigUpdateIntervalSettingView()
        setupView.frame = NSRect(x: 0, y: 0, width: 100, height: 22)
        alertView.accessoryView = setupView
        let response = alertView.runModal()

        guard response == .alertFirstButtonReturn else { return }
        let stringValue = setupView.textfield.stringValue
        guard let intValue = Int(stringValue), intValue > 0 else {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.informativeText = NSLocalizedString("Should be a least 1 hour", comment: "")
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
            return
        }
        Settings.configAutoUpdateInterval = TimeInterval(intValue * 60 * 60)
        RemoteConfigManager.shared.autoUpdateCheck()
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }

    init() {}
}
