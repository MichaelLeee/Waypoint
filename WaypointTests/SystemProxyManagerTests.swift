//
//  SystemProxyManagerTests.swift
//  WaypointTests
//

import Foundation
import Testing
@testable import Waypoint

// notifyHelperMissing() asserts the main queue before it posts, so these drive
// the manager the same way the app does: on the main actor, serially.
@MainActor
@Suite("System proxy manager", .serialized)
struct SystemProxyManagerTests {

    private func makeManager(helper: FakeProxyHelper?) -> SystemProxyManager {
        let manager = SystemProxyManager()
        manager.helperProvider = { helper }
        return manager
    }

    /// Runs `body` with the preference unset, then puts the previous value
    /// back, so a setting left behind by another test cannot change the route
    /// the manager takes.
    private func withCleared<T>(_ key: String, _ body: () -> T) -> T {
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        return body()
    }

    @Test("A non-positive port never reaches the helper")
    func portGuardRejectsNonPositivePorts() {
        let fake = FakeProxyHelper()
        let manager = makeManager(helper: fake)

        manager.enableProxy(port: 0, socksPort: 1080)
        manager.enableProxy(port: 8080, socksPort: 0)
        manager.enableProxy(port: -1, socksPort: -1)

        #expect(fake.callNames.isEmpty)
    }

    @Test("enableProxy hands the ports and filter settings to the helper")
    func enableProxyDelegates() {
        let fake = FakeProxyHelper()
        let manager = makeManager(helper: fake)

        manager.enableProxy(port: 8080, socksPort: 1080)

        #expect(fake.callNames == ["enableProxy"])
        #expect(fake.enabledPort == 8080)
        #expect(fake.enabledSocksPort == 1080)
        #expect(fake.enabledFilterInterface == Settings.filterInterface)
        #expect(fake.enabledIgnoreList == Settings.proxyIgnoreList)
    }

    @Test("An error from the helper is reported, not thrown")
    func enableProxySurvivesHelperError() {
        let fake = FakeProxyHelper()
        fake.enableErrorMessage = "networksetup failed"
        let manager = makeManager(helper: fake)

        manager.enableProxy(port: 8080, socksPort: 1080)

        #expect(fake.callNames == ["enableProxy"])
    }

    @Test("With no helper installed, disabling still runs the completion")
    func disableWithoutHelperCompletes() {
        let manager = makeManager(helper: nil)
        var completed = false

        manager.disableProxy(port: 8080, socksPort: 1080) { completed = true }

        #expect(completed)
    }

    @Test("Disabling restores the saved proxy settings by default")
    func disableRestoresSavedSettings() {
        let fake = FakeProxyHelper()
        let manager = makeManager(helper: fake)

        withCleared(Persistence.Key.disableRestoreProxy) {
            var completed = false
            manager.disableProxy(port: 8080, socksPort: 1080) { completed = true }
            #expect(completed)
        }

        #expect(fake.callNames == ["restoreProxy"])
        #expect(fake.restoredPort == 8080)
        #expect(fake.restoredSocksPort == 1080)
        #expect(fake.restoredFilterInterface == Settings.filterInterface)
    }

    @Test("Forcing the disable path skips the restore")
    func forceDisableSkipsRestore() {
        let fake = FakeProxyHelper()
        let manager = makeManager(helper: fake)

        manager.disableProxy(port: 8080, socksPort: 1080, forceDisable: true)

        #expect(fake.callNames == ["disableProxy"])
        #expect(fake.disabledFilterInterface == Settings.filterInterface)
    }

    @Test("saveProxy asks the helper for the current settings")
    func saveProxyDelegates() {
        let fake = FakeProxyHelper()
        let manager = makeManager(helper: fake)

        withCleared(Persistence.Key.disableRestoreProxy) {
            manager.saveProxy()
        }

        #expect(fake.callNames == ["getCurrentProxySetting"])
    }

    @Test("With no helper installed, saveProxy stops before asking")
    func saveProxyWithoutHelperIsQuiet() {
        let manager = SystemProxyManager()
        var providerCalls = 0
        manager.helperProvider = {
            providerCalls += 1
            return nil
        }

        withCleared(Persistence.Key.disableRestoreProxy) {
            manager.saveProxy()
        }

        #expect(providerCalls == 1)
    }
}
