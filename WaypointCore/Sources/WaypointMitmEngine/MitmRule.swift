//
//  MitmRule.swift
//  WaypointMitmEngine
//

public struct MitmRule: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// Drop connections to the matched host entirely.
        case reject
        /// Add or replace a header on requests to the matched host.
        case requestHeader
        /// Add or replace a header on responses (empty value removes it).
        case responseHeader
    }

    public var kind: Kind
    /// Host to match, e.g. "api.example.com" or suffix form ".example.com".
    public var host: String
    /// Header field for request/response kinds (unused for reject).
    public var headerKey: String
    /// Replacement value; empty means "remove the header".
    public var headerValue: String

    public init(kind: Kind, host: String, headerKey: String = "", headerValue: String = "") {
        self.kind = kind
        self.host = host
        self.headerKey = headerKey
        self.headerValue = headerValue
    }

    /// ".example.com" (or the equivalent "*.example.com") matches the domain
    /// itself and every subdomain; anything else is an exact (case-insensitive)
    /// host match.
    public func matches(host candidate: String) -> Bool {
        let lowered = candidate.lowercased()
        if let domain = Self.suffixDomain(of: host)?.lowercased() {
            return lowered == domain || lowered.hasSuffix("." + domain)
        }
        return lowered == host.lowercased()
    }

    /// "*.example.com" and ".example.com" both yield "example.com" for suffix
    /// matching; nil means exact match.
    public static func suffixDomain(of host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix(".") {
            return String(trimmed.dropFirst())
        }
        if trimmed.hasPrefix("*.") {
            return String(trimmed.dropFirst(2))
        }
        return nil
    }
}
