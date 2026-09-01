//
//  MitmEngineIntegrationTests.swift
//  WaypointCoreTests
//  End-to-end coverage for the engine's I/O paths: a local NIO echo server
//  stands in for the upstream host, requests are pushed through the engine
//  as an HTTP proxy with a raw byte-collecting client. TLS CONNECT
//  interception needs certificate material and is exercised by the app.
//

import Foundation
import NIO
import Testing
@testable import WaypointMitmEngine

// Ports reserved for tests so the suite never collides with the app's
// 6153-6199 range when both run on the same machine.
private let testPortRange: ClosedRange<UInt16> = 46153 ... 46199

private struct ThrowingIdentityProvider: MitmIdentityProviding {
    func identity(forHost host: String) throws -> MitmIdentity {
        throw NSError(domain: "MitmEngineIntegrationTests", code: 1)
    }
}

@Suite("MITM engine end-to-end", .serialized)
struct MitmEngineIntegrationTests {

    /// Fixed headers + echo of the received request bytes as the body, then
    /// close — so the client's closeFuture doubles as "response complete".
    private final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer

        private let hits: Counter
        private var received: [UInt8] = []
        private var responded = false

        init(hits: Counter) {
            self.hits = hits
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = Self.unwrapInboundIn(data)
            received.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
            guard !responded else { return }
            responded = true
            hits.increment()
            var payload = Array("HTTP/1.1 200 OK\r\nX-Echo-Old: z\r\nContent-Length: \(received.count)\r\n\r\n".utf8)
            payload.append(contentsOf: received)
            context.writeAndFlush(NIOAny(ByteBuffer(bytes: payload))).whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }

    private final class EchoServer {
        let channel: Channel
        let hits: Counter

        init(group: EventLoopGroup) throws {
            hits = Counter()
            channel = try ServerBootstrap(group: group)
                .childChannelInitializer { [hits] channel in
                    channel.pipeline.addHandler(EchoHandler(hits: hits))
                }
                .bind(host: "127.0.0.1", port: 0).wait()
        }

        var port: UInt16 {
            UInt16(channel.localAddress!.port!)
        }

        func close() {
            try? channel.close().wait()
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// Collects every inbound byte through a shared box; the test reads the
    /// box after the channel's closeFuture completes.
    private final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer

        private let box: ByteBox

        init(box: ByteBox) {
            self.box = box
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = Self.unwrapInboundIn(data)
            box.append(buffer.readBytes(length: buffer.readableBytes) ?? [])
        }
    }

    private final class ByteBox: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [UInt8] = []

        func append(_ newBytes: [UInt8]) {
            lock.lock()
            bytes.append(contentsOf: newBytes)
            lock.unlock()
        }

        var value: [UInt8] {
            lock.lock()
            defer { lock.unlock() }
            return bytes
        }
    }

