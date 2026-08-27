//
//  DateFormatter+.swift
//  Waypoint
//

import Cocoa

extension DateFormatter {
    static var js: DateFormatter {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: NSCalendar.Identifier.ISO8601.rawValue)
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SZ"
        return dateFormatter
    }

    static var simple: DateFormatter {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM-dd HH:mm:ss"
        return dateFormatter
    }
}
