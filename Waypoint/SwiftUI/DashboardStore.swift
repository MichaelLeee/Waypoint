//
//  DashboardStore.swift
//  Waypoint
//

import Observation
import Foundation
import WaypointCore
import WaypointNetworking

@MainActor
@Observable
final class DashboardStore {
    private(set) var upSpeed = 0
    private(set) var downSpeed = 0
    private(set) var memoryUsed = 0
    private(set) var memoryLimit = 0
    private(set) var activeConnections = 0
    private(set) var uploadTotal = 0
    private(set) var downloadTotal = 0
    private(set) var samples = [SpeedSample]()

    private static let sampleLimit = 120
    private var series = SpeedSampleSeries(limit: DashboardStore.sampleLimit)

    // nonisolated so deinit can cancel the tasks: Task is Sendable, and deinit
    // has exclusive access to the instance, so no concurrent mutation is possible.
    private nonisolated var tasks = [Task<Void, Never>]()

    init() {
        let api = ApiClient.shared
        tasks.append(Task { [weak self] in
            for await traffic in await api.trafficStream() {
                self?.apply(traffic: traffic)
            }
        })
        tasks.append(Task { [weak self] in
            for await memory in await api.memoryStream() {
                self?.memoryUsed = memory.inuse
                self?.memoryLimit = memory.osLimit ?? 0
            }
        })
        tasks.append(Task { [weak self] in
            for await snapshot in await api.connectionsStream() {
                self?.apply(connections: snapshot)
            }
        })
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    private func apply(traffic: TrafficSnapshot) {
        upSpeed = traffic.up
        downSpeed = traffic.down
        series.append(up: traffic.up, down: traffic.down, at: Date())
        samples = series.samples
    }

    private func apply(connections snapshot: ConnectionsSnapshot) {
        activeConnections = snapshot.connections.count
        uploadTotal = snapshot.uploadTotal
        downloadTotal = snapshot.downloadTotal
    }
}
