//
//  SavedProxyModel.swift
//  Waypoint
//

import Cocoa

struct SavedProxyModel: Codable {
    let group: WaypointProxyName
    let selected: WaypointProxyName
    let config: String

    var key: String {
        return "\(group)_\(config)"
    }

    static func loadsFromUserDefault() -> [SavedProxyModel] {
        guard let models: [SavedProxyModel] = Persistence.loadCodable(
            [SavedProxyModel].self, forKey: Persistence.Key.savedProxyModels) else {
            return []
        }
        var set = Set<String>()
        return models.filter { model in
            let pass = !set.contains(model.key)
            set.insert(model.key)
            return pass
        }
    }

    static func save(_ models: [SavedProxyModel]) {
        Persistence.saveCodable(models, forKey: Persistence.Key.savedProxyModels)
    }
}

extension SavedProxyModel: Equatable {}
