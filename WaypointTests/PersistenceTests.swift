//
//  PersistenceTests.swift
//  WaypointTests
//

import Foundation
import Testing
@testable import Waypoint

// UserDefaults.standard is process-wide mutable state, so the suite runs
// serially and every test that touches a real preference restores it.
@Suite("Persistence", .serialized)
struct PersistenceTests {

    /// Scratch keys are namespaced so a value left behind by a crashed run
    /// can never be mistaken for an app preference.
    private func scratchKey(_ name: String) -> String {
        "org.waypnt.waypointTests.\(name)"
    }

    /// Runs `body` with `key` unset, then puts the previous value back.
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

    // MARK: - Generic access

    @Test("A written value reads back")
    func roundTrip() {
        let key = scratchKey("roundTrip")
        defer { Persistence.removeValue(forKey: key) }

        Persistence.write("mixed", forKey: key)
        #expect(Persistence.read(key, default: "other") == "mixed")
        #expect(Persistence.string(forKey: key) == "mixed")
        #expect(Persistence.hasValue(forKey: key))
    }

    @Test("An absent key reports absent and returns the caller's default")
    func absentKeyReturnsDefault() {
        let key = scratchKey("absent")
        Persistence.removeValue(forKey: key)

        #expect(Persistence.read(key, default: "fallback") == "fallback")
        #expect(Persistence.string(forKey: key) == nil)
        #expect(!Persistence.hasValue(forKey: key))
    }

    @Test("A value of the wrong type falls back instead of trapping")
    func wrongTypeFallsBack() {
        let key = scratchKey("wrongType")
        defer { Persistence.removeValue(forKey: key) }

        Persistence.write("not a number", forKey: key)
        #expect(Persistence.read(key, default: 7) == 7)
    }

    // MARK: - Codable blobs

    @Test("Codable values round-trip through their JSON blob")
    func codableRoundTrip() {
        let key = scratchKey("codable")
        defer { Persistence.removeValue(forKey: key) }

        let value = SampleRecord(name: "tokyo", weight: 3)
        Persistence.saveCodable(value, forKey: key)
        #expect(Persistence.loadCodable(SampleRecord.self, forKey: key) == value)
    }

    @Test("An unreadable blob decodes to nil rather than crashing")
    func corruptBlobIsNil() {
        let key = scratchKey("corrupt")
        defer { Persistence.removeValue(forKey: key) }

        UserDefaults.standard.set(Data("not json".utf8), forKey: key)
        #expect(Persistence.loadCodable(SampleRecord.self, forKey: key) == nil)
    }

    @Test("A blob written under the old schema decodes to nil")
    func schemaDriftIsNil() {
        let key = scratchKey("drift")
        defer { Persistence.removeValue(forKey: key) }

        Persistence.saveCodable(["unexpected": true], forKey: key)
        #expect(Persistence.loadCodable(SampleRecord.self, forKey: key) == nil)
    }

    // MARK: - Documented defaults

    @Test("Unset preferences fall back to their documented defaults")
    func typedDefaults() {
        #expect(withCleared(Persistence.Key.selectConfigName) { Persistence.selectConfigName } == "config")
        #expect(withCleared(Persistence.Key.selectOutBoundMode) { Persistence.selectOutBoundMode } == .rule)
        #expect(withCleared(Persistence.Key.selectLoggingApiLevel) { Persistence.selectLoggingApiLevel } == .info)
        #expect(withCleared(Persistence.Key.autoUpdateEnable) { Persistence.autoUpdateEnable })
        #expect(withCleared(Persistence.Key.selectedRemoteControlConfigID) { Persistence.selectedRemoteControlConfigID } == "")
        #expect(withCleared(Persistence.Key.savedProxyInfo) { Persistence.savedProxyInfo }.isEmpty)
    }

    @Test("An unreadable stored value falls back to the default mode and level")
    func unreadableEnumFallsBack() {
        defer {
            Persistence.removeValue(forKey: Persistence.Key.selectOutBoundMode)
            Persistence.removeValue(forKey: Persistence.Key.selectLoggingApiLevel)
        }

        Persistence.write("not-a-mode", forKey: Persistence.Key.selectOutBoundMode)
        Persistence.write("not-a-level", forKey: Persistence.Key.selectLoggingApiLevel)
        #expect(Persistence.selectOutBoundMode == .rule)
        #expect(Persistence.selectLoggingApiLevel == .info)
    }

    @Test("Typed accessors round-trip through their keys")
    func typedRoundTrip() {
        defer {
            Persistence.removeValue(forKey: Persistence.Key.selectConfigName)
            Persistence.removeValue(forKey: Persistence.Key.selectOutBoundMode)
            Persistence.removeValue(forKey: Persistence.Key.autoUpdateEnable)
            Persistence.removeValue(forKey: Persistence.Key.onboardingCompleted)
        }

        Persistence.selectConfigName = "direct"
        Persistence.selectOutBoundMode = .global
        Persistence.autoUpdateEnable = false
        Persistence.onboardingCompleted = true

        #expect(Persistence.selectConfigName == "direct")
        #expect(Persistence.selectOutBoundMode == .global)
        #expect(!Persistence.autoUpdateEnable)
        #expect(Persistence.onboardingCompleted)
    }
}

private struct SampleRecord: Codable, Equatable {
    let name: String
    let weight: Int
}
