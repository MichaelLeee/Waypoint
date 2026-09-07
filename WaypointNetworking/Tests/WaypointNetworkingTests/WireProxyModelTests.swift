//
//  WireProxyModelTests.swift
//  WaypointNetworkingTests
//

import Foundation
import Testing
@testable import WaypointNetworking

struct WireProxyModelTests {
    private let proxiesJSON = #"""
    {
      "proxies": {
        "GLOBAL": {
          "name": "GLOBAL", "type": "Selector",
          "all": ["Proxy", "Auto", "DIRECT"],
          "now": "Proxy", "history": []
        },
        "Auto": {
          "name": "Auto", "type": "URLTest",
          "all": ["Proxy"], "now": "Proxy", "history": []
        },
        "Proxy": {
          "name": "Proxy", "type": "Shadowsocks",
          "history": [
            {"time": "2026-09-07T12:00:00.1+0000", "delay": 120, "meanDelay": 0}
          ]
        },
        "DIRECT": {"name": "DIRECT", "type": "Direct", "history": []}
      }
    }
    """#

    @Test func decodesProxiesIntoMap() {
        let resp = WaypointProxyResp(Data(proxiesJSON.utf8))
        #expect(resp.proxiesMap.count == 4)
        #expect(resp.proxiesMap["Auto"]?.type == .urltest)
        #expect(resp.proxiesMap["Auto"]?.type.isAutoGroup == true)
        #expect(resp.proxiesMap["Proxy"]?.history.first?.delay == 120)
    }

    @Test func malformedDataYieldsEmptyResp() {
        let resp = WaypointProxyResp(Data("garbage".utf8))
        #expect(resp.proxies.isEmpty)
        #expect(resp.proxiesMap.isEmpty)
        #expect(WaypointProxyResp(nil).proxies.isEmpty)
    }

    @Test func updateProviderMergesAndRecordsOwnership() throws {
        var resp = WaypointProxyResp(Data(proxiesJSON.utf8))
        let providerJSON = #"""
        {
          "providers": {
            "ProviderA": {
              "name": "ProviderA", "type": "Proxy", "vehicleType": "HTTP",
              "proxies": [
                {"name": "Node1", "type": "Vmess", "history": []},
                {"name": "Node2", "type": "Trojan", "history": []}
              ]
            },
            "FileProvider": {
              "name": "FileProvider", "type": "Proxy", "vehicleType": "Compatible",
              "proxies": []
            }
          }
        }
        """#
        let providerResp = try WaypointProviderResp.decoder.decode(
            WaypointProviderResp.self, from: Data(providerJSON.utf8))
        #expect(providerResp.providers.count == 1)

        resp.updateProvider(providerResp)
        #expect(resp.proxiesMap["Node1"]?.type == .vmess)
        #expect(resp.providerNamesByProxy["Node1"] == "ProviderA")
        #expect(resp.providerNamesByProxy["Node2"] == "ProviderA")
        #expect(resp.providerNamesByProxy["Proxy"] == nil)
        #expect(resp.enclosingProviderResp?.allProviders.count == 2)
    }

    @Test func speedtestAbleItemsResolveProviderOwnership() throws {
        var resp = WaypointProxyResp(Data(proxiesJSON.utf8))
        let providerJSON = #"""
        {
          "providers": {
            "ProviderA": {
              "name": "ProviderA", "type": "Proxy", "vehicleType": "HTTP",
              "proxies": [{"name": "Proxy", "type": "Shadowsocks", "history": []}]
            }
          }
        }
        """#
        let providerResp = try WaypointProviderResp.decoder.decode(
            WaypointProviderResp.self, from: Data(providerJSON.utf8))
        resp.updateProvider(providerResp)

        // GLOBAL.all = ["Proxy", "Auto", "DIRECT"]; Proxy resolved to a
        // provider above, the other two stay plain proxies.
        let items = resp.speedtestAbleItems(for: "GLOBAL")
        #expect(items.contains(.provider(name: "Proxy", provider: "ProviderA")))
        #expect(items.contains(.proxy(name: "Auto")))
        #expect(items.contains(.proxy(name: "DIRECT")))
    }

    @Test func speedtestAbleItemsForUnknownGroupIsEmpty() {
        let resp = WaypointProxyResp(Data(proxiesJSON.utf8))
        #expect(resp.speedtestAbleItems(for: "Nope").isEmpty)
        #expect(resp.speedtestAbleItems(for: "Proxy").isEmpty)
    }

    @Test func proxyGroupsSortedByGlobalOrder() {
        let resp = WaypointProxyResp(Data(proxiesJSON.utf8))
        let groups = resp.proxyGroups
        #expect(groups.map(\.name) == ["GLOBAL", "Auto"])
    }

    @Test func builtInProxyDetection() throws {
        let direct = try JSONDecoder().decode(
            WaypointProxy.self,
            from: Data(#"{"name": "DIRECT", "type": "Direct", "history": []}"#.utf8))
        let node = try JSONDecoder().decode(
            WaypointProxy.self,
            from: Data(#"{"name": "Node", "type": "Vmess", "history": []}"#.utf8))
        #expect(WaypointProxyType.isBuiltInProxy(direct))
        #expect(!WaypointProxyType.isBuiltInProxy(node))
        #expect(WaypointProxyType.isProxyGroup(direct) == false)
    }

    @Test func delayDisplayPrefersMeanDelay() {
        let mean = WaypointProxySpeedHistory(time: Date(), delay: 0, meanDelay: 55)
        #expect(mean.delayDisplay == "55 ms")
        let plain = WaypointProxySpeedHistory(time: Date(), delay: 88, meanDelay: nil)
        #expect(plain.delayDisplay == "88 ms")
        let fail = WaypointProxySpeedHistory(time: Date(), delay: 0, meanDelay: nil)
        #expect(fail.delayDisplay == "fail")
    }

    @Test func equalityIsByDisplayString() {
        // Same minute-of-day and same delay text -> equal, even at different
        // instants (legacy dedupe semantics used by the history menu).
        let a = WaypointProxySpeedHistory(time: Date(timeIntervalSince1970: 100), delay: 10, meanDelay: nil)
        let b = WaypointProxySpeedHistory(time: Date(timeIntervalSince1970: 119), delay: 10, meanDelay: nil)
        #expect(a == b)
        let c = WaypointProxySpeedHistory(time: Date(timeIntervalSince1970: 200), delay: 10, meanDelay: nil)
        #expect(a != c)
    }
}
