//
//  WireProxyModels.swift
//  WaypointNetworking
//  Sendable value models for the /proxies and /providers/proxies API,
//  including the provider merge (`updateProvider`) and group-resolution
//  logic, testable here without AppKit.
//

import Foundation

public enum WaypointProxyType: String, Codable, Sendable {
    case urltest = "URLTest"
    case fallback = "Fallback"
    case loadBalance = "LoadBalance"
    case select = "Selector"
    case direct = "Direct"
    case reject = "Reject"
    case rejectDrop = "RejectDrop"
    case compatible = "Compatible"
    case pass = "Pass"
    case passRule = "PassRule"
    case shadowsocks = "Shadowsocks"
    case shadowsocksR = "ShadowsocksR"
    case socks5 = "Socks5"
    case http = "Http"
    case vmess = "Vmess"
    case snell = "Snell"
    case trojan = "Trojan"
    case relay = "Relay"
    case unknown = "Unknown"
    case wireguard = "WireGuard"
    case vless = "Vless"
    case hysteria = "Hysteria"
    case hysteria2 = "Hysteria2"
    case tuic = "Tuic"

    public static let proxyGroups: [WaypointProxyType] = [.select, .urltest, .fallback, .loadBalance]

    public var isAutoGroup: Bool {
        switch self {
        case .urltest, .fallback, .loadBalance:
            return true
        default:
            return false
        }
    }

    public static func isProxyGroup(_ proxy: WaypointProxy) -> Bool {
        switch proxy.type {
        case .select, .urltest, .fallback, .loadBalance, .relay: return true
        default: return false
        }
    }

    public static func isBuiltInProxy(_ proxy: WaypointProxy) -> Bool {
        switch proxy.name {
        case "DIRECT", "REJECT": return true
        default: return false
        }
    }
}

public typealias WaypointProxyName = String
public typealias WaypointProviderName = String

public struct WaypointProxySpeedHistory: Codable, Sendable {
    public let time: Date
    public let delay: Int
    public let meanDelay: Int?

    // @unchecked: only holds a lazily built DateFormatter.
    final class HisDateFormaterInstance: @unchecked Sendable {
        static let shared = HisDateFormaterInstance()
        lazy var formater: DateFormatter = {
            var f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f
        }()
    }

    public var delayDisplay: String {
        if let meanDelay, meanDelay > 0 {
            switch meanDelay {
            case 0: return NSLocalizedString("fail", comment: "")
            default: return "\(meanDelay) ms"
            }
        } else {
            switch delay {
            case 0: return NSLocalizedString("fail", comment: "")
            default: return "\(delay) ms"
            }
        }
    }

    public var dateDisplay: String { HisDateFormaterInstance.shared.formater.string(from: time) }

    public var displayString: String { "\(dateDisplay) \(delayDisplay)" }

    public init(time: Date, delay: Int, meanDelay: Int?) {
        self.time = time
        self.delay = delay
        self.meanDelay = meanDelay
    }

    /// Equality by display string: two entries in the same minute with the
    /// same delay text are considered identical (legacy behavior the history
    /// menu relies on for dedupe).
    public static func == (lhs: WaypointProxySpeedHistory, rhs: WaypointProxySpeedHistory) -> Bool {
        lhs.displayString == rhs.displayString
    }
}

public struct WaypointProxy: Codable, Sendable {
    public let name: WaypointProxyName
    public let type: WaypointProxyType
    public let all: [WaypointProxyName]?
    public let history: [WaypointProxySpeedHistory]
    public let now: WaypointProxyName?
    public let alive: Bool?

    public enum SpeedtestAbleItem: Equatable, Sendable {
        case proxy(name: WaypointProxyName)
        case provider(name: WaypointProxyName, provider: WaypointProviderName)
    }

    private enum CodingKeys: String, CodingKey {
        case type, all, history, now, name, alive
    }

    public init(
        name: WaypointProxyName,
        type: WaypointProxyType,
        all: [WaypointProxyName]?,
        history: [WaypointProxySpeedHistory],
        now: WaypointProxyName?,
        alive: Bool?
    ) {
        self.name = name
        self.type = type
        self.all = all
        self.history = history
        self.now = now
        self.alive = alive
    }
}

public struct WaypointProxyResp: Sendable {
    public private(set) var proxies: [WaypointProxy]

