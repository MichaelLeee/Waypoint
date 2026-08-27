//
//  Notification.swift
//  Waypoint
//
import Foundation

extension Notification.Name {
    static let configFileChange = Notification.Name("kConfigFileChange")
    static let speedTestFinishForProxy = Notification.Name("kSpeedTestFinishForProxy")
    static let reloadDashboard = Notification.Name("kReloadDashboard")
    static let systemNetworkStatusIPUpdate = Notification.Name("systemNetworkStatusIPUpdate")
    static let systemNetworkStatusDidChange = Notification.Name("kSystemNetworkStatusDidChange")
    static let proxyMeneViewShowLeftPadding = Notification.Name("kProxyMeneViewShowLeftPadding")

    static func proxyUpdate(for name: WaypointProxyName) -> Notification.Name {
        return Notification.Name("kProxyUpdate_\(name)")
    }
}
