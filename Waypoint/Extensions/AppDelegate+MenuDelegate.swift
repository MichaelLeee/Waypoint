//
//  AppDelegate+MenuDelegate.swift
//  Waypoint
//

import Cocoa

// MARK: NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        MenuItemFactory.refreshExistingMenuItems()
        updateConfigFiles()
        syncConfig()
        NotificationCenter.default.post(name: .proxyMeneViewShowLeftPadding,
                                        object: nil,
                                        userInfo: ["show": hasMenuSelected()])
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        startProxyRefreshTimer()
    }

    /// Re-reads the proxy state once a second while the menu is open. Without
    /// it the rows only ever changed when the menu opened, so a node picked by a
    /// url-test group, the dashboard, another client or a Shortcut stayed
    /// invisible until the menu was dismissed and reopened.
    private func startProxyRefreshTimer() {
        guard proxyRefreshTimer == nil else { return }
        // Added to the common modes on purpose: a menu runs the run loop in
        // .eventTracking while it is tracking, which a default-mode timer never
        // fires in — the refresh would only land after the menu closed.
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                MenuItemFactory.refreshExistingMenuItems()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        proxyRefreshTimer = timer
    }

    private func stopProxyRefreshTimer() {
        proxyRefreshTimer?.invalidate()
        proxyRefreshTimer = nil
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        menu.items.forEach {
            ($0.view as? ProxyGroupMenuHighlightDelegate)?.highlight(item: item)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === statusMenu {
            stopProxyRefreshTimer()
        }
        menu.items.forEach {
            ($0.view as? ProxyGroupMenuHighlightDelegate)?.highlight(item: nil)
        }
    }
}

// MARK: URL Scheme

extension AppDelegate {
    @objc func handleURL(event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
            return
        }

        guard let components = URLComponents(string: url),
              let scheme = components.scheme,
              scheme.hasPrefix("waypoint"),
              let host = components.host
        else { return }

        if host == "install-config" {
            guard let url = components.queryItems?.first(where: { item in
                item.name == "url"
            })?.value else { return }

            var userInfo = ["url": url]
            if let name = components.queryItems?.first(where: { item in
                item.name == "name"
            })?.value {
                userInfo["name"] = name
            }

            remoteConfigAutoupdateMenuItem.menu?.performActionForItem(at: 0)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(name: Notification.Name(rawValue: "didGetUrl"), object: nil, userInfo: userInfo)
            }
        } else if host == "update-config" {
            updateConfig()
        }
    }
}
