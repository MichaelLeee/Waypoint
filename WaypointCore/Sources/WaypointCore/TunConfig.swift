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
    /// mihomo requires every `tun.dns-hijack` entry to be `any:port` or
    /// `[tcp://|udp://]address:port` with a literal IP address; a hostname
    /// fails at TUN startup with `ParseAddr("..."): unexpected character`.
    /// Some subscription configs ship hostname entries (e.g. `dns.google`),
    /// and the user's own `tun:` block is never overwritten by `apply`, so
    /// any such entry found in the config is replaced with `any:53`.
    public static func sanitizedDNSHijackEntries(in config: String) -> String {
        var out: [String] = []
        out.reserveCapacity(config.count / 32 + 8)
        var inTunBlock = false
        var inHijackList = false

        for line in config.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                out.append(line)
                continue
            }

            if inTunBlock && inHijackList && !indent.isEmpty && trimmed.hasPrefix("- ") {
                let entry = commentStripped(String(trimmed.dropFirst(2)))
                if !entry.isEmpty, !isValidHijackEntry(entry) {
                    out.append("\(indent)- any:53")
                    continue
                }
                out.append(line)
                continue
            }

            if indent.isEmpty {
                inTunBlock = trimmed.hasPrefix("tun:")
                inHijackList = false
                out.append(line)
                continue
            }

            guard inTunBlock else {
                out.append(line)
                continue
            }

            if trimmed.hasPrefix("dns-hijack:") {
                let inline = commentStripped(String(trimmed.dropFirst("dns-hijack:".count)))
                    .trimmingCharacters(in: .whitespaces)
                if inline.isEmpty {
                    inHijackList = true
                    out.append(line)
                } else if inline.hasPrefix("[") && inline.hasSuffix("]") {
                    let items = inline.dropFirst().dropLast()
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    let fixed = items.map {
                        (isValidHijackEntry($0) ? $0 : "any:53")
                    }
                    out.append("\(indent)dns-hijack: [\(fixed.joined(separator: ", "))]")
                    inHijackList = false
                } else {
                    inHijackList = false
                    out.append(line)
                }
                continue
            }

            inHijackList = false
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    private static func commentStripped(_ entry: String) -> String {
        if let hash = entry.firstIndex(of: "#") {
            return String(entry[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        return entry.trimmingCharacters(in: .whitespaces)
    }

    public static func isValidHijackEntry(_ raw: String) -> Bool {
        var entry = raw
        for scheme in ["tcp://", "udp://"] where entry.hasPrefix(scheme) {
            entry.removeFirst(scheme.count)
        }
        guard let colon = entry.lastIndex(of: ":") else { return false }
        let host = String(entry[..<colon])
        let port = entry[entry.index(after: colon)...]
        guard !port.isEmpty, Int(port) != nil, (1...65535).contains(Int(port)!) else {
            return false
        }
        if host == "any" { return true }
        return isIPv4(host) || isIPv6(host)
    }

    private static func isIPv4(_ host: String) -> Bool {
        let groups = host.split(separator: ".", omittingEmptySubsequences: false)
        guard groups.count == 4 else { return false }
        return groups.allSatisfy { group in
            group.allSatisfy(\.isNumber)
                && group.count <= 3
                && !(group.count > 1 && group.hasPrefix("0"))
                && (0...255).contains(Int(group) ?? -1)
        }
    }

    private static func isIPv6(_ host: String) -> Bool {
        let body = host.hasPrefix("[") && host.hasSuffix("]") && host.count > 2
            ? String(host.dropFirst().dropLast())
            : host
        guard let zone = body.firstIndex(of: "%") else {
            return isIPv6Body(body)
        }
        return isIPv6Body(String(body[..<zone]))
    }

    private static func isIPv6Body(_ body: String) -> Bool {
        body.contains(":") && body.count <= 45
            && body.allSatisfy { $0.isHexDigit || $0 == ":" }
    }

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
