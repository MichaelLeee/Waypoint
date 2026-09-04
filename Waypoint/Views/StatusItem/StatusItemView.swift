//
//  StatusItemView.swift
//  Waypoint
//

import AppKit
import Foundation

/// Drives the standard NSStatusItem button (icon + stacked ↑/↓ rates).
/// A custom NSView subview inside the status-bar button is avoided on
/// purpose: AppKit's status-item replicant machinery re-snapshots the button
/// content whenever one of its layers is re-displayed, and a custom subview
/// keeps that cycle alive — each snapshot re-displays the subview's layers,
/// re-marks the status window, and schedules the next snapshot, burning
/// ~40% CPU at idle on macOS 26. The standard image path converges, so the
/// two-line rate display is rendered into a single template image instead.
@MainActor
final class StatusItemView: NSObject, StatusItemViewProtocol {
    private static let iconLength: CGFloat = 18
    private static let iconTextGap: CGFloat = 4
    private static let buttonPadding: CGFloat = 8
    private static let iconOnlyLength: CGFloat = 25
    private static let displayHeight: CGFloat = 22

    private let statusItem: NSStatusItem
    private let button: NSStatusBarButton

    private var showsSpeed: Bool
    private var lastEnableProxy: Bool?
    private var lastUpText: String?
    private var lastDownText: String?
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
        button.imagePosition = .imageOnly
        refreshDisplay()
    }

    static func create(statusItem: NSStatusItem?) -> StatusItemView {
        guard let statusItem else {
            fatalError("a status item is required to build the menu bar view")
        }
        return StatusItemView(statusItem: statusItem)
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
            refreshDisplay()
        }
    }

    func showSpeedContainer(show: Bool) {
        guard show != showsSpeed else { return }
        showsSpeed = show
        up = 0
        down = 0
        refreshDisplay()
    }

    private func refreshDisplay() {
        guard showsSpeed else {
            button.image = StatusItemTool.menuImage
            button.title = ""
            lastUpText = nil
            lastDownText = nil
            if statusItem.length != Self.iconOnlyLength {
                statusItem.length = Self.iconOnlyLength
            }
            return
        }
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: min(StatusItemTool.font.pointSize, 8), weight: .regular)
        let upText = "↑\(SpeedUtils.getSpeedString(for: up))"
        let downText = "↓\(SpeedUtils.getSpeedString(for: down))"
        guard upText != lastUpText || downText != lastDownText else { return }
        lastUpText = upText
        lastDownText = downText
        let image = Self.stackedDisplayImage(
            icon: StatusItemTool.menuImage, lines: [upText, downText], font: font)
        button.image = image
        button.title = ""
        let targetLength = ceil(image.size.width) + Self.buttonPadding
        if statusItem.length != targetLength {
            statusItem.length = targetLength
        }
    }

    /// Icon at the left, the given text lines stacked at the right, drawn at
    /// 2x backing resolution so text stays crisp on Retina. Rendered black
    /// with `isTemplate = true` so the menu bar tints it for dark/light mode.
    private static func stackedDisplayImage(
        icon: NSImage, lines: [String], font: NSFont) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let attributed = lines.map { NSAttributedString(string: $0, attributes: attributes) }
        let lineHeight = ceil(font.ascender - font.descender)
        // Fixed-width slot sized for the widest possible rate string. The
        // status button centers its content, so letting the image width
        // follow the current digit count would re-center (wiggle) icon and
        // text on every 1↔3-digit transition; a constant width keeps the
        // layout anchored, with the extra space trailing after the text.
        let slotSamples = ["1023.9GB/s", "99.99MB/s", "1023KB/s"]
        let textWidth = slotSamples
            .map { ceil(($0 as NSString).size(withAttributes: attributes).width) }
            .max() ?? 0
        let width = iconLength + iconTextGap + textWidth
        let height = max(displayHeight, lineHeight * CGFloat(lines.count))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            fatalError("unable to build status item bitmap")
        }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let textBlockHeight = lineHeight * CGFloat(lines.count)
        let top = (height + textBlockHeight) / 2 - font.ascender
        for (index, line) in attributed.enumerated() {
            line.draw(at: NSPoint(
                x: iconLength + iconTextGap,
                y: top - lineHeight * CGFloat(index)))
        }
        let iconRect = NSRect(
            x: 0, y: (height - iconLength) / 2, width: iconLength, height: iconLength)
        icon.draw(in: iconRect)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}