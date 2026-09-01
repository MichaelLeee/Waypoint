//
//  AppDelegate+CrashAndMemory.swift
//  Waypoint
//
//  Consecutive-crash launch protection and proxy-selection memory helpers.
//

import Cocoa
import WaypointNetworking

// MARK: crash handler

extension AppDelegate {
    func failLaunchProtect() {
        #if DEBUG
            return
        #else
            UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": false])
            var launch_fail_times = Persistence.launchFailTimes
            launch_fail_times += 1
            Persistence.launchFailTimes = launch_fail_times
            if launch_fail_times > 3 {
                // consecutive crashes — reset state for a clean launch
                ConfigFileManager.backupAndRemoveConfigFile()
                try? FileManager.default.removeItem(atPath: kConfigFolderPath + "Country.mmdb")
                if let domain = Bundle.main.bundleIdentifier {
                    UserDefaults.standard.removePersistentDomain(forName: domain)
                    UserDefaults.standard.synchronize()
                }
                WaypointNotifier.post(title: "Fail on launch protect", info: "You origin Config has been renamed", notiOnly: false)
            }
            DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + Double(Int64(5 * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)) {
                Persistence.launchFailTimes = 0
            }
        #endif
    }
}

// MARK: Memory

extension AppDelegate {
    func selectProxyGroupWithMemory() {
        let copy = [SavedProxyModel](ConfigManager.selectedProxyRecords)
        for item in copy {
            guard item.config == ConfigManager.selectConfigName else { continue }
            Logger.log("Auto selecting \(item.group) \(item.selected)", level: .debug)
            Task {
                let success = await ApiRequest.updateProxyGroup(group: item.group, selectProxy: item.selected)
                if !success {
                    ConfigManager.selectedProxyRecords.removeAll { model -> Bool in
                        return model.key == item.key
                    }
                }
            }
        }
    }

    func removeUnExistProxyGroups() {
        let action: (([String]) -> Void) = { list in
            let unexists = ConfigManager.selectedProxyRecords.filter {
                !list.contains($0.config)
            }
            ConfigManager.selectedProxyRecords.removeAll {
                unexists.contains($0)
            }
        }

        if ICloudManager.shared.useiCloud.value {
            Task {
                let list: [String] = await withCheckedContinuation { continuation in
                    ICloudManager.shared.getConfigFilesList { continuation.resume(returning: $0) }
                }
                action(list)
            }
        } else {
            let list = ConfigManager.getConfigFilesList()
            action(list)
        }
    }

    func selectOutBoundModeWithMenory() async {
        _ = await ApiRequest.updateOutBoundMode(ConfigManager.selectOutBoundMode)
        ConnectionManager.closeAllConnection()
        syncConfig()
    }

    func selectAllowLanWithMenory() async {
        await ApiRequest.updateAllowLan(ConfigManager.allowConnectFromLan)
        syncConfig()
    }

    func hasMenuSelected() -> Bool {
        if #available(macOS 11, *) {
            return statusMenu.items.contains { $0.state == .on }
        } else {
            return true
        }
    }
}