    public private(set) var proxiesMap: [WaypointProxyName: WaypointProxy]

    /// Provider ownership resolved by `updateProvider`, replacing the old
    /// per-proxy weak back-reference.
    public private(set) var providerNamesByProxy: [WaypointProxyName: WaypointProviderName]

    public private(set) var enclosingProviderResp: WaypointProviderResp?

    public init(_ data: Data?) {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxiesDict = root["proxies"] as? [String: Any]
        else {
            self.proxiesMap = [:]
            self.providerNamesByProxy = [:]
            self.enclosingProviderResp = nil
            self.proxies = []
            return
        }

        var proxiesModel = [WaypointProxy]()
        var proxiesMap = [WaypointProxyName: WaypointProxy]()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(DateFormatter.js)
        for value in proxiesDict.values {
            guard let data = try? JSONSerialization.data(withJSONObject: value) else {
                continue
            }
            guard let proxy = try? decoder.decode(WaypointProxy.self, from: data) else {
                continue
            }
            proxiesModel.append(proxy)
            proxiesMap[proxy.name] = proxy
        }
        self.proxiesMap = proxiesMap
        self.providerNamesByProxy = [:]
        self.enclosingProviderResp = nil
        self.proxies = proxiesModel
    }

    public mutating func updateProvider(_ providerResp: WaypointProviderResp) {
        enclosingProviderResp = providerResp
        for provider in providerResp.providers.values {
            for proxy in provider.proxies {
                providerNamesByProxy[proxy.name] = provider.name
                proxiesMap[proxy.name] = proxy
                proxies.append(proxy)
            }
        }
    }

    /// Resolves the speed-testable entries of a group against the merged data.
    public func speedtestAbleItems(for name: WaypointProxyName) -> [WaypointProxy.SpeedtestAbleItem] {
        guard let group = proxiesMap[name], let allProxys = group.all else { return [] }
        var items = [WaypointProxy.SpeedtestAbleItem]()
        for proxyName in allProxys {
            guard let proxy = proxiesMap[proxyName] else { continue }
            if let provider = providerNamesByProxy[proxy.name] {
                items.append(.provider(name: proxy.name, provider: provider))
            } else {
                items.append(.proxy(name: proxy.name))
            }
        }
        return items
    }

    public var proxyGroups: [WaypointProxy] {
        var sortMap = [WaypointProxyName: Int]()
        for (idx, proxy) in (proxiesMap["GLOBAL"]?.all ?? []).enumerated() {
            sortMap[proxy] = idx
        }
        return proxies.filter {
            WaypointProxyType.isProxyGroup($0)
        }.sorted(by: { sortMap[$0.name] ?? -1 < sortMap[$1.name] ?? -1 })
    }
}

public struct WaypointProviderResp: Codable, Sendable {
    public let allProviders: [WaypointProxyName: WaypointProvider]

    public var providers: [WaypointProxyName: WaypointProvider] {
        allProviders.filter { $0.value.vehicleType != .Compatible }
    }

    public init() {
        allProviders = [:]
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(DateFormatter.js)
        return decoder
    }

    private enum CodingKeys: String, CodingKey {
        case allProviders = "providers"
    }
}

public struct WaypointProvider: Codable, Sendable {
    public enum ProviderType: String, Codable, Sendable {
        case Proxy
        case Rule
    }

    public enum ProviderVehicleType: String, Codable, Sendable {
        case HTTP
        case File
        case Compatible
        case Unknown
    }

    public let name: WaypointProviderName
    public let proxies: [WaypointProxy]
    public let type: ProviderType
    public let vehicleType: ProviderVehicleType

    public init(
        name: WaypointProviderName,
        proxies: [WaypointProxy],
        type: ProviderType,
        vehicleType: ProviderVehicleType
    ) {
        self.name = name
        self.proxies = proxies
        self.type = type
        self.vehicleType = vehicleType
    }
}

public extension DateFormatter {
    /// mihomo's timestamp format: fractional-truncated ISO 8601 with an
    /// ICU "Z" (RFC 822 offset) suffix, e.g. 2026-09-07T12:00:00.1+0000.
    static var js: DateFormatter {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: NSCalendar.Identifier.ISO8601.rawValue)
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SZ"
        return dateFormatter
    }
}
