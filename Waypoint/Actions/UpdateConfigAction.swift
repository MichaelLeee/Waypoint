//
//  UpdateConfigAction.swift
//  Waypoint
//

import AppKit
import Foundation

enum UpdateConfigAction {
    static func showError(text: String, configName: String) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = NSLocalizedString("Reload Config Fail", comment: "")
            alert.informativeText = text
            alert.addButton(withTitle: NSLocalizedString("Edit in Text Mode", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                ConfigManager.getConfigPath(configName: configName) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: $0))
                }
            }
        }
    }
}
