//
//  LoginServiceKit.swift
//  LoginServiceKit
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Reduced to the SMAppService implementation; the deployment target is
//  macOS 26, so the legacy LSSharedFileList code path was removed.
//

import Foundation
import ServiceManagement

public enum LoginServiceKit {
    public static func isExistLoginItems(at path: String = Bundle.main.bundlePath) -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    public static func addLoginItems(at path: String = Bundle.main.bundlePath) -> Bool {
        guard !isExistLoginItems(at: path) else {
            return false
        }
        do {
            try SMAppService.mainApp.register()
            return true
        } catch {
            Logger.log("add loginItem error: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    @discardableResult
    public static func removeLoginItems(at path: String = Bundle.main.bundlePath) -> Bool {
        guard isExistLoginItems(at: path) else {
            return false
        }
        do {
            try SMAppService.mainApp.unregister()
            return true
        } catch {
            Logger.log("remove loginItem error: \(error.localizedDescription)", level: .error)
            return false
        }
    }
}
