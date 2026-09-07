//
//  UrlValidation.swift
//  WaypointCore
//  Gate for user-entered endpoints (remote config, benchmark URL, remote
//  control): only absolute http(s) URLs with a host count as valid.
//

import Foundation

public extension String {
    func isValidHttpUrl() -> Bool {
        guard !isEmpty, let url = URL(string: self), url.host != nil,
              let scheme = url.scheme else {
            return false
        }
        return ["http", "https"].contains(scheme)
    }
}
