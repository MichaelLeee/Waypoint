//
//  DateFormatter+.swift
//  Waypoint
//

import Cocoa

extension DateFormatter {

    static var simple: DateFormatter {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM-dd HH:mm:ss"
        return dateFormatter
    }
}
