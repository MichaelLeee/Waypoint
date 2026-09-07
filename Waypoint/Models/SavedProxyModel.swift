//
//  SavedProxyModel.swift
//  Waypoint
//  App-side storage for the model (which lives in WaypointCore): backed by
//  Persistence/UserDefaults.
//

import WaypointCore

extension SavedProxyModel {
    static func loadsFromUserDefault() -> [SavedProxyModel] {
        guard let models: [SavedProxyModel] = Persistence.loadCodable(
            [SavedProxyModel].self, forKey: Persistence.Key.savedProxyModels) else {
            return []
        }
        return deduplicated(models)
    }

    static func save(_ models: [SavedProxyModel]) {
        Persistence.saveCodable(models, forKey: Persistence.Key.savedProxyModels)
    }
}
