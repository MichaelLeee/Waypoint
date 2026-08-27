//
//  DashboardStore.swift
//  Waypoint
//

import Foundation

struct SpeedSample: Identifiable {
    let id: Int
    let date: Date
    let up: Int
    let down: Int
}

@MainActor
final class DashboardStore: ObservableObject {
    @Published private(set) var upSpeed = 0
    @Published private(set) var downSpeed = 0
    @Published private(set) var memoryUsed = 0
    @Published private(set) var memoryLimit = 0
    @Published private(set) var activeConnections = 0
    @Published private(set) var uploadTotal = 0
    @Published private(set) var downloadTotal = 0
    @Published private(set) var samples = [SpeedSample]()

    static let sampleLimit = 120

    private var tasks = [Task<Void, Never>]()

    init() {
        let api = ApiRequest.shared
        tasks.append(Task { [weak self] in
            for await traffic in api.trafficStream() {
                self?.apply(traffic: traffic)
            }
        })
        tasks.append(Task { [weak self] in
            for await memory in api.memoryStream() {
                self?.memoryUsed = memory.inuse
                self?.memoryLimit = memory.osLimit ?? 0
            }
        })
        tasks.append(Task { [weak self] in
            for await snapshot in api.connectionsStream() {
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
