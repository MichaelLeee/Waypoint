import Testing
@testable import WaypointCore

struct KillSwitchRulesTests {
    @Test func endsWithFailClosedBlock() {
        let rules = KillSwitchRules.compose(uid: 501, allowsLan: false)
        #expect(rules.hasSuffix("block drop out all\n"))
    }

    @Test func containsPassesForOwnUidAndRoot() {
        let rules = KillSwitchRules.compose(uid: 501, allowsLan: false)
        #expect(rules.contains("pass out user 501 no state"))
        #expect(rules.contains("pass out user root no state"))
        #expect(rules.contains("pass on lo0 all no state"))
    }

    @Test func lanPassOnlyWhenAllowed() {
        #expect(!KillSwitchRules.compose(uid: 501, allowsLan: false)
            .contains("192.168.0.0/16"))
        #expect(KillSwitchRules.compose(uid: 501, allowsLan: true)
            .contains("pass out to { 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 } no state"))
    }

    @Test func lanPassSitsBeforeFinalBlock() {
        let rules = KillSwitchRules.compose(uid: 0, allowsLan: true)
        let lanIndex = rules.index(of: "pass out to { 192.168.0.0/16")!
        let blockIndex = rules.index(of: "block drop out all")!
        #expect(lanIndex < blockIndex)
    }

    @Test func utunRangesEnumerated() {
        let rules = KillSwitchRules.compose(uid: 501, allowsLan: false)
        #expect(rules.contains("utun0 utun1 utun2 utun3 utun4 utun5 utun6 utun7"))
        #expect(rules.contains("utun8 utun9 utun10 utun11 utun12 utun13 utun14 utun15"))
    }
}

extension String {
    /// Index of the first line starting with the given prefix, nil if absent.
    func index(of linePrefix: String) -> Int? {
        var offset = 0
        for line in split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(linePrefix) { return offset }
            offset += line.count + 1
        }
        return nil
    }
}

struct LivenessTrackerTests {
    @Test func successResetsFailureStreak() {
        var tracker = LivenessTracker(maxConsecutiveFailures: 3)
        #expect(!tracker.registerFailure())
        tracker.registerSuccess()
        #expect(tracker.failureCount == 0)
        #expect(!tracker.registerFailure())
        #expect(tracker.failureCount == 1)
    }

    @Test func tripsAtThreshold() {
        var tracker = LivenessTracker(maxConsecutiveFailures: 3)
        #expect(!tracker.registerFailure())
        #expect(!tracker.registerFailure())
        #expect(tracker.registerFailure())
    }

    @Test func staysTrippedWithoutSuccess() {
        var tracker = LivenessTracker(maxConsecutiveFailures: 2)
        _ = tracker.registerFailure()
        #expect(tracker.registerFailure())
        #expect(tracker.registerFailure())
    }

    @Test func thresholdOneTripsImmediately() {
        var tracker = LivenessTracker(maxConsecutiveFailures: 1)
        #expect(tracker.registerFailure())
    }
}
