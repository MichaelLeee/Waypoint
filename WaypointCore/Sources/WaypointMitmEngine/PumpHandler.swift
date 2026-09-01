//
//  PumpHandler.swift
//  WaypointMitmEngine
//  Relays decrypted/cleartext bytes from this channel to its peer channel,
//  applying header rewrite rules exactly once per direction: the first
//  complete header block seen is rewritten, everything after streams
//  verbatim. Backpressure: reading pauses while the peer channel is
//  unwritable and resumes on the next writability transition of either
//  side (each direction owns one handler instance; TCP drains both).
//

import NIO

// @unchecked Sendable: handlers are confined to their channel's event loop;
// NIO pipelines require the type to cross @Sendable closure boundaries.
final class PumpHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    enum Direction: Sendable {
        case request
        case response

        var ruleKind: MitmRule.Kind {
            self == .request ? .requestHeader : .responseHeader
        }
    }

    enum RewriteState {
        case pending([UInt8])
        case done
    }

    private let peer: Channel
    private let direction: Direction
    private let rules: [MitmRule]
    /// Host of the session; captured at setup time.
    private let host: String
    /// True when the head block was already consumed and rewritten upstream
    /// by the head handler (plain HTTP request leg).
    private let startsRewritten: Bool
    // Mutated only from this handler's own event loop.
    private var rewriteState: RewriteState

    init(peer: Channel, direction: Direction, rules: [MitmRule], host: String, startsRewritten: Bool) {
        self.peer = peer
        self.direction = direction
        self.rules = rules
        self.host = host
        self.startsRewritten = startsRewritten
        self.rewriteState = startsRewritten ? .done : .pending([])
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = Self.unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        relay(bytes: bytes, context: context)
        if !peer.isWritable {
            context.channel.setOption(ChannelOptions.autoRead, value: false)
                .whenFailure { error in
                    PumpHandler.log("autoRead off failed: \(error)")
                }
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.autoRead, value: peer.isWritable)
            .whenFailure { error in
                PumpHandler.log("autoRead restore failed: \(error)")
            }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        peer.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    private func relay(bytes: [UInt8], context: ChannelHandlerContext) {
        switch rewriteState {
        case .done:
            write(bytes, context: context)
        case .pending(var accumulated):
            accumulated.append(contentsOf: bytes)
            if let blockEnd = accumulated.firstRange(of: HTTPWire.crlfcrlf) {
                let matched = rules.filter { $0.kind == direction.ruleKind && $0.matches(host: host) }
                let block = Array(accumulated[..<blockEnd.upperBound])
                let rewritten = HTTPWire.rewrittenHeaderBlock(block, rules: matched)
                var out = rewritten
                out.append(contentsOf: accumulated[blockEnd.upperBound...])
                rewriteState = .done
                write(out, context: context)
            } else if accumulated.count > 65_536 {
                // No terminator in sight — stop rewriting and pass through.
                rewriteState = .done
                write(accumulated, context: context)
            } else {
                rewriteState = .pending(accumulated)
            }
        }
    }

    private func write(_ bytes: [UInt8], context: ChannelHandlerContext) {
        guard !bytes.isEmpty else { return }
        peer.writeAndFlush(ByteBuffer(bytes: bytes), promise: nil)
    }

    private static func log(_ message: String) {
        // The engine has no logger dependency; misbehaviour surfaces through
        // broken connections rather than crashed event loops.
        #if DEBUG
        print("[WaypointMitmEngine] \(message)")
        #endif
    }
}
