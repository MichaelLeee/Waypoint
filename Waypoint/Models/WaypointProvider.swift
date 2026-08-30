//
//  WaypointProvider.swift
//  Waypoint
//

import Foundation

struct WaypointProviderResp: Codable, Sendable {
    let allProviders: [WaypointProxyName: WaypointProvider]

    var providers: [WaypointProxyName: WaypointProvider] {
        allProviders.filter { $0.value.vehicleType != .Compatible }
    }

    init() {
        allProviders = [:]
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(DateFormatter.js)
        return decoder
    }

    private enum CodingKeys: String, CodingKey {
        case allProviders = "providers"
    }
}

struct WaypointProvider: Codable, Sendable {
    enum ProviderType: String, Codable {
        case Proxy
        case Rule
    }

    enum ProviderVehicleType: String, Codable {
        case HTTP
        case File
        case Compatible
        case Unknown
    }

    let name: WaypointProviderName
    let proxies: [WaypointProxy]
    let type: ProviderType
    let vehicleType: ProviderVehicleType
}
