//
//  OnboardingRootView.swift
//  Waypoint
//

import AppKit
import ScreenCaptureKit
import SwiftUI
import Vision

@MainActor
@Observable
final class OnboardingStore {
    var urlText = ""
    var nameText = ""
    var importing = false
    var scanning = false
    var message: String?
    var messageIsError = false
    var configImported = false
    var systemProxyEnabled = ConfigManager.shared.proxyPortAutoSet

    func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            setMessage(NSLocalizedString("Clipboard is empty.", comment: ""), isError: true)
            return
        }
        urlText = text
        nameText = ""
        clearMessage()
    }

    func scanQRCode() async {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            setMessage(
                NSLocalizedString("Grant Screen Recording permission to read QR codes from the screen.", comment: ""),
                isError: true
            )
            return
        }
        scanning = true
        clearMessage()
        let captured = await captureMainDisplay().map { QRCodeReader.readURL(from: $0) }
        scanning = false
        switch captured {
        case .some(.some(let url)):
            urlText = url
            nameText = ""
        case .some(nil):
            setMessage(
                NSLocalizedString("No QR code found on screen. Open the QR code, then try again.", comment: ""),
                isError: true
            )
        case nil:
            setMessage(NSLocalizedString("Could not capture the screen.", comment: ""), isError: true)
        }
    }

    // CGDisplayCreateImage is unavailable in the macOS 26 SDK; ScreenCaptureKit
    // is the supported replacement.
    private func captureMainDisplay() async -> CGImage? {
        guard let display = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false))?
            .displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
            return nil
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.captureResolution = .best
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    func importSubscription() async {
        let urlString = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard urlString.isUrlVaild() else {
            setMessage(NSLocalizedString("Please enter a valid subscription URL.", comment: ""), isError: true)
            return
        }
        importing = true
        clearMessage()
        defer { importing = false }

        let trimmedName = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? URL(string: urlString)?.host ?? "unknown" : trimmedName
        let isPlaceholderName = trimmedName.isEmpty

        let manager = RemoteConfigManager.shared
        let model: RemoteConfigModel
        if let existed = manager.configs.first(where: { $0.name == name }) {
            existed.url = urlString
            model = existed
        } else {
            let newModel = RemoteConfigModel(url: urlString, name: name)
            newModel.isPlaceHolderName = isPlaceholderName
            manager.configs.append(newModel)
            model = newModel
        }

        let error = await RemoteConfigManager.updateConfig(config: model)
        if let error {
            setMessage(error, isError: true)
            return
        }
        model.updateTime = Date()
        model.isPlaceHolderName = false
        manager.saveConfigs()
        configImported = true
        setMessage(
            String(format: NSLocalizedString("Imported “%@” and switched to it.", comment: ""), model.name),
            isError: false
        )
        AppDelegate.shared.updateConfig(configName: model.name)
    }

    func enableSystemProxy() {
        ConfigManager.shared.proxyPortAutoSet = true
        SystemProxyManager.shared.saveProxy()
        SystemProxyManager.shared.enableProxy()
        systemProxyEnabled = true
    }

    func disableSystemProxy() {
        SystemProxyManager.shared.disableProxy()
        systemProxyEnabled = false
    }

    private func setMessage(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }

    private func clearMessage() {
        message = nil
    }
}

enum QRCodeReader {
    /// Captures nothing itself; extracts an importable URL from a screenshot.
    nonisolated static func readURL(from image: CGImage) -> String? {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let observations = request.results ?? []
        let payloads = observations.compactMap(\.payloadStringValue)
        return payloads.first(where: {
            $0.hasPrefix("https://") || $0.hasPrefix("http://") || $0.hasPrefix("waypoint://")
        })
    }
}

struct OnboardingRootView: View {
    @State private var store = OnboardingStore()

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 20) {
            header

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label(NSLocalizedString("Import a Subscription", comment: ""), systemImage: "square.and.arrow.down.on.square")
                        .font(.headline)

                    HStack(spacing: 8) {
                        TextField(
                            NSLocalizedString("https://your-provider/subscription", comment: ""),
                            text: $store.urlText
                        )
                        .textFieldStyle(.roundedBorder)

                        Button(NSLocalizedString("Paste", comment: "")) {
                            store.pasteFromClipboard()
                        }

                        Button {
                            Task { await store.scanQRCode() }
                        } label: {
                            if store.scanning {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label(NSLocalizedString("Scan QR", comment: ""), systemImage: "qrcode.viewfinder")
                            }
                        }
                        .disabled(store.scanning)
                    }

                    TextField(
                        NSLocalizedString("Name (optional)", comment: ""),
                        text: $store.nameText
                    )
                    .textFieldStyle(.roundedBorder)

                    HStack {
                        Button {
                            Task { await store.importSubscription() }
                        } label: {
                            if store.importing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(NSLocalizedString("Download & Import", comment: ""))
                            }
                        }
                        .disabled(store.importing || store.urlText.isEmpty)
                        .keyboardShortcut(.defaultAction)

                        Spacer()

                        if store.configImported {
                            Label(NSLocalizedString("Ready", comment: ""), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }

                    messageView
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label(NSLocalizedString("One-Click System Proxy", comment: ""), systemImage: "laptopcomputer.and.arrow.down")
                        .font(.headline)
                    Text(NSLocalizedString(
                        "Route macOS traffic through Waypoint automatically. TUN mode in Settings captures everything without this.",
                        comment: ""
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button(store.systemProxyEnabled
                        ? NSLocalizedString("Disable System Proxy", comment: "")
                        : NSLocalizedString("Enable System Proxy", comment: "")) {
                        if store.systemProxyEnabled {
                            store.disableSystemProxy()
                        } else {
                            store.enableSystemProxy()
                        }
                    }
                }
                .padding(4)
            }

            Spacer()

            HStack {
                Text("Waypoint · \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(NSLocalizedString("Open Dashboard", comment: "")) {
                    openDashboard()
                }
                Button(NSLocalizedString("Get Started", comment: "")) {
                    finish()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            if store.urlText.isEmpty,
               let clipboard = NSPasteboard.general.string(forType: .string)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
               clipboard.isUrlVaild() {
                store.urlText = clipboard
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image("WaypointStatus")
                .resizable()
                .frame(width: 44, height: 44)
                .padding(.bottom, 2)
            Text(NSLocalizedString("Welcome to Waypoint", comment: ""))
                .font(.largeTitle.bold())
            Text(NSLocalizedString(
                "Two steps to start: bring in your subscription, then switch on the proxy.",
                comment: ""
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var messageView: some View {
        if let message = store.message {
            Text(message)
                .font(.caption)
                .foregroundStyle(store.messageIsError ? Color.red : Color.green)
                .textSelection(.enabled)
        }
    }

    private func openDashboard() {
        AppDelegate.shared.actionDashboard(nil)
    }

    private func finish() {
        Persistence.onboardingCompleted = true
        NSApp.keyWindow?.close()
    }
}
