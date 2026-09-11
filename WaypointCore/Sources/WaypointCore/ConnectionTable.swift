//
//  ConnectionTable.swift
//  WaypointCore
//  Connection-row state machine behind the connections view: merges the
//  streamed snapshots into a stable row list and derives per-frame speeds.
//

import Foundation

/// One connection as shown in the connections view. `upload`/`download` are
/// the cumulative byte counters the core reports for the connection's life;
/// `uploadSpeed`/`downloadSpeed` are the deltas `ConnectionTable` computes
/// between two frames.
public struct ConnectionRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let host: String
    public let chains: [String]
    public let rule: String
    public let rulePayload: String
    public let network: String
    public let type: String
    public let source: String
    public let destinationIP: String
    public let processName: String?
    public let start: Date
    public var upload: Int
    public var download: Int
    public var uploadSpeed: Int
    public var downloadSpeed: Int

    public var displayChains: String { chains.joined(separator: " → ") }

    public init(id: String,
                host: String,
                chains: [String],
                rule: String,
                rulePayload: String,
                network: String,
                type: String,
                source: String,
                destinationIP: String,
                processName: String?,
                start: Date,
                upload: Int,
                download: Int,
                uploadSpeed: Int = 0,
                downloadSpeed: Int = 0) {
        self.id = id
        self.host = host
        self.chains = chains
        self.rule = rule
        self.rulePayload = rulePayload
        self.network = network
        self.type = type
        self.source = source
        self.destinationIP = destinationIP
        self.processName = processName
        self.start = start
        self.upload = upload
        self.download = download
        self.uploadSpeed = uploadSpeed
        self.downloadSpeed = downloadSpeed
    }
}

/// Merges the connection snapshots the core streams (about once per second).
/// A row that drops out of a frame is kept with its final totals, so the list
/// still shows what a finished connection transferred, but it reports zero
/// speed and is no longer active. Finished rows are kept newest-first up to
/// `maxFinishedRows`; older ones are dropped so a long-running session does
/// not grow the list without bound.
public struct ConnectionTable: Sendable {
    public private(set) var activeIDs = Set<String>()
    private var rowsByID = [String: ConnectionRow]()
    /// How many finished rows to retain. Only finished rows count toward the
    /// limit and only finished rows are evicted, oldest first, so live
    /// connections never disappear from under the user.
    private let maxFinishedRows: Int

    public init(maxFinishedRows: Int = 1_000) {
        self.maxFinishedRows = max(0, maxFinishedRows)
    }

    /// Newest connection first; finished rows keep their original position.
    public var rows: [ConnectionRow] {
        rowsByID.values.sorted { $0.start > $1.start }
    }

    public mutating func merge(_ incoming: [ConnectionRow]) {
        var alive = Set<String>()
        alive.reserveCapacity(incoming.count)
        for var row in incoming {
            if let previous = rowsByID[row.id] {
                row.uploadSpeed = row.upload - previous.upload
                row.downloadSpeed = row.download - previous.download
            } else {
                row.uploadSpeed = 0
                row.downloadSpeed = 0
            }
            alive.insert(row.id)
            rowsByID[row.id] = row
        }
        let finished = rowsByID.keys.filter { !alive.contains($0) }
        for id in finished {
            rowsByID[id]?.uploadSpeed = 0
            rowsByID[id]?.downloadSpeed = 0
        }
        let overflow = finished.count - maxFinishedRows
        if overflow > 0 {
            let oldestFirst = finished.sorted {
                (rowsByID[$0]?.start ?? .distantPast) < (rowsByID[$1]?.start ?? .distantPast)
            }
            for id in oldestFirst.prefix(overflow) {
                rowsByID[id] = nil
            }
        }
        activeIDs = alive
    }

    public mutating func remove(_ id: String) {
        rowsByID[id] = nil
    }

    /// Drops the rows the latest frame reported as active (Close All); rows
    /// that already finished stay listed.
    public mutating func removeActive() {
        for id in activeIDs {
            rowsByID[id] = nil
        }
        activeIDs = []
    }

    /// Applies the connections-view toolbar: the active-only toggle and the
    /// free-text filter over host, chain, rule and process name.
    public static func filtered(_ rows: [ConnectionRow],
                                activeOnly: Bool,
                                activeIDs: Set<String>,
                                searchText: String) -> [ConnectionRow] {
        let query = searchText.lowercased()
        return rows.filter { row in
            if activeOnly, !activeIDs.contains(row.id) { return false }
            if query.isEmpty { return true }
            return row.host.lowercased().contains(query)
                || row.displayChains.lowercased().contains(query)
                || row.rule.lowercased().contains(query)
                || (row.processName?.lowercased().contains(query) ?? false)
        }
    }
}