    /// Runs one proxied request against a freshly started engine and returns
    /// everything the client received before the connection closed.
    private func runThroughProxy(
        request: [UInt8],
        rules: [MitmRule],
        group: EventLoopGroup
    ) throws -> (response: [UInt8], engine: MitmEngine) {
        let engine = MitmEngine()
        try engine.start(rules: rules, identityProvider: ThrowingIdentityProvider(), portRange: testPortRange)
        let box = ByteBox()
        let channel = try ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(ResponseCollector(box: box))
            }
            .connect(host: "127.0.0.1", port: Int(engine.port)).wait()
        try channel.writeAndFlush(ByteBuffer(bytes: request)).wait()
        channel.closeFuture.wait()
        return (box.value, engine)
    }

    @Test("Plain HTTP request is rewritten once and relayed verbatim")
    func plainHTTPRequestRewrite() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }
        let echo = try EchoServer(group: group)
        defer { echo.close() }

        let head = "POST /echo HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\nX-Old: a\r\nContent-Length: 0\r\n\r\n"
        let (response, engine) = try runThroughProxy(
            request: Array(head.utf8),
            rules: [MitmRule(kind: .requestHeader, host: "127.0.0.1", headerKey: "X-Old", headerValue: "new")],
            group: group
        )
        defer { engine.stop() }

        let text = String(bytes: response, encoding: .isoLatin1)!
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        // The echo body IS the bytes that reached the upstream — assert them
        // exactly: rule applied, old header gone, single terminator.
        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        #expect(body == "POST /echo HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\nX-Old: new\r\n\r\n")
        #expect(!body.contains("\r\n\r\n\r\n"))
        #expect(echo.hits.value == 1)
    }

    @Test("Reject rule answers 403 without contacting the upstream")
    func rejectRuleBlocks() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }
        let echo = try EchoServer(group: group)
        defer { echo.close() }

        let head = "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\n\r\n"
        let (response, engine) = try runThroughProxy(
            request: Array(head.utf8),
            rules: [MitmRule(kind: .reject, host: "127.0.0.1")],
            group: group
        )
        defer { engine.stop() }

        let text = String(bytes: response, encoding: .isoLatin1)!
        #expect(text.hasPrefix("HTTP/1.1 403 Blocked by Waypoint\r\n"))
        #expect(echo.hits.value == 0)
    }

    @Test("Response-header rules rewrite the first response block")
    func responseHeaderRewrite() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }
        let echo = try EchoServer(group: group)
        defer { echo.close() }

        let head = "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\n\r\n"
        let (response, engine) = try runThroughProxy(
            request: Array(head.utf8),
            rules: [MitmRule(kind: .responseHeader, host: "127.0.0.1", headerKey: "X-Echo-Old", headerValue: "new")],
            group: group
        )
        defer { engine.stop() }

        let text = String(bytes: response, encoding: .isoLatin1)!
        #expect(text.contains("X-Echo-Old: new\r\n"))
        #expect(!text.contains("X-Echo-Old: z"))
        #expect(text.contains("Content-Length: "))
        // The echoed request bytes must survive as the intact body.
        #expect(text.hasSuffix("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\n\r\n"))
        #expect(echo.hits.value == 1)
    }

    @Test("Rules without a host match do not touch the traffic")
    func unmatchedRulesAreInert() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }
        let echo = try EchoServer(group: group)
        defer { echo.close() }

        let head = "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\nX-Keep: 1\r\n\r\n"
        let (response, engine) = try runThroughProxy(
            request: Array(head.utf8),
            rules: [
                MitmRule(kind: .requestHeader, host: "other.host", headerKey: "X-Keep", headerValue: ""),
                MitmRule(kind: .responseHeader, host: "other.host", headerKey: "X-Echo-Old", headerValue: ""),
            ],
            group: group
        )
        defer { engine.stop() }

        let text = String(bytes: response, encoding: .isoLatin1)!
        #expect(text.contains("X-Keep: 1"))
        #expect(text.contains("X-Echo-Old: z"))
    }

    @Test("Start reports noFreePort when the whole range is busy")
    func portExhaustion() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        var sockets: [Channel] = []
        defer {
            for socket in sockets {
                try? socket.close().wait()
            }
        }
        for port in testPortRange {
            sockets.append(try ServerBootstrap(group: group).bind(host: "127.0.0.1", port: Int(port)).wait())
        }

        let engine = MitmEngine()
        #expect(throws: MitmEngine.EngineError.noFreePort) {
            try engine.start(rules: [], identityProvider: ThrowingIdentityProvider(), portRange: testPortRange)
        }
        engine.stop()
    }

    @Test("Lifecycle reports the bound port and clears it on stop")
    func lifecycle() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        let engine = MitmEngine()
        #expect(!engine.isRunning)
        #expect(engine.port == 0)
        let bound = try engine.start(rules: [], identityProvider: ThrowingIdentityProvider(), portRange: testPortRange)
        #expect(engine.isRunning)
        #expect(engine.port == bound)
        #expect(testPortRange.contains(bound))
        engine.stop()
        #expect(!engine.isRunning)
        #expect(engine.port == 0)
    }
}
