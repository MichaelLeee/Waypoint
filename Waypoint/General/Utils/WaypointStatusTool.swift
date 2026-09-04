//
//  WaypointStatusTool.swift
//  Waypoint Pro
//

import Cocoa

class WaypointStatusTool {
    // The config snapshot arrives on every reload/reconnect, so guard the
    // notice to once per app run — a modal here (the old behavior) re-armed on
    // each snapshot and trapped the whole app in stacked modal sessions.
    private static var didNoticeNoPorts = false

    static func checkPortConfig(cfg: WaypointConfig?) {
        guard let cfg else { return }
        // Only value types cross the isolation boundary (WaypointConfig itself
        // is not Sendable).
        let httpPort = cfg.usedHttpPort
        let mixedPort = cfg.mixedPort
        Task { @MainActor in
            guard ConfigManager.shared.isRunning else { return }
            guard httpPort == 0 else {
                didNoticeNoPorts = false
                return
            }
            guard !didNoticeNoPorts else { return }
            didNoticeNoPorts = true
            Logger.log("checkPortConfig: running core reports no inbound ports (mixed-port: \(mixedPort)); system proxy cannot be applied", level: .error)
            // Zero ports is legitimate with Enhanced Mode (TUN) or a
            // portless config — it must never block the UI or quit the app,
            // so this stays a dismissible notification, not a modal alert.
            WaypointNotifier.post(
                title: NSLocalizedString("Ports Open Fail", comment: ""),
                info: NSLocalizedString(
                    "The proxy core reports no open ports, so the system proxy cannot be set. Edit your config to add a mixed-port (or enable Enhanced Mode), then reload the config.",
                    comment: ""))
        }
    }
}
