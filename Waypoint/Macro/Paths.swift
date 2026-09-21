//
//  Paths.swift
//  Waypoint
//
import Foundation

let kConfigFolderPath = "\(NSHomeDirectory())/.config/waypoint/"

let kDefaultConfigFilePath = "\(kConfigFolderPath)config.yaml"

enum Paths {
    /// Config names arrive from user input (the add-remote-config form), the
    /// `waypoint://` URL scheme, and the Shortcuts/App Intents surface, and each
    /// one becomes a file name under the config folder. A name carrying a path
    /// separator would escape that folder: it is read as the core's config, and
    /// adding it deletes and overwrites whatever it resolves to.
    static func isValidConfigName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        // A separator would escape the folder; an embedded NUL would truncate
        // the C path it is handed to.
        return !name.contains { $0 == "/" || $0 == "\0" }
    }

    static func localConfigPath(for name: String) -> String {
        return "\(kConfigFolderPath)\(configFileName(for: name))"
    }

    /// Every path built from a config name goes through here, so an invalid
    /// name falls back to the default instead of composing a path outside the
    /// config folder. Callers that take a name from the user should reject it
    /// up front with `isValidConfigName` and report the error.
    static func configFileName(for name: String) -> String {
        return "\(isValidConfigName(name) ? name : "config").yaml"
    }
}
