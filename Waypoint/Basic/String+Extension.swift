//
//  String+Extension.swift
//  Waypoint
//
import Foundation

extension String {
    func isUrlVaild() -> Bool {
        guard !isEmpty else { return false }
        guard let url = URL(string: self) else { return false }

        guard url.host != nil,
              let scheme = url.scheme else {
            return false
        }
        return ["http", "https"].contains(scheme)
    }
}
