//
//  RewriteSettingsView.swift
//  Waypoint
//

import SwiftUI

struct RewriteSettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $store.mitmEnabled) {
                    VStack(alignment: .leading) {
                        Text(NSLocalizedString("MITM & Rewrite", comment: ""))
                        Text(NSLocalizedString(
                            "Intercepts matching hosts through a local certificate and rewrites HTTP headers.",
                            comment: ""
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(NSLocalizedString("Install Trusted Certificate", comment: "")) {
                        store.installMitmCertificate()
                    }
                    Button(NSLocalizedString("Export Certificate…", comment: "")) {
                        store.exportMitmCertificate()
                    }
                }
                if let note = store.mitmCertificateNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(NSLocalizedString("Interception", comment: ""))
            } footer: {
                Text(NSLocalizedString(
                    "The generated root certificate is kept in your keychain; trust it once to make interception work in browsers. Rewrites apply to request and response headers of HTTP/1.1 traffic.",
                    comment: ""
                ))
            }

            Section {
                ForEach(store.rewriteRules.indices, id: \.self) { index in
                    ruleRow(index: index)
                }
                Button(NSLocalizedString("Add Rule", comment: "")) {
                    store.addRewriteRule()
                }
                .disabled(store.rewriteRules.contains { $0.host.isEmpty })
            } header: {
                Text(NSLocalizedString("Rewrite Rules", comment: ""))
            } footer: {
                Text(NSLocalizedString(
                    "Hosts accept exact (api.example.com) or suffix (.example.com) forms. Reject drops connections before any data is sent. Header rules replace the named header; an empty value removes it from responses. Changes reload the running core automatically.",
                    comment: ""
                ))
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func ruleRow(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: ruleBinding(index, keyPath: \.kind)) {
                    ForEach(RewriteRule.Kind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()

                Spacer()

                Button(NSLocalizedString("Delete", comment: ""), role: .destructive) {
                    store.deleteRewriteRule(at: IndexSet(integer: index))
                }
                .buttonStyle(.link)
            }

            TextField(NSLocalizedString("Host (e.g. api.example.com or .example.com)", comment: ""),
                      text: textBinding(index, keyPath: \.host))
                .textFieldStyle(.roundedBorder)

            if store.rewriteRules.indices.contains(index),
               store.rewriteRules[index].kind != .reject {
                TextField(NSLocalizedString("Header Name", comment: ""),
                          text: textBinding(index, keyPath: \.headerKey))
                    .textFieldStyle(.roundedBorder)
                TextField(
                    store.rewriteRules[index].kind == .responseHeader
                        ? NSLocalizedString("Header Value (empty removes it)", comment: "")
                        : NSLocalizedString("Header Value", comment: ""),
                    text: textBinding(index, keyPath: \.headerValue)
                )
                .textFieldStyle(.roundedBorder)
            }
        }
        .padding(.vertical, 2)
    }

    private func ruleBinding(_ index: Int, keyPath: WritableKeyPath<RewriteRule, RewriteRule.Kind>) -> Binding<RewriteRule.Kind> {
        Binding(
            get: { store.rewriteRules[index][keyPath: keyPath] },
            set: { newValue in
                store.updateRewriteRule(at: index) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func textBinding(_ index: Int, keyPath: WritableKeyPath<RewriteRule, String>) -> Binding<String> {
        Binding(
            get: { store.rewriteRules.indices.contains(index) ? store.rewriteRules[index][keyPath: keyPath] : "" },
            set: { newValue in
                guard store.rewriteRules.indices.contains(index) else { return }
                store.updateRewriteRule(at: index) { $0[keyPath: keyPath] = newValue }
            }
        )
    }
}
