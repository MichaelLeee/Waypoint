import Testing
@testable import WaypointCore

/// The app kills the process these functions point it at, so most of this is
/// about what must NOT be killed.
struct StaleCoreReapingTests {
    private let ourCore = "/Applications/Waypoint.app/Contents/Resources/mihomo"

    /// What `ps -o command=` prints for the core this app spawns.
    private let ourCommandLine = "/Applications/Waypoint.app/Contents/Resources/mihomo -f /Users/x/.config/waypoint/config.yaml -d /Users/x/.config/waypoint/ -ext-ctl 127.0.0.1:9090 -secret abc"

    @Test func ourOwnAbandonedCoreIsReaped() {
        let verdict = StaleCoreReaping.verdict(pid: 4321,
                                               parentPid: 1,
                                               command: ourCommandLine,
                                               expectedCorePath: ourCore)
        #expect(verdict == .reap)
    }

    @Test func aBarePathWithNoVisibleArgumentsIsReaped() {
        // Arguments are hidden for another user's process; the path alone has to
        // be enough.
        let verdict = StaleCoreReaping.verdict(pid: 4321,
                                               parentPid: 1,
                                               command: ourCore,
                                               expectedCorePath: ourCore)
        #expect(verdict == .reap)
    }

    @Test func theSameCoreInAnotherCopyOfTheAppIsReaped() {
        // A build left in DerivedData, or an app the user moved: same file
        // inside the bundle, different prefix.
        let other = "/Users/x/Library/Developer/Xcode/DerivedData/Waypoint-abc/Build/Products/Debug/Waypoint.app/Contents/Resources/mihomo -f /tmp/c.yaml"
        let verdict = StaleCoreReaping.verdict(pid: 4321,
                                               parentPid: 1,
                                               command: other,
                                               expectedCorePath: ourCore)
        #expect(verdict == .reap)
    }

    @Test func anUnrelatedMihomoIsNotReaped() {
        let verdict = StaleCoreReaping.verdict(pid: 4321,
                                               parentPid: 1,
                                               command: "/opt/homebrew/bin/mihomo -d /etc/mihomo",
                                               expectedCorePath: ourCore)
        #expect(verdict == .notOurs)
    }

    @Test func anUnrelatedProgramIsNotReaped() {
        let verdict = StaleCoreReaping.verdict(pid: 4321,
                                               parentPid: 1,
                                               command: "/usr/sbin/sshd -D",
                                               expectedCorePath: ourCore)
        #expect(verdict == .notOurs)
    }

    @Test func aCoreWithALiveParentIsNotReaped() {
        // pid 900 is still running, so this core belongs to it — possibly a
        // second copy of the app whose proxy is working.
        let verdict = StaleCoreReaping.verdict(pid: 4321,
                                               parentPid: 900,
                                               command: ourCommandLine,
                                               expectedCorePath: ourCore)
        #expect(verdict == .notOurs)
    }

    @Test func anUnusablePidIsGone() {
        for pid in [Int32(0), -1] {
            let verdict = StaleCoreReaping.verdict(pid: pid,
                                                   parentPid: 1,
                                                   command: ourCommandLine,
                                                   expectedCorePath: ourCore)
            #expect(verdict == .gone)
        }
    }

    @Test func parsesPSOutput() {
        let parsed = StaleCoreReaping.parseProcessInfo("  1 \(ourCommandLine)\n")
        #expect(parsed?.parentPid == 1)
        #expect(parsed?.command == ourCommandLine)
    }

    @Test func parsesPSOutputWithSpacesInThePath() {
        let command = "/Users/a b/Applications/Waypoint.app/Contents/Resources/mihomo -f /tmp/c.yaml"
        let parsed = StaleCoreReaping.parseProcessInfo("  42 \(command)")
        #expect(parsed?.parentPid == 42)
        #expect(parsed?.command == command)
    }

    @Test func rejectsUnusablePSOutput() {
        // `ps` prints nothing for a pid that does not exist.
        #expect(StaleCoreReaping.parseProcessInfo("") == nil)
        #expect(StaleCoreReaping.parseProcessInfo("\n") == nil)
        #expect(StaleCoreReaping.parseProcessInfo("   \n") == nil)
        #expect(StaleCoreReaping.parseProcessInfo("notapid /usr/bin/x") == nil)
        #expect(StaleCoreReaping.parseProcessInfo("1") == nil)
    }

    @Test func pidFileRoundTrips() {
        let contents = StaleCoreReaping.pidFileContents(pid: 4321)
        #expect(StaleCoreReaping.pid(fromPidFile: contents) == 4321)
    }

    @Test func rejectsAnUnusablePidFile() {
        for contents in ["", "\n", "   ", "abc", "0", "-5", "4321x", "999999999999999999999"] {
            #expect(StaleCoreReaping.pid(fromPidFile: contents) == nil, "accepted \(contents)")
        }
    }

    @Test func trailingComponentsNeedsAFullTail() {
        // A short path cannot yield a bundle-relative tail, so it falls back to
        // requiring an exact match rather than matching too much.
        #expect(StaleCoreReaping.trailingComponents(of: "/mihomo", count: 4) == "")
        #expect(!StaleCoreReaping.isOurCore(command: "/tmp/mihomo", expectedCorePath: "/mihomo"))
        #expect(StaleCoreReaping.trailingComponents(of: ourCore, count: 4)
            == "Waypoint.app/Contents/Resources/mihomo")
    }
}
