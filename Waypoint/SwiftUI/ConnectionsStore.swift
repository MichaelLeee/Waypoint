//
//  ConnectionsStore.swift
//  Waypoint
//

import Observation
import Foundation
import WaypointCore
import WaypointNetworking

extension ConnectionRow {
    /// Relative age label for the table's Duration column. Kept app-side
    /// because NSLocalizedString resolves against the app bundle, not the
    /// package's.
    var startDisplay: String {
        let interval = Date().timeIntervalSince(start)
        if interval < 60 {
            return NSLocalizedString("just now", comment: "")
        }
        return ((Self.durationFormatter.string(from: interval) ?? "") + " "
            + NSLocalizedString("ago", comment: ""))
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 1
        return formatter
    }()
}

@MainActor
@Observable
final class ConnectionsStore {
    private(set) var rows = [ConnectionRow]()
    private(set) var uploadTotal = 0
    private(set) var downloadTotal = 0
    var activeOnly = false
    var searchText = ""

    private var table = ConnectionTable()
    private var activeIDs = Set<String>()
    // nonisolated(unsafe) so deinit can cancel it: Task is Sendable, and it is
    // only touched from init and deinit, both on the main actor. Plain
    // `nonisolated` cannot be applied to a mutable stored property, and the
    // handle is not view state, so observation is skipped.
    @ObservationIgnored private nonisolated(unsafe) var streamTask: Task<Void, Never>?

    init() {
        streamTask = Task { [weak self] in
            for await snapshot in await ApiClient.shared.connectionsStream() {
                self?.apply(snapshot: snapshot)
            }
        }
    }

    deinit {
        // The stream auto-reconnects forever; without cancelling, a closed
        // window's store keeps a live WebSocket and a mutating closure.
        streamTask?.cancel()
    }

    var filteredRows: [ConnectionRow] {
        ConnectionTable.filtered(rows,
                                 activeOnly: activeOnly,
                                 activeIDs: activeIDs,
                                 searchText: searchText)
    }

    func close(_ id: String) async {
        await ApiClient.shared.closeConnection(id)
        table.remove(id)
        publishRows()
    }

    func closeAll() async {
        await ApiClient.shared.closeAllConnection()
        table.removeActive()
        publishRows()
    }

    private func apply(snapshot: ConnectionsSnapshot) {
        uploadTotal = snapshot.uploadTotal
        downloadTotal = snapshot.downloadTotal
        table.merge(snapshot.connections.map { conn in
            ConnectionRow(id: conn.id,
                          host: conn.displayHost,
                          chains: conn.chains,
                          rule: conn.rule,
                          rulePayload: conn.rulePayload,
                          network: conn.network,
                          type: conn.type,
                          source: "\(conn.sourceIP):\(conn.sourcePort)",
                          destinationIP: conn.destinationIP,
                          processName: conn.displayName,
                          start: conn.start,
                          upload: conn.upload,
                          download: conn.download)
        })
        publishRows()
    }

    private func publishRows() {
        activeIDs = table.activeIDs
        rows = table.rows
    }
}
