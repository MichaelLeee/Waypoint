//
//  TerminalCleanUpAction.swift
//  Waypoint
//

import AppKit
import Foundation

enum TerminalConfirmAction {
    @MainActor
    static func run() -> NSApplication.TerminateReply {
        guard confirmAction() else {
            return .terminateCancel
        }
        let group = DispatchGroup()
        var shouldWait = false

        if ConfigManager.shared.proxyPortAutoSet && !ConfigManager.shared.isProxySetByOther || NetworkChangeNotifier.isCurrentSystemSetToWaypoint(looser: true) ||
            NetworkChangeNotifier.hasInterfaceProxySetToWaypoint() {
            Logger.log("Waypoint quit need clean proxy setting")
            shouldWait = true
            let forceDisable = ConfigManager.shared.isProxySetByOther
            group.enter()

            SystemProxyManager.shared.disableProxy(forceDisable: forceDisable) {
                group.leave()
            }
        }

        if !shouldWait {
            Logger.log("Waypoint quit without clean waiting")
            return .terminateNow
        }

        if let statusItem = AppDelegate.shared.statusItem, statusItem.menu != nil {
            statusItem.menu = nil
        }

        DispatchQueue.global(qos: .default).async {
            let res = group.wait(timeout: .now() + 5)
            switch res {
            case .success:
                Logger.log("Waypoint quit after clean up finish")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    MainActor.assumeIsolated {
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                }
                // Delayed failsafe in case the main run loop never services
                // the block above.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            case .timedOut:
                Logger.log("Waypoint quit after clean up timeout")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }

        Logger.log("Waypoint quit wait for clean up")
        return .terminateLater
    }

    @MainActor static func confirmAction() -> Bool {
        if NSApp.activationPolicy() == .regular {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Quit Waypoint?", comment: "")
            alert.informativeText = NSLocalizedString("The active connections will be interrupted.", comment: "")
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            return alert.runModal() == .alertFirstButtonReturn
        }
        return true
    }
}
