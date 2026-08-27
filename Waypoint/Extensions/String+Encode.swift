//
//  String+Encode.swift
//  Waypoint
//

import Cocoa

extension String {
    var encoded: String {
        return addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? ""
    }
}
