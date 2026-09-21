//
//  MenuItemViewTests.swift
//  WaypointTests
//

import AppKit
import Testing
@testable import Waypoint

@MainActor
@Suite("Menu item views", .serialized)
struct MenuItemViewTests {

    // These fail by aborting the process rather than by failing an expectation,
    // which is the intended signal: MenuItemBaseView used to call
    // assertionFailure from the un-overridden didClickView, so clicking a row
    // that has nothing to do on click took the whole app down.

    @Test("A row without a didClickView override ignores the click")
    func unoverriddenClickIsIgnored() {
        let view = MenuItemBaseView(frame: .zero, autolayout: false)
        view.didClickView()
    }

    // The class from the crash: a group row is an item with a submenu, so AppKit
    // opens the submenu and the view itself has no click work to do.
    @Test("A proxy group row ignores the click")
    func groupRowClickIsIgnored() {
        let view = ProxyGroupMenuItemView(group: "GLOBAL",
                                          targetProxy: "DIRECT",
                                          hasLeftPadding: false,
                                          observeUpdate: false)
        view.didClickView()
    }
}
