//
//  YAMLSectionDetection.swift
//  WaypointCore
//

import Foundation

extension String {
    /// True if the YAML declares a top-level key whose name begins with `key`
    /// (e.g. `"tun:"` or `"dns:"`). Indented lines are skipped so a nested key
    /// (like a `dns:` provider under another section) doesn't false-positive.
    public func hasTopLevelSection(named key: String) -> Bool {
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
    public func hasTopLevelPortKey() -> Bool {
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
