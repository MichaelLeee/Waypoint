//
//  UrlValidation.swift
//  WaypointCore
//  Gate for user-entered endpoints (remote config, benchmark URL, remote
//  control): only absolute http(s) URLs with a host count as valid.
//

import Foundation

public extension String {
    func isValidHttpUrl() -> Bool {
        // `host != nil` on its own is not enough: "http:///path" parses with a
        // present-but-empty host, which would pass a check that promises one.
        guard !isEmpty, let url = URL(string: self), let scheme = url.scheme,
              let host = url.host, !host.isEmpty else {
            return false
        }
        return ["http", "https"].contains(scheme)
    }
}
