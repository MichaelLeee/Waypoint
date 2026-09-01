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

    /// ".example.com" matches the domain itself and every subdomain;
    /// anything else is an exact (case-insensitive) host match.
    public func matches(host candidate: String) -> Bool {
        let lowered = candidate.lowercased()
        if host.hasPrefix(".") {
            let domain = String(host.dropFirst()).lowercased()
            return lowered == domain || lowered.hasSuffix("." + domain)
        }
        return lowered == host.lowercased()
    }
}
