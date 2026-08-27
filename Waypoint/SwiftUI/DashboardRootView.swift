//
//  DashboardRootView.swift
//  Waypoint
//

import Charts
import SwiftUI

struct DashboardRootView: View {
    @StateObject private var store = DashboardStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 32) {
                SpeedBadge(
                    label: NSLocalizedString("Upload", comment: ""),
                    value: SpeedUtils.getSpeedString(for: store.upSpeed),
                    color: .green
                )
                SpeedBadge(
                    label: NSLocalizedString("Download", comment: ""),
                    value: SpeedUtils.getSpeedString(for: store.downSpeed),
                    color: .blue
                )
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Memory: \(SpeedUtils.getNetString(for: store.memoryUsed))")
                        .foregroundStyle(.secondary)
                    Text("Connections: \(store.activeConnections)")
                        .foregroundStyle(.secondary)
                }
            }

            chart
                .frame(maxHeight: .infinity)

            Divider()

            HStack(spacing: 24) {
                Label("\(SpeedUtils.getNetString(for: store.uploadTotal))", systemImage: "arrow.up.circle")
                    .foregroundStyle(.green)
                    .help(NSLocalizedString("Total uploaded", comment: ""))
                Label("\(SpeedUtils.getNetString(for: store.downloadTotal))", systemImage: "arrow.down.circle")
                    .foregroundStyle(.blue)
                    .help(NSLocalizedString("Total downloaded", comment: ""))
                Spacer()
            }
            .font(.callout.monospacedDigit())
        }
        .padding()
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private var chart: some View {
        if store.samples.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Waiting for traffic…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(store.samples) { sample in
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Speed", sample.up)
                    )
                    .foregroundStyle(Color.green)
                }
                ForEach(store.samples) { sample in
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Speed", sample.down)
                    )
                    .foregroundStyle(Color.blue)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let speed = value.as(Int.self) {
                            Text(SpeedUtils.getSpeedString(for: speed))
                        }
                    }
                }
            }
            .chartYAxisLabel(NSLocalizedString("Throughput (per second)", comment: ""))
        }
    }
}

private struct SpeedBadge: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}
