//
//  WaypointConfigTests.swift
//  WaypointTests
//

import Testing
@testable import Waypoint

@Suite("Config generation")
struct WaypointConfigTests {

    // MARK: - TunConfig YAML

    @Test("TUN block renders enabled mixed stack with dns-hijack by default")
    func tunYamlDefault() {
        let yaml = TunConfig().yamlString
        #expect(yaml.hasPrefix("tun:\n"))
        #expect(yaml.contains("  enable: true"))
        #expect(yaml.contains("  stack: mixed"))
        #expect(yaml.contains("  device: utun"))
        #expect(yaml.contains("  auto-route: true"))
        #expect(yaml.contains("  auto-detect-interface: true"))
        #expect(yaml.contains("  strict-route: true"))
        #expect(yaml.contains("  dns-hijack:\n    - any:53"))
        #expect(!yaml.contains("mtu"))
    }

    @Test("TUN block includes mtu only when set and omits empty dns-hijack")
    func tunYamlMtu() {
        var tun = TunConfig()
        tun.mtu = 1400
        tun.dnsHijack = []
        let yaml = tun.yamlString
        #expect(yaml.contains("  mtu: 1400"))
        #expect(!yaml.contains("dns-hijack"))
    }

    // MARK: - Section apply

    @Test("TUN apply appends block to a config without one")
    func tunApplyAppends() {
        let out = TunConfig.apply(TunConfig(), to: "port: 7890\nmode: rule\n")
        #expect(out.hasPrefix("port: 7890\nmode: rule\n\ntun:\n"))
        #expect(out.hasSuffix("\n"))
        #expect(!out.contains("tun:\n  enable: false"))
    }

    @Test("Section apply normalizes a missing trailing newline")
    func applyNoTrailingNewline() {
        let out = TunConfig.apply(TunConfig(), to: "port: 7890")
        #expect(out.hasPrefix("port: 7890\n\ntun:\n"))
    }

    @Test("TUN apply is a no-op when the config declares tun:")
    func tunApplySkipsExisting() {
        let config = "port: 7890\ntun:\n  enable: false\n"
        #expect(TunConfig.apply(TunConfig(), to: config) == config)
    }

    @Test("TUN apply with nil returns the config unchanged")
    func tunApplyNil() {
        let config = "port: 7890\n"
        #expect(TunConfig.apply(nil as TunConfig?, to: config) == config)
    }

    // MARK: - DnsConfig

    @Test("DNS block renders fake-ip defaults")
    func dnsYamlDefault() {
        let yaml = DnsConfig().yamlString
        #expect(yaml.hasPrefix("dns:\n"))
        #expect(yaml.contains("  enable: true"))
        #expect(yaml.contains("  enhanced-mode: fake-ip"))
        #expect(yaml.contains("  fake-ip-range: 198.18.0.1/16"))
    }

    @Test("DNS apply appends the block when the config has no top-level dns:")
    func dnsApplyAppends() {
        let out = DnsConfig.apply(DnsConfig(), to: "port: 7890\n")
        #expect(out.hasPrefix("port: 7890\n\ndns:\n"))
        #expect(out.contains("  enhanced-mode: fake-ip"))
    }

    @Test("DNS apply is a no-op when the config declares dns: at top level")
    func dnsApplySkipsExisting() {
        let config = "port: 7890\ndns:\n  enable: false\n"
        #expect(DnsConfig.apply(DnsConfig(), to: config) == config)
    }

    @Test("DNS apply injects when dns: appears only nested in another section")
    func dnsApplyNested() {
        let config = "proxy-providers:\n  provider1:\n    dns:\n      enable: true\n"
        let out = DnsConfig.apply(DnsConfig(), to: config)
        #expect(out.hasSuffix("\ndns:\n  enable: true\n  enhanced-mode: fake-ip\n  fake-ip-range: 198.18.0.1/16\n"))
    }

    // MARK: - AdBlockConfig

    @Test("Ad-block rules are inserted directly under an existing rules: section")
    func adBlockInsertsUnderRules() {
        let config = "mixed-port: 7890\nrules:\n  - DOMAIN,example.com,DIRECT\n  - MATCH,DIRECT\n"
        let out = AdBlockConfig.apply(to: config)
        let lines = out.split(separator: "\n").map(String.init)
        guard let rulesIdx = lines.firstIndex(of: "rules:") else {
            Issue.record("rules: section missing")
            return
        }
        #expect(lines[rulesIdx + 1] == "  - GEOSITE,category-ads-all,REJECT")
        #expect(lines[rulesIdx + 2] == "  - GEOSITE,category-public-tracker,REJECT")
        #expect(lines[rulesIdx + 3] == "  - DOMAIN,example.com,DIRECT")
    }

    @Test("Ad-block apply creates a rules section with MATCH,DIRECT when absent")
    func adBlockCreatesRules() {
        let out = AdBlockConfig.apply(to: "mixed-port: 7890\n")
        #expect(out.hasSuffix(
            "rules:\n" +
            "  - GEOSITE,category-ads-all,REJECT\n" +
            "  - GEOSITE,category-public-tracker,REJECT\n" +
            "  - MATCH,DIRECT\n"
        ))
    }

    @Test("Ad-block apply is idempotent")
    func adBlockIdempotent() {
        let once = AdBlockConfig.apply(to: "rules:\n  - MATCH,DIRECT\n")
        #expect(AdBlockConfig.apply(to: once) == once)
    }

    @Test("Ad-block apply re-injects only the rules that are missing")
    func adBlockPartial() {
        let config = "rules:\n  - GEOSITE,category-ads-all,REJECT\n  - MATCH,DIRECT\n"
        let out = AdBlockConfig.apply(to: config)
        let adsCount = out.components(separatedBy: "GEOSITE,category-ads-all").count - 1
        #expect(adsCount == 1)
        #expect(out.components(separatedBy: "GEOSITE,category-public-tracker").count - 1 == 1)
    }

    // MARK: - YAML top-level detection

    @Test("hasTopLevelSection ignores indented keys")
    func topLevelSection() {
        #expect("tun:\n  enable: true\n".hasTopLevelSection(named: "tun:"))
        #expect(!"  tun:\n    enable: true\n".hasTopLevelSection(named: "tun:"))
        #expect(!"mode: rule\n".hasTopLevelSection(named: "tun:"))
    }

    @Test("hasTopLevelPortKey detects each port style")
    func portKey() {
        #expect("mixed-port: 7890\n".hasTopLevelPortKey())
        #expect("port: 7890\n".hasTopLevelPortKey())
        #expect("socks-port: 7891\n".hasTopLevelPortKey())
        #expect(!"mode: rule\n".hasTopLevelPortKey())
        #expect(!"providers:\n  port: 1\n".hasTopLevelPortKey())
    }
}
