//
//  WaypointAppIntents.swift
//  Waypoint
//  App Intents (Shortcuts/Siri) for the core status-menu actions. Intents
//  delegate to the existing AppDelegate actions so behavior stays identical
//  to the NSMenu path.
//

import AppIntents
import Foundation

enum ProxyModeAppEnum: String, AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Proxy Mode")
    static let caseDisplayRepresentations: [ProxyModeAppEnum: DisplayRepresentation] = [
        .rule: .init(title: "Rule"),
        .global: .init(title: "Global"),
        .direct: .init(title: "Direct"),
    ]

    case rule, global, direct

    var mode: WaypointProxyMode {
        switch self {
        case .rule: return .rule
        case .global: return .global
        case .direct: return .direct
        }
    }
}

struct ConfigFileEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Config")
    static let defaultQuery = ConfigFileQuery()

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }
}

struct ConfigFileQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ConfigFileEntity] {
        identifiers.map(ConfigFileEntity.init)
    }

    func suggestedEntities() async throws -> [ConfigFileEntity] {
        await MainActor.run {
            ConfigManager.getConfigFilesList().map(ConfigFileEntity.init)
        }
    }
}

struct ToggleSystemProxyIntent: AppIntent {
    static let title: LocalizedStringResource = "Set as System Proxy"
    static let description = IntentDescription("Toggles the macOS system proxy through Waypoint.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppDelegate.shared.actionSetSystemProxy(nil)
        let dialog: IntentDialog = ConfigManager.shared.proxyPortAutoSet
            ? "System proxy enabled."
            : "System proxy disabled."
        return .result(dialog: dialog)
    }
}

struct ToggleEnhancedModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Enhanced Mode"
    static let description = IntentDescription(
        "Enables or disables TUN enhanced mode. Applying it restarts the core."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let enabled = !Settings.tunEnabled
        AppDelegate.shared.actionEnhanceTunMode(AppDelegate.shared.enhanceTunModeMenuItem)
        let dialog: IntentDialog = enabled
            ? "Enhanced mode enabled."
            : "Enhanced mode disabled."
        return .result(dialog: dialog)
    }
}

struct SetProxyModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Proxy Mode"
    static let description = IntentDescription("Switches between Rule, Global, and Direct modes.")

    @Parameter(title: "Proxy Mode")
    var mode: ProxyModeAppEnum

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppDelegate.shared.switchProxyMode(mode: mode.mode)
        return .result(dialog: IntentDialog("Proxy mode set to \(mode.rawValue)."))
    }
}

struct SelectConfigIntent: AppIntent {
    static let title: LocalizedStringResource = "Select Config"
    static let description = IntentDescription("Loads one of the installed Waypoint configs.")

    @Parameter(title: "Config")
    var config: ConfigFileEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppDelegate.shared.updateConfig(configName: config.id)
        return .result(dialog: IntentDialog("Config \(config.id) activated."))
    }
}

struct ReloadConfigIntent: AppIntent {
    static let title: LocalizedStringResource = "Reload Config"
    static let description = IntentDescription("Reloads the current Waypoint config.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppDelegate.shared.updateConfig()
        return .result(dialog: IntentDialog("Config reloaded."))
    }
}

struct OpenDashboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Dashboard"
    static let description = IntentDescription("Opens the Waypoint dashboard window.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppDelegate.shared.actionDashboard(nil)
        return .result()
    }
}

struct WaypointShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleSystemProxyIntent(),
            phrases: [
                "Toggle \(.applicationName) system proxy",
                "\(.applicationName) system proxy",
            ],
            shortTitle: "Set as System Proxy",
            systemImageName: "arrow.triangle.swap"
        )
        AppShortcut(
            intent: ToggleEnhancedModeIntent(),
            phrases: ["Toggle \(.applicationName) enhanced mode"],
            shortTitle: "Toggle Enhanced Mode",
            systemImageName: "bolt.horizontal"
        )
        AppShortcut(
            intent: SetProxyModeIntent(),
            phrases: ["Set \(.applicationName) proxy mode to \(\.$mode)"],
            shortTitle: "Set Proxy Mode",
            systemImageName: "arrow.triangle.branch"
        )
        AppShortcut(
            intent: SelectConfigIntent(),
            phrases: ["Select \(.applicationName) config \(\.$config)"],
            shortTitle: "Select Config",
            systemImageName: "doc.badge.gearshape"
        )
        AppShortcut(
            intent: ReloadConfigIntent(),
            phrases: ["Reload \(.applicationName) config"],
            shortTitle: "Reload Config",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: OpenDashboardIntent(),
            phrases: ["Open \(.applicationName) dashboard"],
            shortTitle: "Open Dashboard",
            systemImageName: "chart.line.uptrend.xyaxis"
        )
    }
}
