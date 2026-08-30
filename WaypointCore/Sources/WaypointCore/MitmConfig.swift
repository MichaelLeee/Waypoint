//
//  MitmConfig.swift
//  WaypointCore
//  Injects the local MITM engine into the mihomo config: an http-type proxy
//  entry pointing at the intercept listener plus DOMAIN/DOMAIN-SUFFIX rules
//  routing rewrite targets through it. Placed directly under the injected
//  ad-block REJECT rules so blocking still wins and user rules come last.
//

import Foundation

public enum MitmConfig {
    public static let proxyName = "waypoint-mitm"
    /// Marker searched in `rules:` to anchor injection below the ad block.
    private static let adBlockRuleMarkers = [
        "GEOSITE,category-ads-all,REJECT",
        "GEOSITE,category-public-tracker,REJECT",
    ]

    /// mihomo rule lines derived from the user's rewrite rules.
    public static func domainRules(fromHostPatterns hosts: [String]) -> [String] {
        var seen = Set<String>()
        var lines: [String] = []
        for raw in hosts {
            let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !host.isEmpty, !seen.contains(host) else { continue }
            seen.insert(host)
            if host.hasPrefix(".") {
                let domain = String(host.dropFirst())
                guard !domain.isEmpty else { continue }
                lines.append("DOMAIN,\(domain)")
                lines.append("DOMAIN-SUFFIX,\(domain)")
            } else {
                lines.append("DOMAIN,\(host)")
            }
        }
        return lines.map { "\($0),\(proxyName)" }
    }

    /// Returns `config` with the MITM proxy entry and routing rules injected.
    /// Idempotent: if any `waypoint-mitm` rule is present the config is left
    /// untouched (rule edits take effect through regeneration on toggle).
    public static func apply(to config: String, port: Int, hosts: [String]) -> String {
        let ruleLines = domainRules(fromHostPatterns: hosts)
        guard !ruleLines.isEmpty else { return config }

        var out = config
        out = injectProxyEntry(to: out, port: port)
        out = injectRules(ruleLines, to: out)
        return out
    }

    // MARK: - Internals

    private static func injectProxyEntry(to config: String, port: Int) -> String {
        if config.contains("name: \(proxyName)") {
            return config
        }
        let entry = [
            "  - name: \(proxyName)",
            "    type: http",
            "    server: 127.0.0.1",
            "    port: \(port)",
        ].joined(separator: "\n")

        var out = config
        if out.hasTopLevelSection(named: "proxies:") {
            var updated = [String]()
            var inserted = false
            for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
                let isFirstSectionLine =
                    line.first?.isWhitespace != true &&
                    line.trimmingCharacters(in: .whitespaces).hasPrefix("proxies:")
                updated.append(String(line))
                if isFirstSectionLine && !inserted {
                    updated.append(entry)
                    inserted = true
                }
            }
            if inserted {
                return updated.joined(separator: "\n")
            }
        }

        if !out.hasSuffix("\n") {
            out += "\n"
        }
        return out + "\n" + ["proxies:", entry].joined(separator: "\n") + "\n"
    }

    private static func injectRules(_ ruleLines: [String], to config: String) -> String {
        if config.contains(",\(proxyName)") {
            return config
        }
        let lines = config.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let rulesIndex = lines.firstIndex(where: { line in
            line.first?.isWhitespace != true &&
            line.trimmingCharacters(in: .whitespaces).hasPrefix("rules:")
        }) else {
            // No rules section — create one carrying only our intercept routes.
            var out = config
            if !out.hasSuffix("\n") {
                out += "\n"
            }
            let block = (["rules:"] + ruleLines.map { "  - \($0)" }).joined(separator: "\n")
            return out + "\n" + block + "\n"
        }

        // Anchor below the injected ad/tracker rejects when present, else
        // right after the section header — always above user-authored rules.
        var insertionIndex = rulesIndex + 1
        for index in rulesIndex + 1 ..< min(rulesIndex + 6, lines.count) where lines[index].contains(",REJECT") {
            insertionIndex = index + 1
        }

        var updated = lines
        updated.insert(contentsOf: ruleLines.map { "  - \($0)" }, at: insertionIndex)
        return updated.joined(separator: "\n")
    }
}
