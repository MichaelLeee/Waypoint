//
//  ProxyMenuItem.swift
//  Waypoint
//

import Cocoa

class ProxyMenuItem: NSMenuItem, @unchecked Sendable {
    let proxyName: String
    let maxProxyNameLength: CGFloat
    private var observerTasks: [Task<Void, Never>] = []

    deinit {
        observerTasks.forEach { $0.cancel() }
    }

    var enableShowUsingView: Bool {
        MenuItemFactory.useViewToRenderProxy
    }

    @MainActor
    init(proxy: WaypointProxy,
         group: WaypointProxy,
         action selector: Selector?,
         simpleItem: Bool = false) {
        proxyName = proxy.name

        maxProxyNameLength = simpleItem ? 0 : group.maxProxyNameLength

        super.init(title: proxyName, action: selector, keyEquivalent: "")

        if !simpleItem && enableShowUsingView && group.isSpeedTestable {
            view = ProxyItemView(proxy: proxy)
        } else if !simpleItem {
            attributedTitle = getAttributedTitle(name: proxyName, delay: proxy.history.last?.delayDisplay)
        }
        let selected = group.now == proxy.name
        updateSelected(selected)

        startObserving(name: group.name)

        if !simpleItem {
            startObserving(name: proxy.name)
        }
    }

    @MainActor private func startObserving(name: String) {
        let hub = ProxyUpdateHub.shared
        observerTasks.append(Task { [weak self] in
            for await event in hub.proxyEvents(for: name) {
                self?.handle(event)
            }
        })
    }

    @MainActor private func handle(_ event: ProxyUpdateHub.Event) {
        switch event {
        case .snapshot(let proxy):
            if WaypointProxyType.isProxyGroup(proxy) {
                updateSelected(proxy.now == proxyName)
            } else if proxy.alive == false {
                updateDelay(NSLocalizedString("fail", comment: ""), rawValue: 0)
            } else {
                updateDelay(proxy.history.last?.delayDisplay, rawValue: proxy.history.last?.delay)
            }
        case .delay(_, let display, let value):
            updateDelay(display, rawValue: value)
        }
    }

    @available(*, unavailable)
    required init(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func didClick() {
        if let action = action {
            _ = target?.perform(action, with: self)
        }
        menu?.cancelTracking()
    }

    @MainActor private func updateSelected(_ selected: Bool) {
        if let v = view as? ProxyItemView {
            v.update(selected: selected)
        } else {
            state = selected ? .on : .off
        }
    }

    @MainActor private func updateDelay(_ delay: String?, rawValue: Int?) {
        if enableShowUsingView {
            (view as? ProxyItemView)?.update(str: delay, value: rawValue)
        } else {
            attributedTitle = getAttributedTitle(name: proxyName, delay: delay)
        }
    }
}

extension ProxyMenuItem: ProxyGroupMenuHighlightDelegate {
    // The @objc protocol requirement is nonisolated; this class is MainActor.
    // Menus call this on the main thread only.
    nonisolated func highlight(item: NSMenuItem?) {
        MainActor.assumeIsolated {
            (view as? ProxyItemView)?.isHighlighted = item == self
        }
    }
}

extension ProxyMenuItem {
    func getAttributedTitle(name: String, delay: String?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [
            NSTextTab(textAlignment: .right, location: 65 + maxProxyNameLength, options: [:])
        ]
        let proxyName = name.replacingOccurrences(of: "\t", with: " ")
        let str: String
        if let delay = delay {
            str = "\(proxyName)\t\(delay)"
        } else {
            str = proxyName.appending(" ")
        }

        let attributed = NSMutableAttributedString(
            string: str,
            attributes: [
                NSAttributedString.Key.paragraphStyle: paragraph,
                NSAttributedString.Key.font: NSFont.menuBarFont(ofSize: 14)
            ]
        )

        let hackAttr = [NSAttributedString.Key.font: NSFont.menuBarFont(ofSize: 15)]
        attributed.addAttributes(hackAttr, range: NSRange(name.utf16.count ..< name.utf16.count + 1))

        if delay != nil {
            let delayAttr = [NSAttributedString.Key.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]
            attributed.addAttributes(delayAttr, range: NSRange(name.utf16.count + 1 ..< str.utf16.count))
        }
        return attributed
    }
}
