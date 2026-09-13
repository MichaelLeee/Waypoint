//
//  KillSwitchManagerTests.swift
//  WaypointTests
//

import Foundation
import Testing
@testable import Waypoint

// The manager is main-actor isolated, and its reply box resumes the
// continuation from whichever callback lands first; the fake calls back
// synchronously, so each of these resolves deterministically.
@MainActor
@Suite("Kill switch manager", .serialized)
struct KillSwitchManagerTests {

    @Test("With no helper installed, installing the anchor reports it")
    func applyWithoutHelper() async {
        let manager = KillSwitchManager()
        manager.helperProvider = { _ in nil }

        let result = await manager.applyNow()

        #expect(result == "proxy helper unavailable")
    }

    @Test("A connection failure reported before the reply wins")
    func applyProviderFailureWins() async {
        let manager = KillSwitchManager()
        manager.helperProvider = { failure in
            failure?("connection invalidated")
            return nil
        }

        let result = await manager.applyNow()

        #expect(result == "proxy helper unavailable: connection invalidated")
    }

    @Test("Installing the anchor passes the composed rules to the helper")
    func applyPassesComposedRules() async {
        let fake = FakeProxyHelper()
        let manager = KillSwitchManager()
        manager.helperProvider = { _ in fake }
        let expected = KillSwitchManager.buildRules()

        let result = await manager.applyNow()

        #expect(result == nil)
        #expect(fake.callNames == ["setFirewallKillSwitch"])
        #expect(fake.killSwitchRules == expected)
    }

    @Test("An error installing the anchor is surfaced to the caller")
    func applySurfacesHelperError() async {
        let fake = FakeProxyHelper()
        fake.killSwitchErrorMessage = "pfctl: /dev/pf: Permission denied"
        let manager = KillSwitchManager()
        manager.helperProvider = { _ in fake }

        let result = await manager.applyNow()

        #expect(result == "pfctl: /dev/pf: Permission denied")
    }

    @Test("Clearing the anchor delegates to the helper")
    func clearDelegates() async {
        let fake = FakeProxyHelper()
        let manager = KillSwitchManager()
        manager.helperProvider = { _ in fake }

        let result = await manager.clear()

        #expect(result == nil)
        #expect(fake.callNames == ["clearFirewallKillSwitch"])
        #expect(fake.clearCount == 1)
    }

    @Test("With no helper installed, clearing the anchor reports it")
    func clearWithoutHelper() async {
        let manager = KillSwitchManager()
        manager.helperProvider = { _ in nil }

        let result = await manager.clear()

        #expect(result == "proxy helper unavailable")
    }
}
