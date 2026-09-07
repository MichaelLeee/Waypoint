//
//  SystemProxyMatchTests.swift
//  WaypointCoreTests
//

import Testing
@testable import WaypointCore

struct SystemProxyMatchTests {
    @Test func zeroExpectedPortsNeverMatches() {
        #expect(!SystemProxyMatch.isSetToWaypoint(
            http: 0, https: 0, socks: 0,
            expectedHttpPort: 0, expectedSocksPort: 0, looser: false))
        #expect(!SystemProxyMatch.isSetToWaypoint(
            http: 0, https: 0, socks: 0,
            expectedHttpPort: 0, expectedSocksPort: 0, looser: true))
    }

    @Test func strictRequiresAllThree() {
        #expect(SystemProxyMatch.isSetToWaypoint(
            http: 7890, https: 7890, socks: 7891,
            expectedHttpPort: 7890, expectedSocksPort: 7891, looser: false))
        // Any single port diverging breaks the strict match.
        #expect(!SystemProxyMatch.isSetToWaypoint(
            http: 7890, https: 7890, socks: 7891,
            expectedHttpPort: 7890, expectedSocksPort: 9999, looser: false))
        #expect(!SystemProxyMatch.isSetToWaypoint(
            http: 7890, https: 1111, socks: 7891,
            expectedHttpPort: 7890, expectedSocksPort: 7891, looser: false))
    }

    @Test func looserMatchesAnyOne() {
        #expect(SystemProxyMatch.isSetToWaypoint(
            http: 7890, https: 0, socks: 0,
            expectedHttpPort: 7890, expectedSocksPort: 7891, looser: true))
        #expect(SystemProxyMatch.isSetToWaypoint(
            http: 0, https: 0, socks: 7891,
            expectedHttpPort: 7890, expectedSocksPort: 7891, looser: true))
        #expect(SystemProxyMatch.isSetToWaypoint(
            http: 0, https: 7890, socks: 0,
            expectedHttpPort: 7890, expectedSocksPort: 7891, looser: true))
        #expect(!SystemProxyMatch.isSetToWaypoint(
            http: 0, https: 0, socks: 0,
            expectedHttpPort: 7890, expectedSocksPort: 7891, looser: true))
    }

    @Test func httpsAndSocksUseTheirOwnExpectations() {
        // https is compared against the HTTP port, socks against the SOCKS
        // port — not interchangeable.
        #expect(!SystemProxyMatch.isSetToWaypoint(
            http: 7890, https: 7891, socks: 7890,
            expectedHttpPort: 7890, expectedSocksPort: 7891, looser: false))
    }

    @Test func distinctHttpAndSocksZeroGuardOnlyWhenBothZero() {
        // Mixed zero/non-zero ports (e.g. socks-only config) still matches.
        #expect(SystemProxyMatch.isSetToWaypoint(
            http: 0, https: 0, socks: 7891,
            expectedHttpPort: 0, expectedSocksPort: 7891, looser: false))
    }
}
