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

    // Same UserDefaults key as Settings.useSwiftUIMenu. MenuBarExtra is
    // always declared because SceneBuilder cannot do runtime if/else; the
    // isInserted binding hides the SwiftUI status item while the AppKit
    // menu is in use.
    @AppStorage("useSwiftUIMenu") private var useSwiftUIMenu = false

    var body: some Scene {
        MenuBarExtra(isInserted: $useSwiftUIMenu) {
            MenuBarMenuView()
        } label: {
            Image("menu_icon").renderingMode(.template)
        }
        .menuBarExtraStyle(.window)
        SwiftUI.Settings {
            EmptyView()
        }
    }
}
