//
//  WaypointProvider.swift
//  Waypoint
//

import Cocoa

class WaypointProviderResp: Codable {
    let allProviders: [WaypointProxyName: WaypointProvider]
    lazy var providers: [WaypointProxyName: WaypointProvider] = allProviders.filter { $0.value.vehicleType != .Compatible }

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

class WaypointProvider: Codable {
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
