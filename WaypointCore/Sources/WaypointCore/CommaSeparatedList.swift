//
//  CommaSeparatedList.swift
//  WaypointCore
//  Parsing for the comma-separated list fields in Settings.
//

import Foundation

public enum CommaSeparatedList {
    /// Splits on commas and trims each entry, so a trailing comma or stray
    /// spaces never persist a blank ignore/SSID entry.
    public static func parse(_ text: String) -> [String] {
        text.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
