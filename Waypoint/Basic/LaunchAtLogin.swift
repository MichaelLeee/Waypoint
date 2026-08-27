//
//  LaunchAtLogin.swift
//  Waypoint
//

import Combine
import Foundation
import ServiceManagement

// @unchecked: only holds a thread-safe CurrentValueSubject.
public class LaunchAtLogin: @unchecked Sendable {
    static let shared = LaunchAtLogin()

    private init() {
        isEnableVirable.send(isEnabled)
    }

    public var isEnabled: Bool {
        get {
            return LoginServiceKit.isExistLoginItems()
        }
        set {
            if newValue {
                LoginServiceKit.addLoginItems()
            } else {
                LoginServiceKit.removeLoginItems()
            }
            isEnableVirable.send(newValue)
        }
    }

    let isEnableVirable = CurrentValueSubject<Bool, Never>(false)
}
