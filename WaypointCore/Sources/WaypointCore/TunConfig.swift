//
//  TunConfig.swift
//  WaypointCore
//  The `tun:` section of the mihomo config. Verified against mihomo v1.19.30:
//  `enable` + `stack` is enough to bring the device up (log line
//  "[TUN] Tun adapter listening at: ... ip stack: gVisor"); `auto-route`
//  defaults to true even when omitted, so we set it explicitly.
//

import Foundation

public struct TunConfig {
    public var enable: Bool = true
    /// `mixed` = system stack for TCP + gVisor for UDP (recommended on macOS).
    public var stack: Stack = .mixed
    /// macOS device names must start with "utun"; mihomo picks the free index.
    public var device: String = "utun"
    public var autoRoute: Bool = true
    public var autoDetectInterface: Bool = true
    public var strictRoute: Bool = true
    public var dnsHijack: [String] = ["any:53"]
    /// mihomo defaults to 9000 when unset.
    public var mtu: Int?

    public enum Stack: String {
        case system
        case gvisor
        case mixed
    }

    public init() {}

    /// The `tun:` block, ready to append to a mihomo YAML config.
    public var yamlString: String {
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
    public static func apply(_ tun: TunConfig?, to config: String) -> String {
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
}
