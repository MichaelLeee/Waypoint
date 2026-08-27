//
//  WaypointStatusTool.swift
//  Waypoint Pro
//

import Cocoa

class WaypointStatusTool {
    static func checkPortConfig(cfg: WaypointConfig?) {
        guard let cfg else { return }
        // Only value types cross the isolation boundary (WaypointConfig itself
        // is not Sendable).
        let httpPort = cfg.usedHttpPort
        let mixedPort = cfg.mixedPort
        Task { @MainActor in
            guard ConfigManager.shared.isRunning else { return }
            if httpPort == 0 {
                Logger.log("checkPortConfig: \(mixedPort) ", level: .error)
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Waypoint Start Error!", comment: "")
                alert.informativeText = NSLocalizedString("Ports Open Fail, Please try to restart Waypoint", comment: "")
                alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
                alert.addButton(withTitle: "Edit Config")
                let ret = alert.runModal()
                if ret == .alertSecondButtonReturn {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Paths.localConfigPath(for: "config")))
                }
                NSApp.terminate(nil)
            }
        }
    }
}
