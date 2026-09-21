import Testing
@testable import WaypointCore

struct KillSwitchRulesTests {
    @Test func endsWithFailClosedBlock() {
        let rules = KillSwitchRules.compose(uid: 501, allowsLan: false)
        #expect(rules.hasSuffix("block drop out all\n"))
    }

    @Test func containsPassesForOwnUidAndRoot() {
        let rules = KillSwitchRules.compose(uid: 501, allowsLan: false)
        #expect(rules.contains("pass out quick user 501 no state"))
        #expect(rules.contains("pass out quick user root no state"))
        #expect(rules.contains("pass quick on lo0 all no state"))
    }

    @Test func lanPassOnlyWhenAllowed() {
        #expect(!KillSwitchRules.compose(uid: 501, allowsLan: false)
            .contains("192.168.0.0/16"))
        #expect(KillSwitchRules.compose(uid: 501, allowsLan: true)
            .contains("pass out quick to { 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 } no state"))
    }

    @Test func lanPassSitsBeforeFinalBlock() {
        let rules = KillSwitchRules.compose(uid: 0, allowsLan: true)
        let lanIndex = rules.index(of: "pass out quick to { 192.168.0.0/16")!
        let blockIndex = rules.index(of: "block drop out all")!
        #expect(lanIndex < blockIndex)
    }

    // pf resolves pass/block by the LAST matching rule, so a catch-all block at
    // the end wins over every exception that is not marked quick. Without quick
    // on all of them, loading this anchor drops every outbound packet —
    // loopback and the core's own upstream sockets included.
    @Test func everyExceptionIsTerminal() {
        for allowsLan in [true, false] {
            let ruleLines = KillSwitchRules.compose(uid: 501, allowsLan: allowsLan)
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            for line in ruleLines where line.hasPrefix("pass") {
                #expect(line.hasPrefix("pass quick") || line.hasPrefix("pass out quick"),
                        "pass rule is not marked quick: \(line)")
            }
            #expect(ruleLines.filter { $0.hasPrefix("block") } == ["block drop out all"])
            #expect(ruleLines.last == "block drop out all")
        }
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
    // Swift Testing's #expect macro rewrites its argument into an immutable
    // context, so mutating calls must be hoisted out of it.
    @Test func successResetsFailureStreak() {
        var tracker = LivenessTracker(maxConsecutiveFailures: 3)
        var tripped = tracker.registerFailure()
        #expect(!tripped)
        tracker.registerSuccess()
        #expect(tracker.failureCount == 0)
        tripped = tracker.registerFailure()
        #expect(!tripped)
        #expect(tracker.failureCount == 1)
    }

    @Test func tripsAtThreshold() {
        var tracker = LivenessTracker(maxConsecutiveFailures: 3)
        var tripped = tracker.registerFailure()
        #expect(!tripped)
        tripped = tracker.registerFailure()
        #expect(!tripped)
        tripped = tracker.registerFailure()
        #expect(tripped)
    }

    @Test func staysTrippedWithoutSuccess() {
        var tracker = LivenessTracker(maxConsecutiveFailures: 2)
        _ = tracker.registerFailure()
        var tripped = tracker.registerFailure()
        #expect(tripped)
        tripped = tracker.registerFailure()
        #expect(tripped)
    }

    @Test func thresholdOneTripsImmediately() {
        var tracker = LivenessTracker(maxConsecutiveFailures: 1)
        let tripped = tracker.registerFailure()
        #expect(tripped)
    }
}
