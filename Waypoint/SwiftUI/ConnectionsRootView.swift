//
//  ConnectionsRootView.swift
//  Waypoint
//

import SwiftUI

struct ConnectionsRootView: View {
    @State private var store = ConnectionsStore()
    @State private var selection = Set<String>()

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            toolbar
            Divider()
            Table(store.filteredRows, selection: $selection) {
                TableColumn(NSLocalizedString("Host", comment: "")) { row in
                    VStack(alignment: .leading) {
                        Text(row.host)
                        Text(row.source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                TableColumn(NSLocalizedString("Rule", comment: "")) { row in
                    Text(row.rulePayload.isEmpty ? row.rule : "\(row.rule) (\(row.rulePayload))")
                }
                TableColumn(NSLocalizedString("Chains", comment: "")) { row in
                    Text(row.displayChains)
                }
                TableColumn(NSLocalizedString("Process", comment: "")) { row in
                    Text(row.processName ?? NSLocalizedString("Unknown", comment: ""))
                }
                TableColumn(NSLocalizedString("Duration", comment: "")) { row in
                    Text(row.startDisplay)
                }
                TableColumn(NSLocalizedString("Uplink", comment: "")) { row in
                    Text(SpeedUtils.getSpeedString(for: row.uploadSpeed))
                        .foregroundStyle(.green)
                }
                TableColumn(NSLocalizedString("Downlink", comment: "")) { row in
                    Text(SpeedUtils.getSpeedString(for: row.downloadSpeed))
                        .foregroundStyle(.blue)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first {
                    Button(String(format: NSLocalizedString("Close %@", comment: ""), id)) {
                        Task { await store.close(id) }
                    }
                } else {
                    Button(NSLocalizedString("Close All Connections", comment: "")) {
                        Task { await store.closeAll() }
                    }
                }
            } primaryAction: { _ in }

            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder private var toolbar: some View {
        @Bindable var store = store
        HStack(spacing: 12) {
            Toggle(
                NSLocalizedString("Active only", comment: ""),
                isOn: $store.activeOnly
            )
            .toggleStyle(.checkbox)

            TextField(
                NSLocalizedString("Filter host, rule, chain, process…", comment: ""),
                text: $store.searchText
            )
            .textFieldStyle(.roundedBorder)

            Spacer()

            Button(NSLocalizedString("Close All Connections", comment: "")) {
                Task { await store.closeAll() }
            }
            .disabled(store.rows.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 24) {
            Label("\(SpeedUtils.getSpeedString(for: store.uploadTotal))", systemImage: "arrow.up.circle")
                .foregroundStyle(.green)
                .help(NSLocalizedString("Total uploaded", comment: ""))
            Label("\(SpeedUtils.getNetString(for: store.downloadTotal))", systemImage: "arrow.down.circle")
                .foregroundStyle(.blue)
                .help(NSLocalizedString("Total downloaded", comment: ""))
            Spacer()
            Text(
                String(
                    format: NSLocalizedString("%d connections", comment: ""),
                    store.filteredRows.count
                )
            )
            .foregroundStyle(.secondary)
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}
