//
//  CoreProcessManager.swift
//  Waypoint
//  Replaces the old in-process CGO bridge (goWaypoint/main.go) with mihomo
//  running as a subprocess, controlled over its REST API + WebSocket.
//

import Foundation
import WaypointCore

@MainActor
final class CoreProcessManager {
    static let shared = CoreProcessManager()

    enum CoreProcessError: LocalizedError {
        case binaryNotFound
        case launchFailed(String)
        case notReady(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "mihomo binary not found in the app bundle."
            case let .launchFailed(message):
                return "Failed to launch mihomo: \(message)"
            case let .notReady(message):
                return "mihomo did not become ready: \(message)"
            }
        }
    }

    private var process: Process?
    // Processes awaiting exit after stop(); a relaunch must not start until
    // they release their ports.
    private var terminatingProcesses = [Process]()
    private var spawnedViaHelper = false
    private let maxReadinessAttempts = 50 // 50 * 0.2s = up to 10s
    // Helper-spawned cores have no Process handle in this app, so exit is
    // detected by polling the core's API.
    private var livenessMonitorTask: Task<Void, Never>?
    private static let livenessCheckIntervalNanos: UInt64 = 3_000_000_000
    // Five polls (~15s) rather than three (~9s): the check has a 1s request
    // timeout, so a loaded machine or a wake-from-sleep blip could otherwise
    // reach three consecutive failures and tear down a healthy proxy.
    private static let maxLivenessFailures = 5

    private(set) var isRunning = false

    /// Invoked on the main actor when the subprocess exits after having been running.
    var onUnexpectedExit: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 1
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Lifecycle

    func start(configPath: String,
               homeDir: String,
               externalController: String,
               secret: String,
               externalUI: String? = nil) async throws {
        // Before stop(): stop() clears the pid record this reads, and only a
        // core left behind by a *process that died* still has a record. A core
        // of ours that is still live is recognised and left alone here, then
        // stopped properly just below.
        await reapAbandonedCoreIfAny()

        stop()
        // Wait for any previously stopped local core to actually exit before
        // relaunching, otherwise the new mihomo races a still-dying one for
        // the same ports and fails to bind.
        for proc in terminatingProcesses where proc.isRunning {
            proc.terminationHandler = nil
            for _ in 0 ..< 30 where proc.isRunning {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        terminatingProcesses.removeAll()

        // Warn, never block. mihomo treats "address already in use" on its
        // external controller as non-fatal and keeps running, so if something
        // else already holds that port the readiness probe below is answered by
        // it: the app reports the core as running while its own core bound
        // nothing, and every later reading — ports, proxies, config — silently
        // describes the other process. A leftover core from an earlier run is
        // the usual cause and the log says so, but refusing to start here would
        // turn a proxy that still works on its own ports into one that does not
        // run at all, which is worse than the confusion it prevents.
        await warnIfAPIPortIsTaken(externalController: externalController, secret: secret)

        if Settings.tunEnabled {
            try await startViaHelper(configPath: configPath,
                                     homeDir: homeDir,
                                     externalController: externalController,
                                     secret: secret,
                                     externalUI: externalUI)
        } else {
            try await startLocally(configPath: configPath,
                                   homeDir: homeDir,
                                   externalController: externalController,
                                   secret: secret,
                                   externalUI: externalUI)
        }
        do {
            try await waitForReadiness(externalController: externalController, secret: secret)
        } catch {
            // The process is already spawned at this point (locally, or as root
            // through the helper) and nothing else tracks it: leaving it alive
            // keeps the proxy and API ports bound while the app reports the core
            // as down, so a later "set as system proxy" would point at a core the
            // app does not know about. The termination handler cannot cover this
            // either — isRunning was never set, so it stays silent.
            stop()
            throw error
        }
        startLivenessMonitor(externalController: externalController, secret: secret)
    }

    // MARK: - Cleaning up a core left behind

    /// Stops a core this app spawned and then died without stopping — a crash
    /// runs no cleanup, and the core is a separate process, so it survives with
    /// every port it listens on still bound. The next launch would then find its
    /// own listeners taken and read the orphan's state instead of its own.
    ///
    /// Only a core that this app's own pid record points at, that is a Waypoint
    /// core, and whose parent is launchd (i.e. genuinely orphaned rather than
    /// serving a running app instance) is signalled; the decision itself lives
    /// in `StaleCoreReaping` so it can be unit-tested. TUN mode is not covered:
    /// there the helper owns the child and the app never learns its pid.
    private func reapAbandonedCoreIfAny() async {
        guard let expectedCorePath = Self.binaryPath(),
              let pid = AbandonedCoreRecord.read() else { return }

        guard let info = Self.processInfo(of: pid) else {
            // The pid is gone; the record is simply stale.
            AbandonedCoreRecord.clear()
            return
        }

        switch StaleCoreReaping.verdict(pid: pid,
                                        parentPid: info.parentPid,
                                        command: info.command,
                                        expectedCorePath: expectedCorePath) {
        case .gone:
            AbandonedCoreRecord.clear()
        case .notOurs:
            Logger.log("leaving pid \(pid) alone: \(info.command) is not an abandoned core of this app",
                       level: .debug)
        case .reap:
            Logger.log("stopping the proxy core left behind by an earlier run (pid \(pid))", level: .warning)
            guard kill(pid, SIGTERM) == 0 else {
                // Not ours to signal — in TUN mode the core runs as root, so
                // only the helper or an administrator can stop it. Say so
                // instead of waiting on a process that is not going anywhere.
                Logger.log("could not stop the leftover core (pid \(pid)): not permitted — run `sudo pkill -f mihomo` to clear it",
                           level: .error)
                return
            }
            if await !waitForExit(pid: pid, seconds: 3) {
                Logger.log("leftover core (pid \(pid)) ignored SIGTERM; killing it", level: .warning)
                kill(pid, SIGKILL)
                _ = await waitForExit(pid: pid, seconds: 2)
            }
            AbandonedCoreRecord.clear()
        }
    }

    /// Parent pid and command line as `ps` reports them, or nil when no such
    /// process exists. `ps` rather than a pid-based API on purpose: it reports a
    /// root-owned core too, which the app cannot inspect any other way.
    private static func processInfo(of pid: Int32) -> (parentPid: Int, command: String)? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "ppid=", "-o", "command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do {
            try ps.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard ps.terminationStatus == 0 else { return nil }
        return StaleCoreReaping.parseProcessInfo(String(decoding: data, as: UTF8.self))
    }

    /// Polls until the pid is gone. `kill(pid, 0)` succeeds while the process
    /// exists; only ESRCH means it has really exited (EPERM means it exists but
    /// belongs to someone else).
    private func waitForExit(pid: Int32, seconds: Double) async -> Bool {
        for _ in 0 ..< max(1, Int(seconds / 0.1)) {
            if hasExited(pid: pid) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return hasExited(pid: pid)
    }

    private func hasExited(pid: Int32) -> Bool {
        errno = 0
        if kill(pid, 0) == 0 { return false }
        return errno == ESRCH
    }

    /// Records the pid of the core this app spawned, so the next launch can tell
    /// an abandoned core of ours from somebody else's process.
    private enum AbandonedCoreRecord {
        private static var url: URL { URL(fileURLWithPath: Paths.corePidFile) }

        static func write(pid: Int32) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? StaleCoreReaping.pidFileContents(pid: pid).write(to: url, atomically: true, encoding: .utf8)
        }

        static func read() -> Int32? {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return StaleCoreReaping.pid(fromPidFile: contents)
        }

        static func clear() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Reports — without changing behaviour — that the controller address is
    /// already in use. Waits first, because a core this app just asked to stop
    /// can still answer for a few seconds: in TUN mode the stop goes through the
    /// helper, which SIGTERMs the core and waits up to 3s before SIGKILLing it,
    /// and warning about our own dying core would be wrong. Five seconds covers
    /// that window with margin.
    private func warnIfAPIPortIsTaken(externalController: String, secret: String) async {
        for attempt in 0 ..< 25 {
            if !(await apiPortIsAnswering(externalController: externalController, secret: secret)) {
                return
            }
            if attempt < 24 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        Logger.log("something is already listening on \(externalController): this core will not be able to use the controller port, and a leftover core from an earlier run is the usual cause — `sudo pkill -f mihomo` in Terminal clears it",
                   level: .error)
    }

    /// True when anything at all answers HTTP on the controller address. A wrong
    /// or absent secret still answers (401), which is why this checks that a
    /// response arrived rather than that it was a success.
    private func apiPortIsAnswering(externalController: String, secret: String) async -> Bool {
        guard let url = URL(string: "http://\(externalController)/version") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return response is HTTPURLResponse
    }

    /// Spawns mihomo as the current user. Used for system-proxy mode (no TUN).
    private func startLocally(configPath: String,
                              homeDir: String,
                              externalController: String,
                              secret: String,
                              externalUI: String?) async throws {
        guard let binaryPath = Self.binaryPath() else {
            throw CoreProcessError.binaryNotFound
        }

        var args = ["-f", configPath, "-d", homeDir, "-ext-ctl", externalController]
        if !secret.isEmpty {
            args += ["-secret", secret]
        }
        if let externalUI, !externalUI.isEmpty {
            args += ["-ext-ui", externalUI]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = args
        // Capture the core's own output (bind failures, port errors) next to
        // the app logs; sending it to /dev/null made launch failures like
        // "0 ports" undiagnosable. Truncated per start, so it holds the
        // latest run only.
        if let coreLog = Self.coreLogHandle() {
            proc.standardOutput = coreLog
            proc.standardError = coreLog
        }
        proc.terminationHandler = { [weak self] finishedProc in
            Task { @MainActor in
                guard let self, self.process === finishedProc else { return }
                let wasRunning = self.isRunning
                self.process = nil
                self.isRunning = false
                if wasRunning {
                    self.onUnexpectedExit?()
                }
            }
        }

        do {
            try proc.run()
        } catch {
            throw CoreProcessError.launchFailed(error.localizedDescription)
        }

        process = proc
        spawnedViaHelper = false
        // Recorded so a later launch can recognise this core if this process
        // dies without stopping it. Written after a successful spawn, so the
        // window in which a crash could go unrecorded is negligible.
        AbandonedCoreRecord.write(pid: proc.processIdentifier)
    }

    /// Spawns mihomo as root via the privileged helper, so it can create the
    /// `utun` device and install routes (`auto-route`). The helper owns the
    /// child and tears it down on stop/exit.
    private func startViaHelper(configPath: String,
                                homeDir: String,
                                externalController: String,
                                secret: String,
                                externalUI: String?) async throws {
        guard let binaryPath = Self.binaryPath() else {
            throw CoreProcessError.binaryNotFound
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceBox<Result<Void, Error>> { continuation.resume(with: $0) }
            guard let helper = PrivilegedHelperManager.shared.helper(failture: { message in
                once.resume(.failure(CoreProcessError.launchFailed(message)))
            }) else {
                once.resume(.failure(CoreProcessError.launchFailed("proxy helper unavailable")))
                return
            }
            helper.launchCore(withBinaryPath: binaryPath,
                              configPath: configPath,
                              homeDir: homeDir,
                              externalController: externalController,
                              secret: secret,
                              externalUI: externalUI ?? "") { errorMessage in
                if let errorMessage, !errorMessage.isEmpty {
                    once.resume(.failure(CoreProcessError.launchFailed(errorMessage)))
                } else {
                    once.resume(.success(()))
                }
            }
        }
        spawnedViaHelper = true
    }

    func stop() {
        livenessMonitorTask?.cancel()
        livenessMonitorTask = nil
        if spawnedViaHelper {
            if let helper = PrivilegedHelperManager.shared.helper() {
                helper.stopCore { _ in }
            } else {
                Logger.log("cannot stop root core: proxy helper unavailable", level: .error)
            }
            spawnedViaHelper = false
        } else if let proc = process {
            // Detach the handler first: this is an intentional stop, not an
            // unexpected exit, and the handler must not clobber a replacement
            // process that start() launches afterwards.
            proc.terminationHandler = nil
            if proc.isRunning {
                proc.terminate()
                terminatingProcesses.append(proc)
            }
        }
        process = nil
        isRunning = false
        // An intentional stop leaves nothing to clean up later.
        AbandonedCoreRecord.clear()
    }

    // MARK: - Readiness

    /// Local cores report exit through their termination handler; helper
    /// cores are invisible to this process, so poll the API instead and
    /// surface a sustained outage as an unexpected exit (which also drops
    /// the kill switch before the dead core strands the network).
    private func startLivenessMonitor(externalController: String, secret: String) {
        livenessMonitorTask?.cancel()
        guard spawnedViaHelper else { return }
        livenessMonitorTask = Task { [weak self] in
            var tracker = LivenessTracker(maxConsecutiveFailures: Self.maxLivenessFailures)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.livenessCheckIntervalNanos)
                guard let self, !Task.isCancelled else { return }
                if await self.isReady(externalController: externalController, secret: secret) {
                    tracker.registerSuccess()
                    continue
                }
                guard tracker.registerFailure() else { continue }
                Logger.log("helper-spawned core stopped answering the API; treating it as exited", level: .error)
                self.isRunning = false
                self.livenessMonitorTask = nil
                self.onUnexpectedExit?()
                return
            }
        }
    }

    private func waitForReadiness(externalController: String, secret: String) async throws {
        for _ in 0 ..< maxReadinessAttempts {
            if !spawnedViaHelper, !(process?.isRunning ?? false) {
                throw CoreProcessError.notReady("process exited before becoming ready")
            }
            if await isReady(externalController: externalController, secret: secret) {
                isRunning = true
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw CoreProcessError.notReady("timed out")
    }

    private func isReady(externalController: String, secret: String) async -> Bool {
        guard let url = URL(string: "http://\(externalController)/version") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - Config validation

    /// Validates a config string by writing it to a temp file under `homeDir`
    /// and running `mihomo -t`. Returns nil on success, otherwise the error text.
    nonisolated static func testConfig(configString: String, homeDir: String) -> String? {
        guard let binaryPath = binaryPath() else {
            return CoreProcessError.binaryNotFound.errorDescription
        }
        let tmpPath = (homeDir as NSString).appendingPathComponent("config_test_\(UUID().uuidString).yaml")
        do {
            try configString.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        defer {
            try? FileManager.default.removeItem(atPath: tmpPath)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["-t", "-f", tmpPath, "-d", homeDir]
        let errPipe = Pipe()
        proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return error.localizedDescription
        }
        proc.waitUntilExit()

        if proc.terminationStatus == 0 {
            return nil
        }
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
    }

    // MARK: - Binary location

    private static func coreLogHandle() -> FileHandle? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Waypoint/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("core.log").path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else { return nil }
        try? handle.truncate(atOffset: 0)
        return handle
    }

    nonisolated static func binaryPath() -> String? {
        return Bundle.main.path(forResource: "mihomo", ofType: nil)
    }
}
