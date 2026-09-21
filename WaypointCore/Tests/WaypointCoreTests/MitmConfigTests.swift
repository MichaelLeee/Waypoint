//
//  MitmConfigTests.swift
//  WaypointCoreTests
//

import Testing
@testable import WaypointCore

@Suite("MITM config injection")
struct MitmConfigTests {

    // Rewrite-rule hosts are persisted free text and are emitted into a
    // comma-delimited rule list, so a comma injects a policy — which makes
    // mihomo reject the whole generated config and takes the core down.
    @Test("A host pattern carrying a comma is dropped, not injected")
    func commaInjectionRejected() {
        #expect(MitmConfig.domainRules(fromHostPatterns: ["a.com,DIRECT"]).isEmpty)
        #expect(MitmConfig.domainRules(fromHostPatterns: ["ok.example.com", "a.com,DIRECT"])
            == ["DOMAIN,ok.example.com,waypoint-mitm"])
    }

    @Test("A host pattern carrying a newline is dropped, not injected")
    func newlineInjectionRejected() {
        #expect(MitmConfig.domainRules(fromHostPatterns: ["a.com\n  - MATCH,REJECT"]).isEmpty)
    }

    @Test("Suffix and wildcard forms each expand to a domain and a suffix rule")
    func suffixForms() {
        let expected = ["DOMAIN,example.com,waypoint-mitm", "DOMAIN-SUFFIX,example.com,waypoint-mitm"]
        #expect(MitmConfig.domainRules(fromHostPatterns: [".example.com"]) == expected)
        #expect(MitmConfig.domainRules(fromHostPatterns: ["*.example.com"]) == expected)
        #expect(MitmConfig.domainRules(fromHostPatterns: ["a.example.com"])
            == ["DOMAIN,a.example.com,waypoint-mitm"])
    }

    @Test("Hosts are normalized and deduplicated")
    func normalization() {
        #expect(MitmConfig.domainRules(fromHostPatterns: ["  A.Example.COM  ", "a.example.com"])
            == ["DOMAIN,a.example.com,waypoint-mitm"])
        #expect(MitmConfig.domainRules(fromHostPatterns: ["", "   "]).isEmpty)
    }
}
