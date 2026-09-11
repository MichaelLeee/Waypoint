//
//  ProxyDelayHistoryMenu.swift
//  Waypoint
//

import Cocoa
import WaypointNetworking

class ProxyDelayHistoryMenu: NSMenu {
    private var observerTask: Task<Void, Never>?

    @MainActor
    init(proxy: WaypointProxy) {
        super.init(title: "")
        updateHistoryMenu(proxy: proxy)
        let hub = ProxyUpdateHub.shared
        let name = proxy.name
        observerTask = Task { [weak self] in
            for await event in hub.proxyEvents(for: name) {
                if case .snapshot(let proxy) = event {
                    self?.updateHistoryMenu(proxy: proxy)
                }
            }
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        observerTask?.cancel()
    }

    private func updateHistoryMenu(proxy: WaypointProxy) {
        removeAllItems()
        for history in proxy.history.reversed() {
            let item = NSMenuItem(title: history.displayString, action: nil, keyEquivalent: "")
            addItem(item)
        }
    }
}
