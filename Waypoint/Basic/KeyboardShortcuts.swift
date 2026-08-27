//
//  KeyboardShortcuts.swift
//  Waypoint
//

import AppKit
import Foundation
import KeyboardShortcuts

// Name is an immutable struct wrapping a String identifier; the conformance
// only silences strict-concurrency checks for the package type.
extension KeyboardShortcuts.Name: @unchecked @retroactive Sendable {}

extension KeyboardShortcuts.Name {
    static let toggleSystemProxyMode = Self("shortCut.toggleSystemProxyMode")
    static let copyShellCommand = Self("shortCut.copyShellCommand")
    static let copyExternalShellCommand = Self("shortCut.copyExternalShellCommand")

    static let modeDirect = Self("shortCut.modeDirect")
    static let modeRule = Self("shortCut.modeRule")
    static let modeGlobal = Self("shortCut.modeGlobal")

    static let log = Self("shortCut.log")
    static let dashboard = Self("shortCut.dashboard")
    static let openMenu = Self("shortCut.openMenu")
    static let nativeDashboard = Self("shortCut.nativeDashboard")
}

enum KeyboardShortCutManager {
    static func setup() {
        // Hot-key handlers are nonisolated in the package but always fire on
        // the main thread; hop explicitly for MainActor UI code.
        KeyboardShortcuts.onKeyUp(for: .toggleSystemProxyMode) {
            MainActor.assumeIsolated {
                AppDelegate.shared.actionSetSystemProxy(nil)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .copyShellCommand) {
            MainActor.assumeIsolated {
                AppDelegate.shared.actionCopyExportCommand(AppDelegate.shared.copyExportCommandMenuItem)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .copyExternalShellCommand) {
            MainActor.assumeIsolated {
                AppDelegate.shared.actionCopyExportCommand(AppDelegate.shared.copyExportCommandExternalMenuItem)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .modeDirect) {
            MainActor.assumeIsolated {
                AppDelegate.shared.switchProxyMode(mode: .direct)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .modeRule) {
            MainActor.assumeIsolated {
                AppDelegate.shared.switchProxyMode(mode: .rule)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .modeGlobal) {
            MainActor.assumeIsolated {
                AppDelegate.shared.switchProxyMode(mode: .global)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .log) {
            MainActor.assumeIsolated {
                AppDelegate.shared.actionShowLog(nil)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .dashboard) {
            MainActor.assumeIsolated {
                AppDelegate.shared.actionDashboard(nil)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .openMenu) {
            MainActor.assumeIsolated {
                AppDelegate.shared.statusItem.button?.performClick(nil)
            }
        }
        KeyboardShortcuts.onKeyUp(for: .nativeDashboard) {
            MainActor.assumeIsolated {
                SwiftUIWindowController.create(
                    title: "Connections",
                    content: ConnectionsRootView()
                ).showWindow(nil)
            }
        }
    }
}
