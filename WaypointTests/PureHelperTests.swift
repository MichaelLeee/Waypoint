//
//  PureHelperTests.swift
//  WaypointTests
//

import Foundation
import Testing
@testable import Waypoint

@Suite("Pure helpers")
struct PureHelperTests {

    // MARK: - Array+Safe

    @Test("Subscripting an in-range index returns the element")
    func safeSubscriptInRange() {
        #expect([10, 20, 30][safe: 0] == 10)
        #expect([10, 20, 30][safe: 2] == 30)
    }

    @Test("Subscripting past either end returns nil instead of trapping")
    func safeSubscriptOutOfRange() {
        #expect([10, 20, 30][safe: 3] == nil)
        #expect([10, 20, 30][safe: -1] == nil)
        #expect([Int]()[safe: 0] == nil)
    }

    // #expect captures its expression in a closure, so a mutating call has to
    // happen first and the result be checked separately.
    @Test("safeRemove reports whether it removed anything")
    func safeRemoveReportsOutcome() {
        var values = ["a", "b", "c"]
        let removedMiddle = values.safeRemove(at: 1)
        #expect(removedMiddle)
        #expect(values == ["a", "c"])
        let removedPastEnd = values.safeRemove(at: 99)
        #expect(!removedPastEnd)
        let removedNegative = values.safeRemove(at: -1)
        #expect(!removedNegative)
        #expect(values == ["a", "c"])
    }

    // MARK: - Paths

    @Test("A config name maps to a yaml file under the config folder")
    func configPaths() {
        #expect(Paths.configFileName(for: "direct") == "direct.yaml")
        #expect(Paths.localConfigPath(for: "direct").hasSuffix("/.config/waypoint/direct.yaml"))
    }

    @Test("The default config path matches the default selected config name")
    func defaultConfigPath() {
        #expect(kDefaultConfigFilePath.hasSuffix("/.config/waypoint/config.yaml"))
        #expect(kDefaultConfigFilePath == Paths.localConfigPath(for: "config"))
    }

    // Config names reach a file path from the add-config form, the waypoint://
    // URL scheme and the Shortcuts surface, so a name carrying a path separator
    // used to address a file outside the config folder.
    @Test("A config name that would escape the config folder is rejected")
    func invalidConfigNames() {
        #expect(!Paths.isValidConfigName(""))
        #expect(!Paths.isValidConfigName("."))
        #expect(!Paths.isValidConfigName(".."))
        #expect(!Paths.isValidConfigName("../../evil"))
        #expect(!Paths.isValidConfigName("sub/name"))
        #expect(!Paths.isValidConfigName("nul\0name"))
        #expect(Paths.isValidConfigName("config"))
        #expect(Paths.isValidConfigName("my-config.v2"))
    }

    @Test("An escaping config name cannot compose a path outside the config folder")
    func invalidConfigNameStaysInFolder() {
        #expect(Paths.configFileName(for: "../../evil") == "config.yaml")
        #expect(Paths.localConfigPath(for: "../../evil") == Paths.localConfigPath(for: "config"))
        #expect(!Paths.localConfigPath(for: "../evil").contains(".."))
    }

    // MARK: - String+Encode

    @Test("Percent-encoding escapes characters a URL host cannot carry")
    func stringEncoding() {
        #expect("a b".encoded == "a%20b")
        #expect("a#b".encoded == "a%23b")
    }

    @Test("Percent-encoding leaves a plain host name alone")
    func stringEncodingPassthrough() {
        #expect("example.com".encoded == "example.com")
    }
}
