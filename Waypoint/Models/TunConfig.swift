//
//  TunConfig.swift
//  Waypoint
//  App-side derivation of the effective config. The pure config model lives
//  in the WaypointCore package; this extension reads app settings and writes
//  the derived file under the config home.
//

import Foundation
import WaypointCore

extension TunConfig {
    /// Reads `sourcePath`, injects every enabled enhancement (TUN stack,
    /// Fake-IP DNS, ad blocking) and a default `mixed-port` when the config
    /// declares none, then writes an effective config under
    /// `~/.config/waypoint/.waypoint/`. Relative paths in the user's config
    /// still resolve against the mihomo home dir (`-d`), so the derived file can
    /// live in a subdirectory without breaking `file:` providers.
    ///
    /// Returns the effective path, or `sourcePath` unchanged when nothing is
    /// injected or the source can't be read/written (mihomo then surfaces the
    /// real error).
    static func effectivePath(from sourcePath: String, configName: String) -> String {
        let mitmActive = Settings.mitmEnabled && !RewriteRuleStore.load().isEmpty
        guard let text = try? String(contentsOfFile: sourcePath, encoding: .utf8) else {
            return sourcePath
        }
        // mihomo listens on nothing when the config omits ports; the API then
        // reports mixed-port 0 and first launch would trip "Ports Open Fail".
        let needsPorts = !text.hasTopLevelPortKey()
        guard Settings.tunEnabled || Settings.fakeIPEnabled || Settings.adBlockEnabled || mitmActive || needsPorts else {
            return sourcePath
        }
        var injected = text
        if needsPorts {
            let port = Settings.proxyPort > 0 ? Settings.proxyPort : 7890
            injected = "mixed-port: \(port)\n" + injected
        }
        if Settings.tunEnabled {
            injected = apply(TunConfig(), to: injected)
        }
        if Settings.fakeIPEnabled {
            injected = DnsConfig.apply(DnsConfig(), to: injected)
        }
        if Settings.adBlockEnabled {
            injected = AdBlockConfig.apply(to: injected)
        }
        if mitmActive {
            injected = MitmConfig.apply(
                to: injected,
                port: Settings.mitmEnginePort,
                hosts: RewriteRuleStore.load().map(\.host)
            )
        }
        let dir = kConfigFolderPath + ".waypoint/"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = dir + Paths.configFileName(for: configName)
            try injected.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return sourcePath
        }
    }
}
