//
//  WaypointConfig.swift
//  Waypoint
//
import Foundation

enum WaypointProxyMode: String, Codable {
    case rule
    case global
    case direct
    #if PRO_VERSION
        case script
    #endif
}

extension WaypointProxyMode {
    var name: String {
        switch self {
        case .rule: return NSLocalizedString("Rule", comment: "")
        case .global: return NSLocalizedString("Global", comment: "")
        case .direct: return NSLocalizedString("Direct", comment: "")
        #if PRO_VERSION
            case .script: return NSLocalizedString("Script", comment: "")
        #endif
        }
    }
}

enum WaypointLogLevel: String, Codable {
    case info
    case warning
    case error
    case debug
    case silent
    case unknow = "unknown"
}

class WaypointConfig: Codable {
    private var port: Int
    private var socksPort: Int
    var allowLan: Bool
    var mixedPort: Int
    var mode: WaypointProxyMode
    var logLevel: WaypointLogLevel

    var usedHttpPort: Int {
        if mixedPort > 0 {
            return mixedPort
        }
        return port
    }

    var usedSocksPort: Int {
        if mixedPort > 0 {
            return mixedPort
        }
        return socksPort
    }

    private enum CodingKeys: String, CodingKey {
        case port, socksPort = "socks-port", mixedPort = "mixed-port", allowLan = "allow-lan", mode, logLevel = "log-level"
    }

    static func fromData(_ data: Data) -> WaypointConfig? {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(WaypointConfig.self, from: data)
        } catch let err {
            Logger.log((err as NSError).description, level: .error)
            return nil
        }
    }

    func copy() -> WaypointConfig? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        let copy = try? JSONDecoder().decode(WaypointConfig.self, from: data)
        return copy
    }
}
