//
//  WaypointStatusTool.swift
//  Waypoint Pro
//

import Cocoa

@MainActor
class WaypointStatusTool {
    // The config snapshot arrives on every reload/reconnect, so guard the
    // notice to once per app run — a modal here (the old behavior) re-armed on
    // each snapshot and trapped the whole app in stacked modal sessions.
    private static var didNoticeNoPorts = false

    static func checkPortConfig(cfg: WaypointConfig?) {
        guard let cfg else { return }
        guard ConfigManager.shared.isRunning else { return }
        guard cfg.usedHttpPort == 0 else {
            didNoticeNoPorts = false
            return
        }
        guard !didNoticeNoPorts else { return }
        didNoticeNoPorts = true
        Logger.log("checkPortConfig: running core reports no inbound ports (mixed-port: \(cfg.mixedPort)); system proxy cannot be applied", level: .error)
        // Zero ports is legitimate with Enhanced Mode (TUN) or a portless
        // config — it must never block the UI or quit the app, so this stays
        // a dismissible notification, not a modal alert.
        //
        // It is also what a failed listener looks like: mihomo logs "bind:
        // address already in use" and then carries on running, so a core whose
        // port was taken still reports itself as up. Both causes are named here
        // because the fixes are completely different.
        WaypointNotifier.post(
            title: NSLocalizedString("Ports Open Fail", comment: ""),
            info: NSLocalizedString(
                "The proxy core reports no open ports, so the system proxy cannot be set. Either the config has no mixed-port (add one, or enable Enhanced Mode), or something else already holds the port — a core left over from an earlier run is the usual cause; run `sudo pkill -f mihomo` in Terminal and reload the config.",
                comment: ""))
    }
}