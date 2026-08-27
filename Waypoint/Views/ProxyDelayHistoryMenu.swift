//
//  ProxyDelayHistoryMenu.swift
//  Waypoint
//

import Cocoa
import FlexibleDiff

class ProxyDelayHistoryMenu: NSMenu {
    var currentHistory: [WaypointProxySpeedHistory]?

    init(proxy: WaypointProxy) {
        super.init(title: "")
        updateHistoryMenu(proxy: proxy)
        NotificationCenter.default.addObserver(self, selector: #selector(proxyInfoDidUpdate(note:)), name: .proxyUpdate(for: proxy.name), object: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func proxyInfoDidUpdate(note: Notification) {
        guard let info = note.object as? WaypointProxy else { return }
        updateHistoryMenu(proxy: info)
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
