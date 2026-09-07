//
//  ApiURLDerivationTests.swift
//  WaypointNetworkingTests
//

import Foundation
import Testing
@testable import WaypointNetworking

struct ApiURLDerivationTests {
    @Test func defaultIsLocalPort() {
        #expect(WaypointApiURL.httpURL(overrideApiURL: nil, apiPort: "9090") == "http://127.0.0.1:9090")
        #expect(WaypointApiURL.webSocketURL(overrideApiURL: nil, apiPort: "9099") == "ws://127.0.0.1:9099")
    }

    @Test func httpOverrideUsedVerbatim() throws {
        let override = try #require(URL(string: "https://api.example.com:1234/base"))
        #expect(WaypointApiURL.httpURL(overrideApiURL: override, apiPort: "9090") == "https://api.example.com:1234/base")
    }

    @Test func webSocketSchemeRewrite() throws {
        let http = try #require(URL(string: "http://api.example.com:1234"))
        let https = try #require(URL(string: "https://api.example.com:1234/base"))
        #expect(WaypointApiURL.webSocketURL(overrideApiURL: http, apiPort: "9090") == "ws://api.example.com:1234")
        #expect(WaypointApiURL.webSocketURL(overrideApiURL: https, apiPort: "9090") == "wss://api.example.com:1234/base")
    }

    @Test func overrideWithoutSchemeIsStillRewrittenToWS() throws {
        // A scheme-less override keeps its path but is treated as ws, not
        // rejected — pinning the legacy behavior.
        let override = try #require(URL(string: "api.example.com:1234"))
        let result = WaypointApiURL.webSocketURL(overrideApiURL: override, apiPort: "9090")
        #expect(result.hasPrefix("ws:"))
        #expect(!result.contains("wss"))
    }
}
