import AppKit
import Foundation
import Gzip

@MainActor
enum WaypointResourceManager {
    static func check() -> Bool {
        checkConfigDir()
        checkMMDB()
        return true
    }

    static func checkConfigDir() {
        var isDir: ObjCBool = true

        if !FileManager.default.fileExists(atPath: kConfigFolderPath, isDirectory: &isDir) {
            do {
                try FileManager.default.createDirectory(atPath: kConfigFolderPath, withIntermediateDirectories: true, attributes: nil)
            } catch let err {
                Logger.log("\(err.localizedDescription) \(kConfigFolderPath)")
                showCreateConfigDirFailAlert(err: err.localizedDescription)
            }
        }
    }

    static func checkMMDB() {
        let fileManage = FileManager.default
        let destMMDBPath = "\(kConfigFolderPath)/Country.mmdb"

        // Remove old mmdb file after version update.
        if fileManage.fileExists(atPath: destMMDBPath) {
            let vaild = isValidMMDB(at: destMMDBPath)
            let versionChange = AppVersionUtil.hasVersionChanged || AppVersionUtil.isFirstLaunch
            if !vaild || versionChange {
                Logger.log("removing new mmdb file")
                try? fileManage.removeItem(atPath: destMMDBPath)
            }
        }

        if !fileManage.fileExists(atPath: destMMDBPath) {
            Logger.log("installing new mmdb file")
            if let mmdbUrl = Bundle.main.url(forResource: "Country.mmdb", withExtension: "gz") {
                do {
                    let data = try Data(contentsOf: mmdbUrl).gunzipped()
                    try data.write(to: URL(fileURLWithPath: destMMDBPath))
                } catch let err {
                    Logger.log("add mmdb fail:\(err)", level: .error)
                }
            }
        }
    }

    static func showCreateConfigDirFailAlert(err: String) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Waypoint fail to create ~/.config/waypoint folder. Please check privileges or manually create folder and restart Waypoint." + err, comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }

    /// MaxMind DB files carry a `\xAB\xCD\xEFMaxMind.com` metadata marker
    /// within their last 128 KiB. Checking for it is a cheap validity probe
    /// that replaces the removed CGO `verifyGEOIPDataBase`.
    private static func isValidMMDB(at path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return false
        }
        let marker = Data([0xAB, 0xCD, 0xEF]) + Data("MaxMind.com".utf8)
        let searchSize = min(data.count, 128 * 1024)
        let range = (data.count - searchSize) ..< data.count
        return data.range(of: marker, options: [], in: range) != nil
    }
}

extension WaypointResourceManager {
    static func updateGeoIP() {
        guard let urlString = showCustomAlert(), let remote = URL(string: urlString) else { return }
        Task {
            let destPath = kConfigFolderPath.appending("/Country.mmdb")
            let dest = URL(fileURLWithPath: destPath)
            var info: String
            do {
                let (tmp, response) = try await URLSession.shared.download(from: remote)
                if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                Logger.log("update success")
                info = NSLocalizedString("Success!", comment: "")
            } catch {
                info = NSLocalizedString("Fail:", comment: "") + error.localizedDescription
                Logger.log("update fail \(error)")
            }
            if !isValidMMDB(at: destPath) {
                info = "Database verify fail"
                checkMMDB()
            }
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Update GEOIP Database", comment: "")
            alert.informativeText = info
            alert.runModal()
        }
    }

    private static func showCustomAlert() -> String? {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Custom your GEOIP MMDB download address.", comment: "")
        let inputView = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        inputView.placeholderString = Settings.defaultMmdbDownloadUrl
        if Settings.mmdbDownloadUrl.isEmpty {
            inputView.stringValue = Settings.defaultMmdbDownloadUrl
        } else {
            inputView.stringValue = Settings.mmdbDownloadUrl
        }
        alert.accessoryView = inputView
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn {
            if inputView.stringValue.isEmpty {
                return inputView.placeholderString
            }
            Settings.mmdbDownloadUrl = inputView.stringValue
            return inputView.stringValue
        }
        return nil
    }
}
