//
//  SwiftUIWindowController.swift
//  Waypoint
//

import AppKit
import SwiftUI

@MainActor
private final class SwiftUIWindowsRecorder {
    static let shared = SwiftUIWindowsRecorder()
    var windowControllers = [NSWindowController]() {
        didSet {
            if windowControllers.isEmpty {
                NSApp.setActivationPolicy(.accessory)
            } else if NSApp.activationPolicy() == .accessory {
                NSApp.setActivationPolicy(.regular)
            }
        }
    }
}

@MainActor
class SwiftUIWindowController<Content: View>: NSWindowController, NSWindowDelegate {
    var onWindowClose: (() -> Void)?
    private var fromCache = false
    private var sizeKey: String { "lastSize.\(String(describing: Content.self))" }

    static func create(
        title: String,
        minimumSize: CGSize? = nil,
        content: Content
    ) -> SwiftUIWindowController<Content> {
        if let wc = SwiftUIWindowsRecorder.shared.windowControllers.first(where: { $0 is Self }) as? Self {
            wc.fromCache = true
            return wc
        }
        let win = NSWindow(contentViewController: NSHostingController(rootView: content))
        win.title = title
        win.styleMask.insert(.closable)
        win.styleMask.insert(.resizable)
        win.styleMask.insert(.miniaturizable)
        if let minimumSize {
            win.contentMinSize = minimumSize
        }
        let wc = SwiftUIWindowController(window: win)
        SwiftUIWindowsRecorder.shared.windowControllers.append(wc)
        return wc
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if !fromCache {
            if let str = UserDefaults.standard.string(forKey: sizeKey) {
                let lastSize = NSSizeFromString(str) as CGSize
                if lastSize != .zero {
                    window?.setContentSize(lastSize)
                    window?.center()
                }
            }
        }
        window?.delegate = self
        window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        SwiftUIWindowsRecorder.shared.windowControllers.removeAll(where: { $0 == self })
        if let win = window, !win.styleMask.contains(.fullScreen) {
            UserDefaults.standard.set(NSStringFromSize(win.frame.size), forKey: sizeKey)
        }
        onWindowClose?()
    }
}
