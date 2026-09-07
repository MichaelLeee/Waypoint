//
//  ConnectionManager.swift
//  Waypoint
//

import WaypointNetworking
import Cocoa

enum ConnectionManager {
    static func closeConnection(for group: String) {
        Task {
            let conns = await ApiClient.shared.getConnections()
            for conn in conns where conn.chains.contains(group) {
                await ApiClient.shared.closeConnection(conn.id)
            }
        }
    }

    static func closeAllConnection() {
        Task { await ApiClient.shared.closeAllConnection() }
    }
}
