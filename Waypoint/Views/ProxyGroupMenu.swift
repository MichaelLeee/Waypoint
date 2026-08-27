//
//  ProxyGroupMenu.swift
//  Waypoint
//
import AppKit

// NSMenuItems are main-thread confined (AppKit); the conformance only
// silences strict-concurrency send checks for menu-item captures.
extension NSMenuItem: @unchecked @retroactive Sendable {}

@objc protocol ProxyGroupMenuHighlightDelegate: AnyObject {
    func highlight(item: NSMenuItem?)
}

class ProxyGroupMenu: NSMenu {
    var highlightDelegates = NSHashTable<ProxyGroupMenuHighlightDelegate>.weakObjects()

    override init(title: String) {
        super.init(title: title)
        delegate = self
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    func add(delegate: ProxyGroupMenuHighlightDelegate) {
        highlightDelegates.add(delegate)
    }

    func remove(_ delegate: ProxyGroupMenuHighlightDelegate) {
        highlightDelegates.remove(delegate)
    }
}

extension ProxyGroupMenu: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        highlightDelegates.allObjects.forEach { $0.highlight(item: nil) }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        highlightDelegates.allObjects.forEach { $0.highlight(item: item) }
    }
}
