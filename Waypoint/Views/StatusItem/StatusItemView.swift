//
//  StatusItemView.swift
//  Waypoint
//

import AppKit
import Foundation

/// Drives the standard NSStatusItem button (icon + one-line speed title).
/// A custom NSView subview inside the status-bar button is avoided on
/// purpose: AppKit's status-item replicant machinery re-snapshots the button
/// content whenever one of its layers is re-displayed, and a custom subview
/// keeps that cycle alive — each snapshot re-displays the subview's layers,
/// re-marks the status window, and schedules the next snapshot, burning
/// ~40% CPU at idle on macOS 26. The standard image+title path converges.
@MainActor
final class StatusItemView: NSObject, StatusItemViewProtocol {
    private let statusItem: NSStatusItem
    private let button: NSStatusBarButton

    private var showsSpeed: Bool
    private var lastTitle: String?
    private var lastEnableProxy: Bool?
    private var up = 0
    private var down = 0

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        guard let button = statusItem.button else {
            fatalError("NSStatusItem has no button")
        }
        self.button = button
        self.showsSpeed = ConfigManager.shared.showNetSpeedIndicator
        super.init()
        button.image = StatusItemTool.menuImage
        button.imagePosition = .imageLeading
        // Monospaced digits keep the ↑x ↓x title a constant width as the
        // numbers tick, so only the glyphs change — no layout jitter.
        button.font = .monospacedDigitSystemFont(
            ofSize: StatusItemTool.font.pointSize, weight: .regular)
        refreshTitle()
    }

    static func create(statusItem: NSStatusItem?) -> StatusItemView {
        guard let statusItem else {
            fatalError("a status item is required to build the menu bar view")
        }
        return StatusItemView(statusItem: statusItem)
    }

    func updateSize(width: CGFloat) {
        if statusItem.length != width {
            statusItem.length = width
        }
    }

    func updateViewStatus(enableProxy: Bool) {
        guard enableProxy != lastEnableProxy else { return }
        lastEnableProxy = enableProxy
        button.appearsDisabled = !enableProxy
    }

    func updateSpeedLabel(up: Int, down: Int) {
        guard showsSpeed else { return }
        if up != self.up || down != self.down {
            self.up = up
            self.down = down
            refreshTitle()
        }
    }

    func showSpeedContainer(show: Bool) {
        guard show != showsSpeed else { return }
        showsSpeed = show
        up = 0
        down = 0
        refreshTitle()
    }

    private func refreshTitle() {
        let title = showsSpeed
            ? "↑\(SpeedUtils.getSpeedString(for: up)) ↓\(SpeedUtils.getSpeedString(for: down))"
            : ""
        guard title != lastTitle else { return }
        lastTitle = title
        button.title = title
    }
}
