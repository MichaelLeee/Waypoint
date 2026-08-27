//
//  ConnectionsStore.swift
//  Waypoint
//

import Foundation

struct ConnectionRow: Identifiable {
    let id: String
    let host: String
    let chains: [String]
    let rule: String
    let rulePayload: String
    let network: String
    let type: String
    let source: String
    let destinationIP: String
    let processName: String?
    let start: Date
    var upload: Int = 0
    var download: Int = 0
    var uploadSpeed: Int = 0
    var downloadSpeed: Int = 0

    var displayChains: String { chains.joined(separator: " → ") }
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
final class ConnectionsStore: ObservableObject {
    @Published private(set) var rows = [ConnectionRow]()
    @Published private(set) var uploadTotal = 0
    @Published private(set) var downloadTotal = 0
    @Published var activeOnly = false
    @Published var searchText = ""

    private var activeIDs = Set<String>()
    private var rowsByID = [String: ConnectionRow]()

    init() {
        Task { [weak self] in
            for await snapshot in ApiRequest.shared.connectionsStream() {
                self?.apply(snapshot: snapshot)
            }
        }
    }

    var filteredRows: [ConnectionRow] {
        rows.filter { row in
            if activeOnly && !activeIDs.contains(row.id) { return false }
            if searchText.isEmpty { return true }
            let query = searchText.lowercased()
            return row.host.lowercased().contains(query)
                || row.displayChains.lowercased().contains(query)
                || row.rule.lowercased().contains(query)
                || (row.processName?.lowercased().contains(query) ?? false)
        }
    }

    func close(_ id: String) async {
        await ApiRequest.closeConnection(id)
        rowsByID[id] = nil
        publishRows()
    }

    func closeAll() async {
        await ApiRequest.closeAllConnection()
        for id in activeIDs {
            rowsByID[id] = nil
        }
        publishRows()
    }

    private func apply(snapshot: ConnectionsSnapshot) {
        uploadTotal = snapshot.uploadTotal
        downloadTotal = snapshot.downloadTotal
        activeIDs = Set(snapshot.connections.map(\.id))
        var seen = Set<String>()
        for conn in snapshot.connections {
            seen.insert(conn.id)
            if var row = rowsByID[conn.id] {
                row.uploadSpeed = conn.upload - row.upload
                row.downloadSpeed = conn.download - row.download
                row.upload = conn.upload
                row.download = conn.download
                rowsByID[conn.id] = row
            } else {
                rowsByID[conn.id] = ConnectionRow(
                    id: conn.id,
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
                    download: conn.download
                )
            }
        }
        for id in rowsByID.keys where !seen.contains(id) {
            rowsByID[id]?.uploadSpeed = 0
            rowsByID[id]?.downloadSpeed = 0
        }
        publishRows()
    }

    private func publishRows() {
        rows = rowsByID.values.sorted { $0.start > $1.start }
    }
}
