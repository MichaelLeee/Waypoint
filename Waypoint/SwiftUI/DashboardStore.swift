//
//  DashboardStore.swift
//  Waypoint
//

import Observation
import Foundation
import WaypointNetworking

struct SpeedSample: Identifiable {
    let id: Int
    let date: Date
    let up: Int
    let down: Int
}

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

    static let sampleLimit = 120

    // nonisolated(unsafe) so deinit can cancel the tasks: deinit has
    // exclusive access to the instance, so no concurrent mutation is possible.
    private nonisolated(unsafe) var tasks = [Task<Void, Never>]()

    init() {
        let api = ApiRequest.client
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
        let sample = SpeedSample(
            id: (samples.last?.id ?? 0) + 1,
            date: Date(),
            up: traffic.up,
            down: traffic.down
        )
        samples.append(sample)
        if samples.count > Self.sampleLimit {
            samples.removeFirst(samples.count - Self.sampleLimit)
        }
    }

    private func apply(connections snapshot: ConnectionsSnapshot) {
        activeConnections = snapshot.connections.count
        uploadTotal = snapshot.uploadTotal
        downloadTotal = snapshot.downloadTotal
    }
}
