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
        if let value = UserDefaults.standard.object(forKey: "AutoUpgardeManager.current") as? Int,
           let channel = Channel(rawValue: value) { return channel }
        #if PRO_VERSION
            return .appcenter
        #else
            return .stable
        #endif
    }() {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: "AutoUpgardeManager.current")
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
    enum Channel: Int, CaseIterable {
        #if !PRO_VERSION
            case stable
            case prelease
        #endif
        case appcenter
    }
}

extension AutoUpgardeManager.Channel {
    var title: String {
        switch self {
        #if !PRO_VERSION
            case .stable:
                return NSLocalizedString("Stable", comment: "")
            case .prelease:
                return NSLocalizedString("Prelease", comment: "")
        #endif
        case .appcenter:
            return "Appcenter"
        }
    }

    var urlString: String {
        switch self {
        #if !PRO_VERSION
            case .stable:
                return "https://michaelleee.github.io/Waypoint/appcast.xml"
            case .prelease:
                return "https://michaelleee.github.io/Waypoint/appcast_pre.xml"
        #endif
        case .appcenter:
            #if PRO_VERSION
                return "https://api.appcenter.ms/v0.1/public/sparkle/apps/REPLACE_WITH_PRO_APPCENTER_ID"
            #else
                return "https://api.appcenter.ms/v0.1/public/sparkle/apps/REPLACE_WITH_APPCENTER_ID"
            #endif
        }
    }
}
