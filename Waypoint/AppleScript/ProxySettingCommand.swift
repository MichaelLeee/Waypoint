//
//  ProxySettingCommand.swift
//  WaypointX
//

import AppKit
import Foundation

@objc class ProxySettingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Script commands are dispatched on the main thread; hop explicitly
        // because NSScriptCommand is not MainActor-annotated in the SDK.
        // Error state is written back outside the closure so `self` (non-
        // Sendable) is never sent across the isolation boundary.
        let errorCode = 0
        let errorMessage: String?
        MainActor.assumeIsolated {
            let delegate = AppDelegate.shared
            // actionSetSystemProxy ignores its sender; passing nil avoids
            // sending the non-Sendable script command across the boundary.
            delegate.actionSetSystemProxy(nil)
        }
        if let errorMessage {
            scriptErrorNumber = errorCode
            scriptErrorString = errorMessage
        }
        return nil
    }
}
