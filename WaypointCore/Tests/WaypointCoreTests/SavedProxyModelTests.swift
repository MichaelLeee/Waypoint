//
//  SavedProxyModelTests.swift
//  WaypointCoreTests
//

import Foundation
import Testing
@testable import WaypointCore

struct SavedProxyModelTests {
    @Test func keyExcludesSelectedProxy() {
        let a = SavedProxyModel(group: "GLOBAL", selected: "A", config: "config")
        let b = SavedProxyModel(group: "GLOBAL", selected: "B", config: "config")
        #expect(a.key == b.key)
        #expect(a.key == "GLOBAL_config")
    }

    @Test func keyDistinguishesGroupsAndConfigs() {
        let a = SavedProxyModel(group: "GLOBAL", selected: "A", config: "config")
        let b = SavedProxyModel(group: "Proxy", selected: "A", config: "config")
        let c = SavedProxyModel(group: "GLOBAL", selected: "A", config: "other")
        #expect(a.key != b.key)
        #expect(a.key != c.key)
    }

    @Test func dedupeKeepsFirstOccurrence() {
        let first = SavedProxyModel(group: "GLOBAL", selected: "A", config: "config")
        let second = SavedProxyModel(group: "GLOBAL", selected: "B", config: "config")
        let distinct = SavedProxyModel(group: "Proxy", selected: "C", config: "config")
        let result = SavedProxyModel.deduplicated([first, second, distinct])
        #expect(result == [first, distinct])
    }

    @Test func dedupePreservesOrder() {
        let models = [
            SavedProxyModel(group: "C", selected: "x", config: "config"),
            SavedProxyModel(group: "A", selected: "x", config: "config"),
            SavedProxyModel(group: "B", selected: "x", config: "config"),
        ]
        #expect(SavedProxyModel.deduplicated(models).map(\.group) == ["C", "A", "B"])
    }

    @Test func codableRoundTrip() throws {
        let model = SavedProxyModel(group: "GLOBAL", selected: "Node", config: "config.yaml")
        let data = try JSONEncoder().encode([model])
        let decoded = try JSONDecoder().decode([SavedProxyModel].self, from: data)
        #expect(decoded == [model])
    }
}
