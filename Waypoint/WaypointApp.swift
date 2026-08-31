//
//  WaypointApp.swift
//  Waypoint
//  SwiftUI app lifecycle entry point. The menu-bar UI (NSStatusItem +
//  NSMenu) and all window presentation stay in AppDelegate; there is no
//  storyboard or nib-based application scene.
//

import SwiftUI

@main
struct WaypointApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        if Settings.useSwiftUIMenu {
            MenuBarExtra {
                MenuBarMenuView()
            } label: {
                Image("menu_icon").renderingMode(.template)
            }
            .menuBarExtraStyle(.window)
        } else {
            // The project has its own top-level `Settings` enum; qualify the
            // SwiftUI scene type explicitly.
            SwiftUI.Settings {
                EmptyView()
            }
        }
    }
}
