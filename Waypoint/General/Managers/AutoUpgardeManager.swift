//
//  AutoUpgardeManager.swift
//  Waypoint
//

import Cocoa
import Sparkle

// @unchecked: UI-confined singleton (menu item + Sparkle controller).
class AutoUpgardeManager: NSObject, @unchecked Sendable {
    var checkForUpdatesMenuItem: NSMenuItem?
    static let shared = AutoUpgardeManager()
    private var controller: SPUStandardUpdaterController?
    private var current: Channel = {
        if let value = Persistence.upgradeChannelRaw,
           let channel = Channel(rawValue: value) { return channel }
        return .stable
    }() {
        didSet {
            Persistence.upgradeChannelRaw = current.rawValue
        }
    }

    private var allowSelectChannel: Bool {
        return Bundle.main.object(forInfoDictionaryKey: "SUDisallowSelectChannel") as? Bool != true
    }

    var canSelectChannel: Bool { allowSelectChannel }

    var selectedChannel: Channel {
        get { current }
        set { current = newValue }
    }

    // MARK: Public

    @MainActor func setup() {
        // Sparkle cannot validate a downloaded update without its EdDSA public
        // key, so the updater fails to start and "Check Update" reports a
        // generic error. Say why in the app log instead.
        if Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String == nil {
            Logger.log("Sparkle: SUPublicEDKey is missing from Info.plist; update checks cannot validate downloads.", level: .error)
        }
        controller = SPUStandardUpdaterController(updaterDelegate: self, userDriverDelegate: nil)
    }

    @MainActor func setupCheckForUpdatesMenuItem(_ item: NSMenuItem) {
        checkForUpdatesMenuItem = item
        checkForUpdatesMenuItem?.target = controller
        checkForUpdatesMenuItem?.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
    }

    @MainActor func addChannelMenuItem(_ button: NSPopUpButton) {
        for channel in Channel.allCases {
            button.addItem(withTitle: channel.title)
            button.lastItem?.tag = channel.rawValue
        }
        button.target = self
        button.action = #selector(didselectChannel(sender:))
        button.selectItem(withTag: current.rawValue)
    }

    @MainActor @objc func didselectChannel(sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag, let channel = Channel(rawValue: tag) else { return }
        current = channel
    }
}

extension AutoUpgardeManager: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard WebPortalManager.hasWebProtal == false, allowSelectChannel else { return nil }
        return current.urlString
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        SystemProxyManager.shared.disableProxy(port: 0, socksPort: 0, forceDisable: true)
    }
}

// MARK: - Channel Enum

extension AutoUpgardeManager {
    // Raw values are persisted, so they must stay stable: stable = 0,
    // prelease = 1. A stored value that no longer maps to a channel falls back
    // to stable in `current`'s initializer.
    enum Channel: Int, CaseIterable {
        case stable
        case prelease
    }
}

extension AutoUpgardeManager.Channel {
    var title: String {
        switch self {
        case .stable:
            return NSLocalizedString("Stable", comment: "")
        case .prelease:
            return NSLocalizedString("Prelease", comment: "")
        }
    }

    var urlString: String {
        switch self {
        case .stable:
            return "https://michaelleee.github.io/Waypoint/appcast.xml"
        case .prelease:
            return "https://michaelleee.github.io/Waypoint/appcast_pre.xml"
        }
    }
}
