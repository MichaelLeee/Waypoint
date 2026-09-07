import Testing
import Foundation
@testable import WaypointCore

struct RemoteConfigUpdatePolicyTests {
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    @Test func updatingEntryIsNeverDue() {
        #expect(!RemoteConfigUpdatePolicy.isDueForUpdate(
            updating: true, updateTime: date(-100_000), now: date(0),
            interval: 2 * 3600, ignoreTimeLimit: true))
    }

    @Test func ignoreTimeLimitOverridesFreshInterval() {
        #expect(RemoteConfigUpdatePolicy.isDueForUpdate(
            updating: false, updateTime: date(-1), now: date(0),
            interval: 2 * 3600, ignoreTimeLimit: true))
    }

    @Test func freshEntryIsSkipped() {
        #expect(!RemoteConfigUpdatePolicy.isDueForUpdate(
            updating: false, updateTime: date(-3600), now: date(0),
            interval: 2 * 3600, ignoreTimeLimit: false))
    }

    @Test func staleEntryIsDue() {
        #expect(RemoteConfigUpdatePolicy.isDueForUpdate(
            updating: false, updateTime: date(-(2 * 3600)), now: date(0),
            interval: 2 * 3600, ignoreTimeLimit: false))
    }

    @Test func nilUpdateTimeIsTreatedAsEpoch() {
        #expect(RemoteConfigUpdatePolicy.isDueForUpdate(
            updating: false, updateTime: nil, now: date(0),
            interval: 2 * 3600, ignoreTimeLimit: false))
    }
}

struct RemoteConfigFetchTests {
    @Test func requestRejectsMalformedURL() {
        // Foundation's URL(string:) is lenient (spaces get percent-encoded),
        // but an empty string and a malformed IPv6 literal are rejected.
        #expect(RemoteConfigFetch.request(urlString: "") == nil)
        #expect(RemoteConfigFetch.request(urlString: "http://[::1") == nil)
    }

    @Test func requestUsesReloadIgnoringCacheData() {
        let request = RemoteConfigFetch.request(urlString: "https://example.com/config.yaml")
        #expect(request?.url?.absoluteString == "https://example.com/config.yaml")
        #expect(request?.cachePolicy == .reloadIgnoringCacheData)
    }

    @Test func decodeAccepts2xxRangeBoundaries() {
        let data = Data("port: 7890\n".utf8)
        #expect(RemoteConfigFetch.decodeResponse(statusCode: 200, data: data) != nil)
        #expect(RemoteConfigFetch.decodeResponse(statusCode: 299, data: data) != nil)
        #expect(RemoteConfigFetch.decodeResponse(statusCode: 199, data: data) == nil)
        #expect(RemoteConfigFetch.decodeResponse(statusCode: 300, data: data) == nil)
        #expect(RemoteConfigFetch.decodeResponse(statusCode: 404, data: data) == nil)
    }

    @Test func decodeRejectsNonUTF8Body() {
        #expect(RemoteConfigFetch.decodeResponse(statusCode: 200, data: Data([0xFF, 0xFE, 0xFD])) == nil)
    }
}
