//
//  SpeedSampleSeries.swift
//  WaypointCore
//  Rolling window of traffic samples behind the dashboard chart.
//

import Foundation

public struct SpeedSample: Identifiable, Sendable, Equatable {
    public let id: Int
    public let date: Date
    public let up: Int
    public let down: Int

    public init(id: Int, date: Date, up: Int, down: Int) {
        self.id = id
        self.date = date
        self.up = up
        self.down = down
    }
}

/// Keeps the most recent `limit` samples. Ids keep counting up while old
/// samples drop off the front, so a sample keeps its chart identity for as
/// long as it is visible.
public struct SpeedSampleSeries: Sendable {
    public let limit: Int
    public private(set) var samples = [SpeedSample]()

    public init(limit: Int) {
        self.limit = limit
    }

    public mutating func append(up: Int, down: Int, at date: Date) {
        samples.append(SpeedSample(id: (samples.last?.id ?? 0) + 1, date: date, up: up, down: down))
        if samples.count > limit {
            samples.removeFirst(samples.count - limit)
        }
    }
}
