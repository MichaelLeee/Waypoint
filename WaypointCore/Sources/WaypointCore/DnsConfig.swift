//
//  DnsConfig.swift
//  WaypointCore
//  The `dns:` section of the mihomo config for Fake-IP mode. Verified against
//  mihomo v1.19.30: `enable` + `enhanced-mode: fake-ip` + `fake-ip-range` is a
//  complete, valid block — `nameserver` and `fake-ip-filter` are optional
//  (mihomo falls back to the system resolver and its built-in filter, which
//  already covers LAN/local/STUN/game/NTP hosts).
//

import Foundation

public struct DnsConfig {
    public var enable: Bool = true
    public var enhancedMode: EnhancedMode = .fakeIP
    public var fakeIPRange: String = "198.18.0.1/16"

    public enum EnhancedMode: String {
        case fakeIP = "fake-ip"
        case redirHost = "redir-host"
    }

    public init() {}

    /// The `dns:` block, ready to append to a mihomo YAML config.
    public var yamlString: String {
        return [
            "dns:",
            "  enable: \(enable)",
            "  enhanced-mode: \(enhancedMode.rawValue)",
            "  fake-ip-range: \(fakeIPRange)",
        ].joined(separator: "\n")
    }
}

extension DnsConfig {
    /// Returns `config` with `dns`'s block appended, unless the config already
    /// declares a top-level `dns:` key (the user's own DNS settings win). Never
    /// emits a duplicate key, which mihomo would reject.
    public static func apply(_ dns: DnsConfig?, to config: String) -> String {
        guard let dns else { return config }
        if config.hasTopLevelSection(named: "dns:") {
            return config
        }
        var out = config
        if !out.hasSuffix("\n") {
            out += "\n"
        }
        return out + "\n" + dns.yamlString + "\n"
    }
}
