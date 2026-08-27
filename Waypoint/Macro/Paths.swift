//
//  Paths.swift
//  Waypoint
//
import Foundation

let kConfigFolderPath = "\(NSHomeDirectory())/.config/waypoint/"

let kDefaultConfigFilePath = "\(kConfigFolderPath)config.yaml"

enum Paths {
    static func localConfigPath(for name: String) -> String {
        return "\(kConfigFolderPath)\(configFileName(for: name))"
    }

    static func configFileName(for name: String) -> String {
        return "\(name).yaml"
    }
}
