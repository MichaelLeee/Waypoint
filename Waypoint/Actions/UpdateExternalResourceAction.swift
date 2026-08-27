//
//  UpdateExternalResourceAction.swift
//  Waypoint
//

import Foundation

enum UpdateExternalResourceAction {
    static func run() {
        Task { @MainActor in
            let provider = await ApiRequest.requestExternalProviderNames()
            let totalCount = provider.proxies.count + provider.rules.count
            if totalCount == 0 {
                onFinished(success: 0, total: 0, fails: [])
                return
            }
            var successCount = 0
            var fails = [String]()

            for name in provider.proxies {
                if await ApiRequest.updateProvider(name: name, type: .proxy) {
                    successCount += 1
                } else {
                    fails.append(name)
                }
            }

            for name in provider.rules {
                if await ApiRequest.updateProvider(name: name, type: .rule) {
                    successCount += 1
                } else {
                    fails.append(name)
                }
            }

            onFinished(success: successCount, total: totalCount, fails: fails)
        }
    }

    private static func onFinished(success: Int, total: Int, fails: [String]) {
        var info = String(format: NSLocalizedString("total: %d, success: %d", comment: ""), total, success)
        if !fails.isEmpty {
            info.append(String(format: NSLocalizedString("fails: %@", comment: ""), fails.joined(separator: " ")))
        }
        WaypointNotifier.post(title: NSLocalizedString("Update external resource complete", comment: ""), info: info)
    }
}
