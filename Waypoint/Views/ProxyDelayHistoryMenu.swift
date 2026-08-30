//
//  ProxyDelayHistoryMenu.swift
//  Waypoint
//

import Cocoa
import FlexibleDiff

class ProxyDelayHistoryMenu: NSMenu {
    var currentHistory: [WaypointProxySpeedHistory]?
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
        let historys = Array(proxy.history.reversed())
        let change = Changeset(previous: currentHistory, current: historys, identifier: { $0.time })
        currentHistory = historys
        if change.moves.isEmpty && change.mutations.isEmpty {
            change.removals.reversed().forEach { idx in
                removeItem(at: idx)
            }
            change.inserts.forEach { idx in
                let his = historys[idx]
                let item = NSMenuItem(title: his.displayString, action: nil, keyEquivalent: "")
                insertItem(item, at: idx)
            }
        } else {
            historys.map { his in
                NSMenuItem(title: his.displayString, action: nil, keyEquivalent: "")
            }.forEach { item in
                addItem(item)
            }
        }
    }
}

extension WaypointProxySpeedHistory: Equatable {
    static func == (lhs: WaypointProxySpeedHistory, rhs: WaypointProxySpeedHistory) -> Bool {
        return lhs.displayString == rhs.displayString
    }
}
