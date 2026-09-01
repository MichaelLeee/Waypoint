//
//  CoreProcessManager.swift
//  Waypoint
//  Replaces the old in-process CGO bridge (goWaypoint/main.go) with mihomo
//  running as a subprocess, controlled over its REST API + WebSocket.
//

import Foundation

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
    private var spawnedViaHelper = false
    private let maxReadinessAttempts = 50 // 50 * 0.2s = up to 10s

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
        stop()

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
        try await waitForReadiness(externalController: externalController, secret: secret)
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
        if let nullHandle = FileHandle(forWritingAtPath: "/dev/null") {
            proc.standardOutput = nullHandle
            proc.standardError = nullHandle
        }
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
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
            let once = ResumeOnce(continuation)
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
        if spawnedViaHelper {
            PrivilegedHelperManager.shared.helper()?.stopCore { _ in }
            spawnedViaHelper = false
        } else {
            process?.terminate()
        }
        process = nil
        isRunning = false
    }

    // MARK: - Readiness

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

    nonisolated static func binaryPath() -> String? {
        return Bundle.main.path(forResource: "mihomo", ofType: nil)
    }
}

/// Resumes the wrapped continuation at most once; safe to call from any thread
/// (XPC reply queues race with connection error handlers).
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<Void, Error>

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(with: result)
    }
}
