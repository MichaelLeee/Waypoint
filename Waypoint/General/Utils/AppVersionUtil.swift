//
//  AppVersionUtil.swift
//  Waypoint
//

import Cocoa

// @unchecked: only holds an immutable version string.
class AppVersionUtil: NSObject, @unchecked Sendable {
    private static let shared = AppVersionUtil()

    private let lastVersionNumber: String?

    static var currentVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static var currentBuild: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    static var isBeta: Bool {
        return Bundle.main.object(forInfoDictionaryKey: "BETA") as? Bool ?? false
    }

    override init() {
        lastVersionNumber = Persistence.lastVersionNumber
        Persistence.lastVersionNumber = AppVersionUtil.currentVersion
    }

    static var isFirstLaunch: Bool {
        return shared.lastVersionNumber == nil
    }

    static var hasVersionChanged: Bool {
        return shared.lastVersionNumber != currentVersion
    }
}

extension AppVersionUtil {
    @MainActor static func showUpgradeAlert() {
        if let lastVersion = shared.lastVersionNumber, hasVersionChanged {
            WebCacheCleaner.clean()
            guard lastVersion.compare("1.30.0", options: .numeric) == .orderedAscending else { return }
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("This version of Waypoint contains a break change due to waypoint core 1.0 released. Check if your config is not working properly.", comment: "")
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Details", comment: ""))
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.open(URL(string: "https://github.com/MichaelLeee/Waypoint")!)
            }
        }
    }
}
