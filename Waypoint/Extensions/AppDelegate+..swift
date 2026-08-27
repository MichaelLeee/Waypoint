//
//  AppDelegate+.swift
//  Waypoint
//
import AppKit

extension AppDelegate {
    // All call sites are main-thread contexts (hot keys, target/action,
    // applicationShouldTerminate); assumeIsolated keeps Swift 6 happy.
    nonisolated static var shared: AppDelegate {
        MainActor.assumeIsolated {
            NSApplication.shared.delegate as! AppDelegate
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
