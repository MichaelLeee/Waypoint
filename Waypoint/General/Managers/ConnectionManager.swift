//
//  ConnectionManager.swift
//  Waypoint
//

import Cocoa

enum ConnectionManager {
    static func closeConnection(for group: String) {
        Task {
            let conns = await ApiRequest.getConnections()
            for conn in conns where conn.chains.contains(group) {
                await ApiRequest.closeConnection(conn.id)
            }
        }
    }

    static func closeAllConnection() {
        Task { await ApiRequest.closeAllConnection() }
    }
}
