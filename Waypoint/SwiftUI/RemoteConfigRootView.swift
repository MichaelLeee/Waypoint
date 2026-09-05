//
//  RemoteConfigRootView.swift
//  Waypoint
//  Replaces the storyboard RemoteConfigViewController scene.
//

import SwiftUI

@MainActor
@Observable
final class RemoteConfigStore {
    var rows: [RemoteConfigRow] = []
    var selectionID: ObjectIdentifier?
    var addContext: RemoteConfigAddContext?
    var showAlert = false
    var alertMessage = ""

    private var latestAdded: RemoteConfigModel?
    // The notifications async sequence only re-evaluates `guard let self`
    // when the next notification arrives, so the store must cancel the task
    // on deinit or the suspended loop pins the observer forever.
    // nonisolated(unsafe): deinit is nonisolated, and cancelling a Task
    // reference there is safe.
    private nonisolated(unsafe) var observerTask: Task<Void, Never>?

    var selectedModel: RemoteConfigModel? {
        rows.first { $0.id == selectionID }?.model
    }

    init() {
        reload()
        observerTask = Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: Notification.Name("didGetUrl")) {
                guard let self, !Task.isCancelled else { break }
                guard let url = note.userInfo?["url"] as? String else { continue }
                self.showAdd(defaultUrl: url,
                             defaultName: nil,
                             name: note.userInfo?["name"] as? String,
                             allowAlt: true)
            }
        }
    }

    deinit {
        observerTask?.cancel()
    }

    func reload() {
        rows = RemoteConfigManager.shared.configs.map { RemoteConfigRow(model: $0) }
    }

    func showAdd(defaultUrl: String? = nil,
                 defaultName: String? = nil,
                 name: String? = nil,
                 allowAlt: Bool = false) {
        addContext = RemoteConfigAddContext(defaultUrl: defaultUrl,
                                            defaultName: defaultName,
                                            name: name,
                                            allowAlt: allowAlt)
    }

    func edit(_ model: RemoteConfigModel) {
        if model.isPlaceHolderName {
            showAdd(defaultUrl: model.url, defaultName: model.name, name: nil, allowAlt: true)
        } else {
            showAdd(defaultUrl: model.url, defaultName: nil, name: model.name, allowAlt: true)
        }
    }

    func submit(url: String, nameInput: String, context: RemoteConfigAddContext) {
        let urlString = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard urlString.isUrlVaild() else {
            alertMessage = NSLocalizedString("Invalid input", comment: "")
            showAlert = true
            return
        }
        let isUserInput = !nameInput.isEmpty
        let configName: String
        if isUserInput {
            configName = nameInput
        } else if let defaultName = context.defaultName, !defaultName.isEmpty {
            configName = defaultName
        } else {
            configName = URL(string: urlString)?.host ?? "unknown"
        }

        if let existed = RemoteConfigManager.shared.configs.first(where: { $0.name == configName }) {
            guard context.allowAlt else {
                alertMessage = NSLocalizedString("The remote config name is duplicated", comment: "")
                showAlert = true
                return
            }
            existed.url = urlString
            latestAdded = existed
            requestUpdate(config: existed)
        } else {
            let model = RemoteConfigModel(url: urlString, name: configName)
            model.isPlaceHolderName = !isUserInput
            RemoteConfigManager.shared.configs.append(model)
            latestAdded = model
            requestUpdate(config: model)
        }
        reload()
    }

    func updateSelected() {
        guard let model = selectedModel else { return }
        requestUpdate(config: model)
    }

    func deleteSelected() {
        guard let index = RemoteConfigManager.shared.configs.firstIndex(where: {
            ObjectIdentifier($0) == selectionID
        }) else { return }
        RemoteConfigManager.shared.configs.safeRemove(at: index)
        selectionID = nil
        reload()
    }

    func requestUpdate(config: RemoteConfigModel) {
        guard !config.updating else { return }
        config.updating = true
        reload()
        Task { [weak self] in
            let errorString = await RemoteConfigManager.updateConfig(config: config)
            guard let self else { return }
            config.updating = false
            if let errorString {
                self.alertMessage = errorString
                self.showAlert = true
            } else {
                config.updateTime = Date()
                RemoteConfigManager.shared.saveConfigs()

                if config == self.latestAdded {
                    AppDelegate.shared.updateConfig(configName: config.name)
                } else if config.name == ConfigManager.selectConfigName {
                    AppDelegate.shared.updateConfig()
                }
            }
            self.reload()
        }
    }
}

struct RemoteConfigRow: Identifiable {
    let id: ObjectIdentifier
    let model: RemoteConfigModel

    init(model: RemoteConfigModel) {
        id = ObjectIdentifier(model)
        self.model = model
    }

    var name: String { model.name }
    var url: String { model.url }
    var time: String { model.displayingTimeString() }
}

struct RemoteConfigAddContext: Identifiable {
    let id = UUID()
    let defaultUrl: String?
    let defaultName: String?
    let name: String?
    let allowAlt: Bool
}

struct RemoteConfigRootView: View {
    @State private var store = RemoteConfigStore()

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack {
                Text("Name").frame(width: 110, alignment: .leading)
                Text("URL").frame(maxWidth: .infinity, alignment: .leading)
                Text("Update Time").frame(width: 90, alignment: .leading)
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
                        Text(row.time)
                            .frame(width: 90, alignment: .leading)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { store.edit(row.model) }
                }
            }
            .listStyle(.plain)

            Divider()

            HStack {
                Spacer()
                Button(NSLocalizedString("Add", comment: "")) {
                    store.showAdd()
                }
                .keyboardShortcut(.defaultAction)
                Button(NSLocalizedString("Update", comment: "")) {
                    store.updateSelected()
                }
                .disabled(store.selectedModel == nil || store.selectedModel?.updating == true)
                Button(NSLocalizedString("Delete", comment: "")) {
                    store.deleteSelected()
                }
                .disabled(store.selectedModel == nil)
            }
            .padding(12)
        }
        .frame(minWidth: 460, minHeight: 260)
        .onAppear { store.reload() }
        .onDisappear { RemoteConfigManager.shared.saveConfigs() }
        .sheet(item: $store.addContext) { context in
            RemoteConfigAddSheet(store: store, context: context)
        }
        .alert(store.alertMessage, isPresented: $store.showAlert) {
            Button(NSLocalizedString("OK", comment: ""), role: .cancel) {}
        }
    }
}

struct RemoteConfigAddSheet: View {
    @Bindable var store: RemoteConfigStore
    let context: RemoteConfigAddContext

    @State private var urlText: String
    @State private var nameText: String
    @Environment(\.dismiss) private var dismiss

    init(store: RemoteConfigStore, context: RemoteConfigAddContext) {
        self.store = store
        self.context = context
        _urlText = State(initialValue: context.defaultUrl ?? "")
        _nameText = State(initialValue: context.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Add a remote config", comment: ""))
                .font(.headline)
            TextField(NSLocalizedString("URL", comment: ""), text: $urlText)
            TextField(namePlaceholder, text: $nameText)
            HStack {
                Spacer()
                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {
                    dismiss()
                }
                Button(NSLocalizedString("OK", comment: "")) {
                    store.submit(url: urlText, nameInput: nameText, context: context)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var namePlaceholder: String {
        if let defaultName = context.defaultName, !defaultName.isEmpty {
            return defaultName
        }
        return URL(string: urlText)?.host ?? NSLocalizedString("Name", comment: "")
    }
}

#Preview("Remote Config") {
    RemoteConfigRootView()
        .frame(width: 480, height: 320)
}
