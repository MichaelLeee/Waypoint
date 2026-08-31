//
//  SSIDSuspendTool.swift
//  Waypoint Pro
//

import AppKit
import Combine
import CoreLocation
import CoreWLAN
import Foundation

// @unchecked: effectively main-thread confined; cross-thread entry points hop
// via MainActor.assumeIsolated.
class SSIDSuspendTool: NSObject, @unchecked Sendable {
    static let shared = SSIDSuspendTool()
    private var ssidChangePublisher = PassthroughSubject<String, Never>()
    private var cancellables = Set<AnyCancellable>()
    private lazy var locationManager = CLLocationManager()

    var showNoticeOnNotPermission = false

    @MainActor
    func setup() {
        if AppVersionUtil.hasVersionChanged {
            showNoticeOnNotPermission = true
        }
        requestPermissionIfNeed()
        do {
            try CWWiFiClient.shared().startMonitoringEvent(with: .ssidDidChange)
            CWWiFiClient.shared().delegate = self
            ssidChangePublisher
                .receive(on: DispatchQueue.main)
                .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
                .delay(for: .seconds(1), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.update()
                    }
                }.store(in: &cancellables)
        } catch let err {
            Logger.log(String(describing: err), level: .warning)
            NotificationCenter.default
                .publisher(for: .systemNetworkStatusDidChange)
                .receive(on: DispatchQueue.main)
                .delay(for: .seconds(2), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.update()
                    }
                }.store(in: &cancellables)
        }
        ConfigManager.shared
            .proxyShouldPausedPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .filter { _ in MainActor.assumeIsolated { ConfigManager.shared.proxyPortAutoSet } }
            .sink { pause in
                MainActor.assumeIsolated {
                    if pause {
                        SystemProxyManager.shared.disableProxy()
                    } else {
                        SystemProxyManager.shared.enableProxy()
                    }
                }
            }.store(in: &cancellables)

        update()
    }

    @MainActor
    func requestPermissionIfNeed() {
        defer {
            showNoticeOnNotPermission = false
        }
        if #available(macOS 14, *) {
            if Settings.disableSSIDList.isEmpty { return }
            if locationManager.authorizationStatus == .notDetermined {
                Logger.log("request location permission")
                locationManager.desiredAccuracy = kCLLocationAccuracyReduced
                locationManager.delegate = self
                locationManager.requestAlwaysAuthorization()
            } else if locationManager.authorizationStatus != .authorized {
                if showNoticeOnNotPermission {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self else { return }
                        MainActor.assumeIsolated {
                            self.openLocationSettings()
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func update() {
        let suspended = shouldSuspend()
        if suspended != ConfigManager.shared.proxyShouldPaused {
            ConfigManager.shared.proxyShouldPaused = suspended
        }
    }

    func shouldSuspend() -> Bool {
        if let currentSSID = getCurrentSSID() {
            return Settings.disableSSIDList.contains(currentSSID)
        } else {
            return false
        }
    }

    private func getCurrentSSID() -> String? {
        if #available(macOS 14, *) {
            if locationManager.authorizationStatus != .authorized {
                // CoreWLAN returns nil without location permission; the old
                // fallback (airport) was removed by Apple in macOS 14.4.
                Logger.log("location permission not granted, cannot read SSID", level: .debug)
                return nil
            }
        }
        return CWWiFiClient.shared().interface()?.ssid()
    }

    @MainActor
    private func openLocationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Location")!)
        NSApp.activate(ignoringOtherApps: true)
        NSAlert.alert(with: NSLocalizedString("Please enable the location service for Waypoint to detect your current WiFi network's SSID name and provide the auto-suspend services.", comment: ""))
    }
}

extension SSIDSuspendTool: CLLocationManagerDelegate {
    // CLLocationManager delivers on the creating thread's run loop, which is main here.
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Logger.log("Location status: \(status.rawValue)")
        MainActor.assumeIsolated {
            if status != .authorized, showNoticeOnNotPermission {
                openLocationSettings()
            }
            showNoticeOnNotPermission = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

extension SSIDSuspendTool: CWEventDelegate {
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        ssidChangePublisher.send(interfaceName)
    }
}
