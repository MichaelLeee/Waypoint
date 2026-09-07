//
//  SystemProxyMatch.swift
//  WaypointCore
//  Pure port comparison deciding whether the system proxy settings point at
//  the running core.
//

public enum SystemProxyMatch {
    /// `http`/`https`/`socks` are the observed system proxy ports,
    /// `expectedHttpPort`/`expectedSocksPort` the core's inbound ports.
    /// Strict mode requires all three to match (the system is fully ours);
    /// `looser` matches when any one does (a hint that cleanup may be needed
    /// even if another app now owns part of the settings). A core reporting
    /// zero ports never matches — nothing was applied.
    public static func isSetToWaypoint(
        http: Int, https: Int, socks: Int,
        expectedHttpPort: Int, expectedSocksPort: Int,
        looser: Bool
    ) -> Bool {
        if expectedHttpPort == expectedSocksPort, expectedHttpPort == 0 {
            return false
        }
        if looser {
            return http == expectedHttpPort || https == expectedHttpPort || socks == expectedSocksPort
        } else {
            return http == expectedHttpPort && https == expectedHttpPort && socks == expectedSocksPort
        }
    }
}
