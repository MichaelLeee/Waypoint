//
//  UrlValidationTests.swift
//  WaypointCoreTests
//

import Testing
@testable import WaypointCore

struct UrlValidationTests {
    @Test func acceptsHttpAndHttps() {
        #expect("http://example.com".isValidHttpUrl())
        #expect("https://example.com/path?q=1".isValidHttpUrl())
        #expect("https://192.168.1.1:9090".isValidHttpUrl())
    }

    @Test func rejectsOtherSchemes() {
        #expect(!"ftp://example.com".isValidHttpUrl())
        #expect(!"file:///tmp/config.yaml".isValidHttpUrl())
    }

    @Test func rejectsMissingSchemeOrHost() {
        #expect(!"example.com".isValidHttpUrl())
        #expect(!"http://".isValidHttpUrl())
        #expect(!"/relative/path".isValidHttpUrl())
    }

    @Test func rejectsEmpty() {
        #expect(!"".isValidHttpUrl())
    }

    @Test func rejectsGarbageThatUrlInitAccepts() {
        // URL(string:) succeeds on loose input like this, but the host is
        // nil — pinned so a Foundation change can't silently widen the gate.
        #expect(!"not a url".isValidHttpUrl())
    }
}
