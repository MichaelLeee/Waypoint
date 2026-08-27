//
//  WaypointRule.swift
//  Waypoint
//

import Foundation

class WaypointRule: Codable {
    let type: String
    let payload: String?
    let proxy: String?
}

class WaypointRuleResponse: Codable {
    var rules: [WaypointRule]?

    static func empty() -> WaypointRuleResponse {
        return WaypointRuleResponse()
    }

    static func fromData(_ data: Data) -> WaypointRuleResponse {
        let decoder = JSONDecoder()
        let model = try? decoder.decode(WaypointRuleResponse.self, from: data)
        return model ?? WaypointRuleResponse.empty()
    }
}
