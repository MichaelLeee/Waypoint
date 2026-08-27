//
//  TunConfig.swift
//  Waypoint
//  The `tun:` section of the mihomo config. Verified against mihomo v1.19.30:
//  `enable` + `stack` is enough to bring the device up (log line
//  "[TUN] Tun adapter listening at: ... ip stack: gVisor"); `auto-route`
//  defaults to true even when omitted, so we set it explicitly.
//

import Foundation

struct TunConfig {
    var enable: Bool = true
    /// `mixed` = system stack for TCP + gVisor for UDP (recommended on macOS).
    var stack: Stack = .mixed
    /// macOS device names must start with "utun"; mihomo picks the free index.
    var device: String = "utun"
    var autoRoute: Bool = true
    var autoDetectInterface: Bool = true
    var strictRoute: Bool = true
    var dnsHijack: [String] = ["any:53"]
    /// mihomo defaults to 9000 when unset.
    var mtu: Int?

    enum Stack: String {
        case system
        case gvisor
        case mixed
    }

    /// The `tun:` block, ready to append to a mihomo YAML config.
    var yamlString: String {
        var lines = [
            "tun:",
            "  enable: \(enable)",
            "  stack: \(stack.rawValue)",
            "  device: \(device)",
            "  auto-route: \(autoRoute)",
            "  auto-detect-interface: \(autoDetectInterface)",
            "  strict-route: \(strictRoute)",
        ]
        if !dnsHijack.isEmpty {
            lines.append("  dns-hijack:")
            for entry in dnsHijack {
                lines.append("    - \(entry)")
            }
        }
        if let mtu {
            lines.append("  mtu: \(mtu)")
        }
        return lines.joined(separator: "\n")
    }
}

extension TunConfig {
    /// Returns `config` with `tun`'s block appended, unless the config already
    /// declares a top-level `tun:` key (in which case the user's own TUN
    /// settings win). Never emits a duplicate key, which mihomo would reject.
    static func apply(_ tun: TunConfig?, to config: String) -> String {
        guard let tun else { return config }
        if config.hasTopLevelSection(named: "tun:") {
            return config
        }
        var out = config
        if !out.hasSuffix("\n") {
            out += "\n"
        }
        return out + "\n" + tun.yamlString + "\n"
    }

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

extension String {
    /// True if the YAML declares a top-level key whose name begins with `key`
    /// (e.g. `"tun:"` or `"dns:"`). Indented lines are skipped so a nested key
    /// (like a `dns:` provider under another section) doesn't false-positive.
    func hasTopLevelSection(named key: String) -> Bool {
        for line in split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first?.isWhitespace == true { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(key) {
                return true
            }
        }
        return false
    }

    /// True if the YAML declares any of `port:`, `socks-port:`, `mixed-port:`
    /// at the top level.
    func hasTopLevelPortKey() -> Bool {
        for line in split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first?.isWhitespace == true { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("port:")
                || trimmed.hasPrefix("socks-port:")
                || trimmed.hasPrefix("mixed-port:") {
                return true
            }
        }
        return false
    }
}
