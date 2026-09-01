//
//  MitmEngine.swift
//  WaypointMitmEngine
//  Local intercept proxy: accepts HTTP proxy traffic on a loopback port,
//  terminates CONNECT tunnels with embedder-provided identities, and
//  applies header-level rules in between. Lifecycle is main-thread (the
//  embedder decides when it runs); all I/O runs on a small NIO event loop
//  group instead of one thread per connection.
//

import Foundation
import NIO
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class MitmEngine: @unchecked Sendable {
    public static let portRangeStart: UInt16 = 6153
    public static let portRangeEnd: UInt16 = 6199

    public enum EngineError: LocalizedError {
        case noFreePort

        public var errorDescription: String? {
            switch self {
            case .noFreePort:
                return "No free port available in range \(portRangeStart)-\(portRangeEnd)."
            }
        }
    }

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private let lock = NSLock()
    private var serverChannel: Channel?
    private var activeRules: [MitmRule] = []
    private var activeProvider: MitmIdentityProviding?

    /// Port the engine bound after a successful `start`; 0 when stopped.
    public private(set) var port: UInt16 = 0

    public var isRunning: Bool { port != 0 }

    public init() {}

    deinit {
        try? group.syncShutdownGracefully()
    }

    // MARK: - Lifecycle

    /// Binds the first free port in `portRange`. Throws `EngineError.noFreePort`
    /// when the whole range is busy.
    @discardableResult
    public func start(rules: [MitmRule],
                      identityProvider: MitmIdentityProviding,
                      portRange: ClosedRange<UInt16> = portRangeStart ... portRangeEnd) throws -> UInt16 {
        stop()
        signal(SIGPIPE, SIG_IGN)
        for candidate in portRange {
            do {
                let channel = try bind(candidate, provider: identityProvider).wait()
                lock.lock()
                serverChannel = channel
                activeRules = rules
                activeProvider = identityProvider
                port = candidate
                lock.unlock()
                return candidate
            } catch {
                continue
            }
        }
        throw EngineError.noFreePort
    }

    /// Replaces the rule set for sessions accepted from now on. Existing
    /// sessions keep the rules they were accepted with.
    public func updateRules(_ newRules: [MitmRule]) {
        lock.lock()
        activeRules = newRules
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let channel = serverChannel
        serverChannel = nil
        activeRules = []
        activeProvider = nil
        port = 0
        lock.unlock()
        if let channel {
            try? channel.close().wait()
        }
    }

    private func bind(_ port: UInt16, provider: MitmIdentityProviding) throws -> Channel {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.close() }
                let (rules, provider) = self.sessionContext()
                guard let provider else { return channel.close() }
                return channel.pipeline.addHandler(HeadHandler(rules: rules, identityProvider: provider))
            }
        return try bootstrap.bind(host: "127.0.0.1", port: Int(port)).wait()
    }

    private func sessionContext() -> (rules: [MitmRule], provider: MitmIdentityProviding?) {
        lock.lock()
        defer { lock.unlock() }
        return (activeRules, activeProvider)
    }
}
