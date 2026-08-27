//
//  ConfigFileManager.swift
//  Waypoint
//

import AppKit
import Foundation

@MainActor
final class ConfigFileManager {
    static let shared = ConfigFileManager()

    private var witness: Witness?
    private var pause = false

    private init() {}

    func pauseForNextChange() {
        pause = true
    }

    func watchFile(path: String) {
        witness = Witness(paths: [path], flags: .FileEvents, latency: 0.3) {
            [weak self] events in
            // Witness fires on its own queue; hop to the main thread before
            // touching any state.
            DispatchQueue.main.async {
                guard let self = self else { return }
                MainActor.assumeIsolated {
                    guard !self.pause else {
                        self.pause = false
                        return
                    }
                    for event in events {
                        if event.flags.contains(.ItemModified) || event.flags.contains(.ItemRenamed) {
                            WaypointNotifier
                                .postConfigFileChangeDetectionNotice()
                            NotificationCenter.default
                                .post(Notification(name: .configFileChange))
                            break
                        }
                    }
                }
            }
        }
    }

    func stopWatchConfigFile() {
        witness = nil
        pause = false
    }

    @discardableResult
    static func backupAndRemoveConfigFile() -> Bool {
        let path = kDefaultConfigFilePath
        if FileManager.default.fileExists(atPath: path) {
            let newPath = "\(kConfigFolderPath)config_\(Date().timeIntervalSince1970).yaml"
            try? FileManager.default.moveItem(atPath: path, toPath: newPath)
        }
        return true
    }

    static func copySampleConfigIfNeed() {
        if !FileManager.default.fileExists(atPath: kDefaultConfigFilePath) {
            let path = Bundle.main.path(forResource: "sampleConfig", ofType: "yaml")!
            try? FileManager.default.copyItem(atPath: path, toPath: kDefaultConfigFilePath)
        }
    }
}
