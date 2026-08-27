//
//  WaypointNotifier.swift
//  Waypoint
//
//  AppKit's NSUserNotificationCenter is deprecated since macOS 11, so all
//  posting goes through the UserNotifications framework. The modal-alert
//  fallback preserves the old behaviour when notifications are denied and
//  the caller insists on surfacing the message.
//

import Cocoa
import UserNotifications

enum WaypointNotifier {
    static func post(title: String, info: String, identifier: String? = nil, notiOnly: Bool = true) {
        // UNUserNotificationCenter is not Sendable; query it fresh inside
        // each @Sendable closure instead of capturing an instance.
        let center = UNUserNotificationCenter.current()
        center.delegate = UserNotificationCenterDelegate.shared
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .denied:
                guard !notiOnly else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        postNotificationAlert(title: title, info: info, identifier: identifier)
                    }
                }
            case .authorized, .provisional:
                postNotification(title: title, info: info, identifier: identifier)
            case .notDetermined:
                center.requestAuthorization(options: .alert) { granted, _ in
                    if granted {
                        postNotification(title: title, info: info, identifier: identifier)
                    } else {
                        guard !notiOnly else { return }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                postNotificationAlert(title: title, info: info, identifier: identifier)
                            }
                        }
                    }
                }
            @unknown default:
                postNotification(title: title, info: info, identifier: identifier)
            }
        }
    }

    private static func postNotification(title: String, info: String, identifier: String? = nil) {
        let center = UNUserNotificationCenter.current()
        center.delegate = UserNotificationCenterDelegate.shared
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = info
        if let identifier {
            content.userInfo = ["identifier": identifier]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Logger.log("send noti fail: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        postNotificationAlert(title: title, info: info, identifier: identifier)
                    }
                }
            }
        }
    }

    @MainActor private static func postNotificationAlert(title: String, info: String, identifier: String?) {
        if Settings.disableNoti {
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
        if let identifier {
            UserNotificationCenterDelegate.shared.handleNotificationActive(with: identifier)
        }
    }

    static func postConfigFileChangeDetectionNotice() {
        post(title: NSLocalizedString("Config file have been changed", comment: ""),
             info: NSLocalizedString("Tap to reload config", comment: ""),
             identifier: "postConfigFileChangeDetectionNotice")
    }

    static func postStreamApiConnectFail(api: String) {
        post(title: "\(api) api connect error!",
             info: NSLocalizedString("Use reload config to try reconnect.", comment: ""))
    }

    @MainActor static func postConfigErrorNotice(msg: String) {
        let configName = ConfigManager.selectConfigName.isEmpty ? "" :
            Paths.configFileName(for: ConfigManager.selectConfigName)

        let message = "\(configName): \(msg)"
        postNotificationAlert(title: NSLocalizedString("Config loading Fail!", comment: ""), info: message, identifier: nil)
    }

    static func postSpeedTestBeginNotice() {
        post(title: NSLocalizedString("Benchmark", comment: ""),
             info: NSLocalizedString("Benchmark has begun, please wait.", comment: ""))
    }

    static func postSpeedTestingNotice() {
        post(title: NSLocalizedString("Benchmark", comment: ""),
             info: NSLocalizedString("Benchmark is processing, please wait.", comment: ""))
    }

    static func postSpeedTestFinishNotice() {
        post(title: NSLocalizedString("Benchmark", comment: ""),
             info: NSLocalizedString("Benchmark Finished!", comment: ""), notiOnly: false)
    }

    static func postProxyChangeByOtherAppNotice() {
        post(title: NSLocalizedString("System Proxy Changed", comment: ""),
             info: NSLocalizedString("Proxy settings are changed by another process. Waypoint is no longer the default system proxy.", comment: ""), notiOnly: true)
    }
}

// Main-thread confined singleton.
class UserNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = UserNotificationCenterDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let identifier = response.notification.request.content.userInfo["identifier"] as? String {
            handleNotificationActive(with: identifier)
        }
        center.removeAllDeliveredNotifications()
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.list, .banner])
    }

    func handleNotificationActive(with identifier: String) {
        // Delegate callbacks and modal alerts arrive on the main thread.
        MainActor.assumeIsolated {
            switch identifier {
            case "postConfigFileChangeDetectionNotice":
                AppDelegate.shared.updateConfig()
            default:
                break
            }
        }
    }
}
