//
//  WaypointProxy.swift
//  Waypoint
//

import Cocoa

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

class WaypointProxySpeedHistory: Codable {
    let time: Date
    let delay: Int
    let meanDelay: Int?

    // @unchecked: only holds a lazily built DateFormatter.
    class HisDateFormaterInstance: @unchecked Sendable {
        static let shared = HisDateFormaterInstance()
        lazy var formater: DateFormatter = {
            var f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f
        }()
    }

    lazy var delayDisplay: String = {
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
    }()

    lazy var dateDisplay: String = HisDateFormaterInstance.shared.formater.string(from: time)

    lazy var displayString: String = "\(dateDisplay) \(delayDisplay)"
}

class WaypointProxy: Codable {
    let name: WaypointProxyName
    let type: WaypointProxyType
    let all: [WaypointProxyName]?
    let history: [WaypointProxySpeedHistory]
    let now: WaypointProxyName?
    let alive: Bool?
    weak var enclosingResp: WaypointProxyResp?
    weak var enclosingProvider: WaypointProvider?

    enum SpeedtestAbleItem {
        case proxy(name: WaypointProxyName)
        case provider(name: WaypointProxyName, provider: WaypointProviderName)
    }

    // Tolerated race: this is only a memoization cache for text widths.
    private nonisolated(unsafe) static var nameLengthCachedMap = [WaypointProxyName: CGFloat]()
    static func cleanCache() {
        nameLengthCachedMap.removeAll()
    }

    lazy var speedtestAble: [SpeedtestAbleItem] = {
        guard let resp = enclosingResp, let allProxys = all else { return [] }
        var proxys = [SpeedtestAbleItem]()
        for proxy in allProxys {
            if let p = resp.proxiesMap[proxy] {
                if let provider = p.enclosingProvider {
                    proxys.append(.provider(name: p.name, provider: provider.name))
                } else {
                    proxys.append(.proxy(name: p.name))
                }
            }
        }
        return proxys
    }()

    lazy var isSpeedTestable: Bool = !speedtestAble.isEmpty

    private enum CodingKeys: String, CodingKey {
        case type, all, history, now, name, alive
    }

    lazy var maxProxyNameLength: CGFloat = {
        let rect = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20)

        let lengths = all?.compactMap { name -> CGFloat in
            if let length = WaypointProxy.nameLengthCachedMap[name] {
                return length
            }

            let rects = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20)
            let attr = [NSAttributedString.Key.font: NSFont.menuBarFont(ofSize: 14)]
            let length = (name as NSString)
                .boundingRect(with: rect,
                              options: .usesLineFragmentOrigin,
                              attributes: attr).width
            WaypointProxy.nameLengthCachedMap[name] = length
            return length
        }
        return lengths?.max() ?? 0
    }()
}

class WaypointProxyResp {
    var proxies: [WaypointProxy]

    var proxiesMap: [WaypointProxyName: WaypointProxy]

    var enclosingProviderResp: WaypointProviderResp?

    init(_ data: Data?) {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxiesDict = root["proxies"] as? [String: Any]
        else {
            self.proxiesMap = [:]
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
        self.proxies = proxiesModel

        for proxy in self.proxies {
            proxy.enclosingResp = self
        }
    }

    func updateProvider(_ providerResp: WaypointProviderResp) {
        enclosingProviderResp = providerResp
        for provider in providerResp.providers.values {
            for proxy in provider.proxies {
                proxy.enclosingProvider = provider
                proxiesMap[proxy.name] = proxy
                proxies.append(proxy)
            }
        }
    }

    lazy var proxiesSortMap: [WaypointProxyName: Int] = {
        var map = [WaypointProxyName: Int]()
        for (idx, proxy) in (self.proxiesMap["GLOBAL"]?.all ?? []).enumerated() {
            map[proxy] = idx
        }
        return map
    }()

    lazy var proxyGroups: [WaypointProxy] = proxies.filter {
        WaypointProxyType.isProxyGroup($0)
    }.sorted(by: { proxiesSortMap[$0.name] ?? -1 < proxiesSortMap[$1.name] ?? -1 })

    lazy var longestProxyGroupName = proxyGroups.max { $1.name.count > $0.name.count }?.name ?? ""

    lazy var maxProxyNameLength: CGFloat = {
        let rect = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20)
        let attr = [NSAttributedString.Key.font: NSFont.menuBarFont(ofSize: 0)]
        return (self.longestProxyGroupName as NSString)
            .boundingRect(with: rect,
                          options: .usesLineFragmentOrigin,
                          attributes: attr).width
    }()
}
