//
//  SavedProxyModel.swift
//  WaypointCore
//  Persisted record of which proxy was last selected in a group for a
//  given config. The storage layer (Persistence/UserDefaults) stays in the
//  app target; the model and its dedupe logic live here so they can be
//  tested in isolation.
//

import Foundation

public struct SavedProxyModel: Codable, Equatable, Sendable {
    public let group: String
    public let selected: String
    public let config: String

    public init(group: String, selected: String, config: String) {
        self.group = group
        self.selected = selected
        self.config = config
    }

    /// Identity of a record: which proxy group, within which config file.
    /// Deliberately excludes `selected` so re-selecting a proxy in the same
    /// group replaces the previous record instead of accumulating entries.
    public var key: String {
        "\(group)_\(config)"
    }

    /// First-wins dedupe on `key`, preserving input order.
    public static func deduplicated(_ models: [SavedProxyModel]) -> [SavedProxyModel] {
        var seen = Set<String>()
        return models.filter { model in
            let pass = !seen.contains(model.key)
            seen.insert(model.key)
            return pass
        }
    }
}
