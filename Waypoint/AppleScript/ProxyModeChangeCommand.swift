//
//  ProxyModeChangeCommand.swift
//  Waypoint
//

import AppKit
import Foundation

@objc class ProxyModeChangeCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let directParameter = directParameter as? String,
              let mode = WaypointProxyMode(rawValue: directParameter)
        else {
            scriptErrorNumber = -1
            scriptErrorString = "please enter a valid parameter. rule, global or direct"
            return nil
        }
        // Script commands are dispatched on the main thread; hop explicitly
        // because NSScriptCommand is not MainActor-annotated in the SDK.
        // Error state is written back outside the closure so `self` (non-
        // Sendable) is never sent across the isolation boundary.
        let errorCode = 0
        let errorMessage: String?
        MainActor.assumeIsolated {
            let delegate = AppDelegate.shared
            let menuItem: NSMenuItem
            switch mode {
            case .rule:
                menuItem = delegate.proxyModeRuleMenuItem
            case .global:
                menuItem = delegate.proxyModeGlobalMenuItem
            case .direct:
                menuItem = delegate.proxyModeDirectMenuItem
            #if PRO_VERSION
                case .script:
                    menuItem = delegate.proxyModeScriptMenuItem
            #endif
            }
            delegate.actionSwitchProxyMode(menuItem)
        }
        if let errorMessage {
            scriptErrorNumber = errorCode
            scriptErrorString = errorMessage
        }
        return nil
    }
}
