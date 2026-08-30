//
//  AdBlockConfig.swift
//  WaypointCore
//  DNS-level ad/tracker blocking via mihomo REJECT rules. mihomo downloads
//  geosite.dat automatically when a GEOSITE rule first appears, so no bundled
//  database or remote rule-provider URL is needed.
//

import Foundation

public enum AdBlockConfig {
    /// Inserted as REJECT rules at the very top of `rules:` so they win over
    /// any user rule (mihomo applies first match).
    public static let adRules = ["GEOSITE,category-ads-all"]
    public static let trackerRules = ["GEOSITE,category-public-tracker"]

    public static func apply(to config: String) -> String {
        let pending = (adRules + trackerRules).filter { !config.contains($0) }
        guard !pending.isEmpty else { return config }
        let injected = pending.map { "  - \($0),REJECT" }

        if config.hasTopLevelSection(named: "rules:") {
            var lines: [String] = []
            var inserted = false
            for line in config.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(String(line))
                if !inserted,
                   line.first?.isWhitespace != true,
                   line.trimmingCharacters(in: .whitespaces).hasPrefix("rules:") {
                    lines.append(contentsOf: injected)
                    inserted = true
                }
            }
            guard inserted else { return config }
            return lines.joined(separator: "\n")
        }

        // No rules section at all: create one; MATCH must come last in mihomo.
        var out = config
        if !out.hasSuffix("\n") {
            out += "\n"
        }
        return out
            + "rules:\n"
            + (injected + ["  - MATCH,DIRECT"]).joined(separator: "\n")
            + "\n"
    }
}
