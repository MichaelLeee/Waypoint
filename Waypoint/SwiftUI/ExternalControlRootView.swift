//
//  ExternalControlRootView.swift
//  Waypoint
//  Replaces the storyboard ExternalControlViewController scene.
//

import SwiftUI

@MainActor
final class ExternalControlStore: ObservableObject {
    @Published var rows: [ExternalControlRow] = []
    @Published var selectionID: ObjectIdentifier?
    @Published var isAdding = false
    @Published var showAlert = false
    @Published var alertMessage = ""

    var selectedRow: ExternalControlRow? {
        rows.first { $0.id == selectionID }
    }

    init() {
        reload()
    }

    func reload() {
        rows = RemoteControlManager.configs.map { ExternalControlRow(model: $0) }
    }

    func submit(url: String, name: String, secret: String) {
        let urlString = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard urlString.isUrlVaild(), !trimmedName.isEmpty else {
            alertMessage = NSLocalizedString("Invalid input", comment: "")
            showAlert = true
            return
        }
        RemoteControlManager.configs.append(
            RemoteControl(name: trimmedName, url: urlString, secret: secret)
        )
        reload()
    }

    func deleteSelected() {
        guard let index = RemoteControlManager.configs.firstIndex(where: {
            ObjectIdentifier($0) == selectionID
        }) else { return }
        RemoteControlManager.configs.safeRemove(at: index)
        selectionID = nil
        reload()
    }
}

struct ExternalControlRow: Identifiable {
    let id: ObjectIdentifier
    let model: RemoteControl

    init(model: RemoteControl) {
        id = ObjectIdentifier(model)
        self.model = model
    }

    var name: String { model.name }
    var url: String { model.url }
    var secret: String { model.secret }
}

struct ExternalControlRootView: View {
    @StateObject private var store = ExternalControlStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Name").frame(width: 110, alignment: .leading)
                Text("URL").frame(maxWidth: .infinity, alignment: .leading)
                Text("Secret").frame(width: 90, alignment: .leading)
            }
            .font(.callout.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 6)

            List(selection: $store.selectionID) {
                ForEach(store.rows) { row in
                    HStack {
                        Text(row.name).frame(width: 110, alignment: .leading)
                        Text(row.url)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.url)
                        Text(row.secret.isEmpty ? "-" : "••••")
                            .frame(width: 90, alignment: .leading)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
            }
            .listStyle(.plain)

            Divider()

            HStack {
                Spacer()
                Button(NSLocalizedString("Add", comment: "")) {
                    store.isAdding = true
                }
                .keyboardShortcut(.defaultAction)
                Button(NSLocalizedString("Delete", comment: "")) {
                    store.deleteSelected()
                }
                .disabled(store.selectedRow == nil)
            }
            .padding(12)
        }
        .frame(minWidth: 460, minHeight: 220)
        .onAppear { store.reload() }
        .sheet(isPresented: $store.isAdding) {
            ExternalControlAddSheet(store: store)
        }
        .alert(store.alertMessage, isPresented: $store.showAlert) {
            Button(NSLocalizedString("OK", comment: ""), role: .cancel) {}
        }
    }
}

struct ExternalControlAddSheet: View {
    @ObservedObject var store: ExternalControlStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var nameText = ""
    @State private var secretText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Add a remote controller", comment: ""))
                .font(.headline)
            TextField(NSLocalizedString("URL", comment: ""), text: $urlText)
            TextField(NSLocalizedString("Name", comment: ""), text: $nameText)
            SecureField(NSLocalizedString("Secret", comment: ""), text: $secretText)
            HStack {
                Spacer()
                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {
                    dismiss()
                }
                Button(NSLocalizedString("OK", comment: "")) {
                    store.submit(url: urlText, name: nameText, secret: secretText)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
