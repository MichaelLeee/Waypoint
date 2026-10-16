//
//  StaleCoreReaping.swift
//  WaypointCore
//  Decides whether a pid left behind by a previous run is this app's own proxy
//  core and can be stopped.
//
//  Why this exists: the core is a separate process, so an app that is killed —
//  a crash never runs any cleanup — leaves it running with every port it
//  listens on still bound. The next launch then finds its own listeners already
//  taken and ends up reading the orphan's state instead of its own, which shows
//  up as "the core reports no inbound ports" and a system proxy that never
//  engages. Killing the wrong process would be far worse than that, so the
//  decision is made here, from three independent facts, and unit-tested.
//

import Foundation

public enum StaleCoreReaping {
    public enum Verdict: Equatable {
        /// This app's own core, abandoned by a process that died: stop it.
        case reap
        /// Alive, but not ours to stop (another app instance still owns it, or
        /// it is some other program that happens to hold the recorded pid).
        case notOurs
        /// No process with that pid (or an unusable pid).
        case gone
    }

    /// `command` is what `ps -o command=` reports: the executable path, followed
    /// by its arguments when the caller is allowed to see them. Matching on the
    /// path rather than on `comm` avoids depending on whether that column prints
    /// a full path or a truncated name.
    public static func verdict(pid: Int32,
                               parentPid: Int,
                               command: String,
                               expectedCorePath: String,
                               launchdPid: Int = 1) -> Verdict {
        guard pid > 0 else { return .gone }
        // An orphan is reparented to launchd. A core whose parent is still alive
        // belongs to a running app instance — possibly a second copy of this
        // app — and killing it would break that instance's proxy.
        guard parentPid == launchdPid else { return .notOurs }
        guard isOurCore(command: command, expectedCorePath: expectedCorePath) else {
            return .notOurs
        }
        return .reap
    }

    /// True when `command` names this app's proxy binary: either the exact file
    /// this build would spawn, or the same file inside another copy of the app
    /// (a build left in DerivedData while /Applications holds the running one).
    /// Matching on the bundle-relative tail keeps an unrelated `mihomo` — a
    /// Homebrew install, say — from qualifying.
    public static func isOurCore(command: String, expectedCorePath: String) -> Bool {
        let tail = trailingComponents(of: expectedCorePath, count: 4)
        guard !tail.isEmpty else { return command == expectedCorePath }
        return command.contains(tail)
    }

    /// The last `count` path components, joined back together: for
    /// `/X/Waypoint.app/Contents/Resources/mihomo` this is
    /// `Waypoint.app/Contents/Resources/mihomo`.
    static func trailingComponents(of path: String, count: Int) -> String {
        let components = path.split(separator: "/").suffix(count)
        guard components.count == count else { return "" }
        return components.joined(separator: "/")
    }

    /// Reads the parent pid and the command out of
    /// `ps -p <pid> -o ppid= -o command=`. The command is a path that may contain
    /// spaces and is followed by arguments, so only the first field is taken as
    /// the parent pid and everything after it is the command.
    public static func parseProcessInfo(_ psOutput: String) -> (parentPid: Int, command: String)? {
        let trimmed = psOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let separator = trimmed.firstIndex(where: { $0.isWhitespace }) else { return nil }
        guard let parentPid = Int(trimmed[trimmed.startIndex ..< separator]) else { return nil }
        let command = String(trimmed[separator...]).trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        return (parentPid, command)
    }

    public static func pidFileContents(pid: Int32) -> String {
        "\(pid)\n"
    }

    /// The pid recorded in the file, or nil when it is missing, empty or not a
    /// positive number (a truncated or hand-edited file must not be signalled).
    public static func pid(fromPidFile contents: String) -> Int32? {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed), pid > 0 else { return nil }
        return pid
    }
}
