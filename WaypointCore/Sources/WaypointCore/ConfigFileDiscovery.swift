//
//  ConfigFileDiscovery.swift
//  WaypointCore
//  Turns a directory listing into config names by keeping only "*.yaml"
//  entries and stripping the extension. Pure so the FileManager access can
//  stay in the caller and be tested with synthetic listings.
//

import Foundation

public enum ConfigFileDiscovery {
    public static func configNames(fromFileNames fileNames: [String]) -> [String] {
        fileNames
            .filter { String($0.split(separator: ".").last ?? "") == "yaml" }
            .map { $0.split(separator: ".").dropLast().joined(separator: ".") }
    }
}
