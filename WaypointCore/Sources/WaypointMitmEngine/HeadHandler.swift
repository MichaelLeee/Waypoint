//
//  HeadHandler.swift
//  WaypointMitmEngine
//  First handler on every accepted connection. Buffers the initial head
//  block, decides what the session is (tunnelled CONNECT, absolute-form or
//  Host-header plain HTTP), applies reject rules, then rewires the pipeline:
//  a TLS server leg for the client, a TLS-or-plain upstream connection, and
//  a pump per direction to relay between the two. Afterwards it stays in the
//  pipeline as a raw pass-through (bytes it sees are already framed data).
//

import NIO
import NIOSSL

// @unchecked Sendable: confined to its channel's event loop after setup.
final class HeadHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private enum Phase {
        case collecting([UInt8])
        case awaitingPeer([UInt8])
        case passthrough
    }

    private let rules: [MitmRule]
    private let identityProvider: MitmIdentityProviding
    // Mutated only from this handler's own event loop.
    private var phase: Phase = .collecting([])

    init(rules: [MitmRule], identityProvider: MitmIdentityProviding) {
        self.rules = rules
        self.identityProvider = identityProvider
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch phase {
        case .passthrough:
            context.fireChannelRead(data)
        case .collecting(var accumulated):
            var buffer = Self.unwrapInboundIn(data)
            accumulated.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
            if let blockEnd = accumulated.firstRange(of: HTTPWire.crlfcrlf) {
                handleHead(context: context, head: accumulated, blockEnd: blockEnd.upperBound)
            } else if accumulated.count > 32_768 {
                context.close(promise: nil)
            } else {
                phase = .collecting(accumulated)
            }
        case .awaitingPeer(var pending):
            var buffer = Self.unwrapInboundIn(data)
            pending.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
            if pending.count > 65_536 {
                context.close(promise: nil)
            } else {
                phase = .awaitingPeer(pending)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    // MARK: - Session setup

    private func handleHead(context: ChannelHandlerContext, head: [UInt8], blockEnd: Int) {
        guard let requestLine = String(
            bytes: HTTPWire.requestLine(of: head),
            encoding: .isoLatin1
        ) else {
            context.close(promise: nil)
            return
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            context.close(promise: nil)
            return
        }
        let method = String(parts[0])
        let target = String(parts[1])

        let establishedTarget: (host: String, port: UInt16)?
        if method == "CONNECT" {
            establishedTarget = HTTPWire.parseAuthority(target, defaultPort: 443)
        } else if target.lowercased().hasPrefix("http://") {
            let netloc = target.dropFirst("http://".count).split(separator: "/").first.map(String.init) ?? ""
            establishedTarget = HTTPWire.parseAuthority(netloc, defaultPort: 80)
        } else if let headerHost = HTTPWire.headerValue(in: head, name: "Host") {
            establishedTarget = HTTPWire.parseAuthority(headerHost, defaultPort: 80)
        } else {
            establishedTarget = nil
        }
        guard let destination = establishedTarget, !destination.host.isEmpty else {
            context.close(promise: nil)
            return
        }

        if rules.contains(where: { $0.kind == .reject && $0.matches(host: destination.host) }) {
            let response = method == "CONNECT"
                ? "HTTP/1.1 403 Blocked by Waypoint\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            context.writeAndFlush(NIOAny(Self.byteBuffer(response)), promise: nil)
            context.close(promise: nil)
            return
        }

        phase = .awaitingPeer([])
        if method == "CONNECT" {
            setupTunnel(context: context, host: destination.host, port: destination.port)
        } else {
            setupPlainHTTP(context: context, head: head, blockEnd: blockEnd, host: destination.host, port: destination.port)
        }
    }

    /// CONNECT: TLS on both legs. The upstream connects first (fail fast),
    /// then the 200 response is written, then the TLS server handler is
    /// installed — so the client's ClientHello, and any bytes arriving
    /// during setup (buffered in `awaitingPeer`), flows through the freshly
    /// installed handlers in order.
    private func setupTunnel(context: ChannelHandlerContext, host: String, port: UInt16) {
        let identity: MitmIdentity
        do {
            identity = try identityProvider.identity(forHost: host)
        } catch {
            context.close(promise: nil)
            return
        }

        let serverTLS: NIOSSLServerHandler
        let clientTLS: NIOSSLClientHandler
        do {
            serverTLS = NIOSSLServerHandler(context: try HeadHandler.serverContext(identity: identity))
            clientTLS = try NIOSSLClientHandler(
                context: try NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration()),
                serverHostname: host
            )
        } catch {
            context.close(promise: nil)
            return
        }

        // NIOSSL handlers and the context are event-loop-confined; the loop
        // bound lets them cross into the setup future's callbacks safely.
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let boundServerTLS = NIOLoopBound(serverTLS, eventLoop: context.eventLoop)
        let boundClientTLS = NIOLoopBound(clientTLS, eventLoop: context.eventLoop)
        let clientChannel = context.channel
        let rules = self.rules
        let bootstrap = ClientBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                channel.pipeline.addHandler(PumpHandler(
                    peer: clientChannel,
                    direction: .response,
                    rules: rules,
                    host: host,
                    startsRewritten: false
                ))
            }

        bootstrap.connect(host: host, port: Int(port)).flatMap { upstreamChannel -> EventLoopFuture<Void> in
            do {
                try upstreamChannel.pipeline.syncOperations.addHandler(boundClientTLS.value)
            } catch {
                return boundContext.value.eventLoop.makeFailedFuture(error)
            }
            return boundContext.value.writeAndFlush(NIOAny(HeadHandler.byteBuffer("HTTP/1.1 200 Connection established\r\n\r\n")))
        }.flatMap {
            let pump = PumpHandler(
                peer: upstreamChannel,
                direction: .request,
                rules: rules,
                host: host,
                startsRewritten: false
            )
            return boundContext.value.eventLoop.makeCompletedFuture {
                try boundContext.value.pipeline.syncOperations.addHandlers([boundServerTLS.value, pump])
            }
        }.whenComplete { result in
            switch result {
            case .success:
                self.finishSetup(context: boundContext.value)
            case .failure:
                boundContext.value.close(promise: nil)
            }
        }
    }

    /// Plain HTTP: cleartext on both legs. The consumed head block is
    /// rewritten with request rules and replayed as the first upstream
    /// bytes; the request-direction pump starts pre-rewritten so subsequent
    /// body bytes stream through untouched.
    private func setupPlainHTTP(context: ChannelHandlerContext, head: [UInt8], blockEnd: Int, host: String, port: UInt16) {
        let matched = rules.filter { $0.kind == .requestHeader && $0.matches(host: host) }
        let rewrittenHead = HTTPWire.rewrittenHeaderBlock(Array(head[..<blockEnd]), rules: matched)
        let firstPayload = rewrittenHead + Array(head[blockEnd...])

        // NIOSSL handlers and the context are event-loop-confined; the loop
        // bound lets them cross into the setup future's callbacks safely.
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let clientChannel = context.channel
        let rules = self.rules
        let bootstrap = ClientBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                channel.pipeline.addHandler(PumpHandler(
                    peer: clientChannel,
                    direction: .response,
                    rules: rules,
                    host: host,
                    startsRewritten: false
                ))
            }

        bootstrap.connect(host: host, port: Int(port)).flatMap { upstreamChannel -> EventLoopFuture<Void> in
            upstreamChannel.writeAndFlush(HeadHandler.byteBuffer(firstPayload)).flatMap {
                let pump = PumpHandler(
                    peer: upstreamChannel,
                    direction: .request,
                    rules: rules,
                    host: host,
                    startsRewritten: true
                )
                return boundContext.value.eventLoop.makeCompletedFuture {
                    try boundContext.value.pipeline.syncOperations.addHandler(pump)
                }
            }
        }.whenComplete { result in
            switch result {
            case .success:
                self.finishSetup(context: boundContext.value)
            case .failure:
                boundContext.value.close(promise: nil)
            }
        }
    }

    /// Switches to raw pass-through and replays bytes that arrived while
    /// the peer side was still being set up.
    private func finishSetup(context: ChannelHandlerContext) {
        guard case .awaitingPeer(let pending) = phase else { return }
        phase = .passthrough
        guard !pending.isEmpty else { return }
        context.fireChannelRead(NIOAny(Self.byteBuffer(pending)))
    }

    // MARK: - TLS contexts

    private static func serverContext(identity: MitmIdentity) throws -> NIOSSLContext {
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: identity.certificateDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: identity.privateKeyDER, format: .der))
        )
        return try NIOSSLContext(configuration: configuration)
    }

    // MARK: - Byte helpers

    private static func byteBuffer(_ text: String) -> ByteBuffer {
        ByteBuffer(bytes: Array(text.utf8))
    }

    private static func byteBuffer(_ bytes: [UInt8]) -> ByteBuffer {
        ByteBuffer(bytes: bytes)
    }
}
