//
//  StatusItemTool.swift
//  Waypoint Pro
//

import AppKit

enum StatusItemTool {
    // Immutable constants, safe to read from any thread.
    static let menuImage: NSImage = {
        let customImagePath = (NSHomeDirectory() as NSString).appendingPathComponent("/.config/waypoint/menuImage.png")
        if let image = NSImage(contentsOfFile: customImagePath) {
            image.isTemplate = true
            return image
        }
        if let image = NSImage(named: "menu_icon") {
            image.isTemplate = true
            return image
        }
        return NSImage()
    }()

    nonisolated(unsafe) static let font: NSFont = {
        let fontSize: CGFloat = 9
        let font: NSFont
        if let fontName = Persistence.statusMenuFontName,
           let f = NSFont(name: fontName, size: fontSize) {
            font = f
        } else {
            font = NSFont.menuBarFont(ofSize: fontSize)
        }
        return font
    }()
}
