//
//  RewriteRule.swift
//  Waypoint
//  Model for MITM rewrite rules applied by the local MITM proxy engine
//  (MitmProxyServer). v1 operates on HTTP/1.1 headers post-TLS because modern
//  clients negotiate TLS paths that make body rewriting unreliable; network-
//  level blocking stays with the ad-block GEOSITE rules.
//

import Foundation
import WaypointMitmEngine

struct RewriteRule: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// Drop connections to the matched host entirely.
        case reject
        /// Add or replace a header on requests to the matched host.
        case requestHeader
        /// Add or replace a header on responses (empty value removes it).
        case responseHeader

        var id: String { rawValue }

        var title: String {
            switch self {
            case .reject: return NSLocalizedString("Reject", comment: "")
            case .requestHeader: return NSLocalizedString("Set Request Header", comment: "")
            case .responseHeader: return NSLocalizedString("Set Response Header", comment: "")
            }
        }
    }

    var kind: Kind
    /// Host to match, e.g. "api.example.com" or suffix form ".example.com".
    var host: String
    /// Header field for request/response kinds (unused for reject).
    var headerKey: String
    /// Replacement value; empty means "remove the header".
    var headerValue: String
    var id = UUID()

    /// ".example.com" (or the equivalent "*.example.com") matches the domain
    /// itself and every subdomain; anything else is an exact (case-insensitive)
    /// host match.
    func matches(host candidate: String) -> Bool {
        let lowered = candidate.lowercased()
        if let domain = Self.suffixDomain(of: host)?.lowercased() {
            return lowered == domain || lowered.hasSuffix("." + domain)
        }
        return lowered == host.lowercased()
    }

    /// Normalizes wildcard hosts: "*.example.com" and ".example.com" both
    /// yield "example.com" for suffix matching; nil means exact match.
    static func suffixDomain(of host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix(".") {
            return String(trimmed.dropFirst())
        }
        if trimmed.hasPrefix("*.") {
            return String(trimmed.dropFirst(2))
        }
        return nil
    }

    /// The engine-side mirror handed to WaypointMitmEngine.
    var engineRule: MitmRule {
        MitmRule(kind: MitmRule.Kind(rawValue: kind.rawValue) ?? .reject,
                 host: host,
                 headerKey: headerKey,
                 headerValue: headerValue)
    }
}

enum RewriteRuleStore {
    static func load() -> [RewriteRule] {
        Persistence.loadCodable([RewriteRule].self,
                                forKey: Persistence.Key.mitmRewriteRules) ?? []
    }

    static func save(_ rules: [RewriteRule]) {
        Persistence.saveCodable(rules, forKey: Persistence.Key.mitmRewriteRules)
    }

    static func rejectHosts(in rules: [RewriteRule]) -> [RewriteRule] {
        rules.filter { $0.kind == .reject }
    }
}
