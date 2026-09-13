//
//  FakeProxyHelper.swift
//  WaypointTests
//

import Foundation
@testable import Waypoint

/// Stands in for the privileged helper's XPC connection. Every call is recorded
/// and every reply is delivered synchronously, so the managers' guard-and-delegate
/// paths can be asserted without a helper installed.
final class FakeProxyHelper: PrivilegedProxyHelper {
    private(set) var callNames: [String] = []

    /// Answer for getCurrentProxySetting.
    var proxySetting: [String: Any]?

    // enableProxy
    var enabledPort: Int?
    var enabledSocksPort: Int?
    var enabledFilterInterface: Bool?
    var enabledIgnoreList: [String]?
    var enableErrorMessage: String?

    // disableProxy
    var disabledFilterInterface: Bool?
    var disableErrorMessage: String?

    // restoreProxy
    var restoredPort: Int?
    var restoredSocksPort: Int?
    var restoredInfo: [String: Any]?
    var restoredFilterInterface: Bool?
    var restoreErrorMessage: String?

    // kill switch
    var killSwitchRules: String?
    var killSwitchErrorMessage: String?
    var clearCount = 0

    func getCurrentProxySetting(reply: @escaping ([String: Any]?) -> Void) {
        callNames.append("getCurrentProxySetting")
        reply(proxySetting)
    }

    func enableProxy(port: Int,
                     socksPort: Int,
                     filterInterface: Bool,
                     ignoreList: [String],
                     error: @escaping (String?) -> Void) {
        callNames.append("enableProxy")
        enabledPort = port
        enabledSocksPort = socksPort
        enabledFilterInterface = filterInterface
        enabledIgnoreList = ignoreList
        error(enableErrorMessage)
    }

    func disableProxy(filterInterface: Bool, reply: @escaping (String?) -> Void) {
        callNames.append("disableProxy")
        disabledFilterInterface = filterInterface
        reply(disableErrorMessage)
    }

    func restoreProxy(port: Int,
                      socksPort: Int,
                      info: [String: Any],
                      filterInterface: Bool,
                      error: @escaping (String?) -> Void) {
        callNames.append("restoreProxy")
        restoredPort = port
        restoredSocksPort = socksPort
        restoredInfo = info
        restoredFilterInterface = filterInterface
        error(restoreErrorMessage)
    }

    func setFirewallKillSwitch(rules: String, reply: @escaping (String?) -> Void) {
        callNames.append("setFirewallKillSwitch")
        killSwitchRules = rules
        reply(killSwitchErrorMessage)
    }

    func clearFirewallKillSwitch(reply: @escaping (String?) -> Void) {
        callNames.append("clearFirewallKillSwitch")
        clearCount += 1
        reply(killSwitchErrorMessage)
    }
}
