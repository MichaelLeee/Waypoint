//
//  AppDelegate+.swift
//  Waypoint
//
import AppKit

extension AppDelegate {
    // Under the SwiftUI App lifecycle, NSApplication.shared.delegate is
    // SwiftUI's internal wrapper object, not the adaptor instance, so the
    // shared reference is tracked manually at creation instead of casting
    // the NSApplication delegate.
    nonisolated(unsafe) static var sharedRef: AppDelegate?

    // All call sites are main-thread contexts (hot keys, target/action,
    // applicationShouldTerminate); assumeIsolated keeps Swift 6 happy.
    nonisolated static var shared: AppDelegate {
        MainActor.assumeIsolated {
            guard let delegate = sharedRef else {
                fatalError("AppDelegate.shared accessed before the app delegate was created")
            }
            return delegate
        }
    }

    nonisolated static var isAboveMacOS14: Bool {
        if #available(macOS 10.14, *) {
            return true
        }
        return false
    }

    nonisolated static var isAboveMacOS152: Bool {
        if #available(macOS 10.15.3, *) {
            return true
        }
        return false
    }
}
