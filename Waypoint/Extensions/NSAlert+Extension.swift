//
//  NSAlert+Extension.swift
//  Waypoint
//

import Cocoa

extension NSAlert {
    static func alert(with text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }
}
