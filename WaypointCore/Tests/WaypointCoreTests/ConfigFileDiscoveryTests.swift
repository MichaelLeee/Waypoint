//
//  ConfigFileDiscoveryTests.swift
//  WaypointCoreTests
//

import Testing
@testable import WaypointCore

struct ConfigFileDiscoveryTests {
    @Test func keepsOnlyYamlFiles() {
        let names = ConfigFileDiscovery.configNames(
            fromFileNames: ["config.yaml", "notes.txt", "backup.yml", "rules.yaml"])
        #expect(names == ["config", "rules"])
    }

    @Test func stripsOnlyTheLastExtension() {
        #expect(ConfigFileDiscovery.configNames(
            fromFileNames: ["my.config.yaml"]) == ["my.config"])
    }

    @Test func extensionMatchIsCaseSensitive() {
        #expect(ConfigFileDiscovery.configNames(
            fromFileNames: ["UPPER.YAML", "mixed.Yaml"]) == [])
    }

    @Test func dotfileNamedYamlProducesEmptyName() {
        // Preserved legacy behavior: ".yaml" passes the filter and yields "".
        #expect(ConfigFileDiscovery.configNames(fromFileNames: [".yaml"]) == [""])
    }

    @Test func nonYamlSuffixFilesAreExcluded() {
        #expect(ConfigFileDiscovery.configNames(
            fromFileNames: ["config.yaml.bak", "yaml", "config.yaml.orig"]) == [])
    }
}
