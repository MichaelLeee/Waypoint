//
//  WaypointProxy.swift
//  Waypoint
//
//  Sendable value models for the proxy API. Text measuring and provider
//  back-references live in the app layer so these types stay AppKit-free.
//

import Foundation

enum WaypointProxyType: String, Codable {
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

    static let proxyGroups: [WaypointProxyType] = [.select, .urltest, .fallback, .loadBalance]

    var isAutoGroup: Bool {
        switch self {
        case .urltest, .fallback, .loadBalance:
            return true
        default:
            return false
        }
    }

    static func isProxyGroup(_ proxy: WaypointProxy) -> Bool {
        switch proxy.type {
        case .select, .urltest, .fallback, .loadBalance, .relay: return true
        default: return false
        }
    }

    static func isBuiltInProxy(_ proxy: WaypointProxy) -> Bool {
        switch proxy.name {
        case "DIRECT", "REJECT": return true
        default: return false
        }
    }
}

typealias WaypointProxyName = String
typealias WaypointProviderName = String

struct WaypointProxySpeedHistory: Codable, Sendable {
    let time: Date
    let delay: Int
    let meanDelay: Int?

    // @unchecked: only holds a lazily built DateFormatter.
    final class HisDateFormaterInstance: @unchecked Sendable {
        static let shared = HisDateFormaterInstance()
        lazy var formater: DateFormatter = {
            var f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f
        }()
    }

    var delayDisplay: String {
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

    var dateDisplay: String { HisDateFormaterInstance.shared.formater.string(from: time) }

    var displayString: String { "\(dateDisplay) \(delayDisplay)" }
}

struct WaypointProxy: Codable, Sendable {
    let name: WaypointProxyName
    let type: WaypointProxyType
    let all: [WaypointProxyName]?
    let history: [WaypointProxySpeedHistory]
    let now: WaypointProxyName?
    let alive: Bool?

    enum SpeedtestAbleItem: Sendable {
        case proxy(name: WaypointProxyName)
        case provider(name: WaypointProxyName, provider: WaypointProviderName)
    }

    private enum CodingKeys: String, CodingKey {
        case type, all, history, now, name, alive
    }
}

struct WaypointProxyResp: Sendable {
    private(set) var proxies: [WaypointProxy]

    private(set) var proxiesMap: [WaypointProxyName: WaypointProxy]

    /// Provider ownership resolved by `updateProvider`, replacing the old
    /// per-proxy weak back-reference.
    private(set) var providerNamesByProxy: [WaypointProxyName: WaypointProviderName]

    private(set) var enclosingProviderResp: WaypointProviderResp?

    init(_ data: Data?) {
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

    mutating func updateProvider(_ providerResp: WaypointProviderResp) {
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
    func speedtestAbleItems(for name: WaypointProxyName) -> [WaypointProxy.SpeedtestAbleItem] {
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

    var proxyGroups: [WaypointProxy] {
        var sortMap = [WaypointProxyName: Int]()
        for (idx, proxy) in (proxiesMap["GLOBAL"]?.all ?? []).enumerated() {
            sortMap[proxy] = idx
        }
        return proxies.filter {
            WaypointProxyType.isProxyGroup($0)
        }.sorted(by: { sortMap[$0.name] ?? -1 < sortMap[$1.name] ?? -1 })
    }
}
