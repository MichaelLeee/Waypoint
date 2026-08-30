//
//  Notification.swift
//  Waypoint
//
import Foundation

extension Notification.Name {
    static let configFileChange = Notification.Name("kConfigFileChange")
    static let reloadDashboard = Notification.Name("kReloadDashboard")
    static let systemNetworkStatusIPUpdate = Notification.Name("systemNetworkStatusIPUpdate")
    static let systemNetworkStatusDidChange = Notification.Name("kSystemNetworkStatusDidChange")
    static let proxyMeneViewShowLeftPadding = Notification.Name("kProxyMeneViewShowLeftPadding")
}
