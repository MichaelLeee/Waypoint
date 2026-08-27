//
//  MitmProxyServer.swift
//  Waypoint
//  Local interception engine mihomo forwards matched hosts through as an HTTP
//  proxy entry. Terminates CONNECT tunnels with locally issued leaf certs,
//  opens its own TLS session to the real host, and applies header-level
//  RewriteRules in between. Implemented on BSD sockets + SecureTransport
//  because Network.framework cannot attach a TLS server context to an
//  already-established tunnel. Uses deprecated-but-functional APIs by design.
//

import Darwin.C
import Foundation
import Security

// @unchecked: lifecycle state is touched only from the main thread; tunnel
// sessions are owned by their own threads.
final class MitmProxyServer: @unchecked Sendable {
    static let shared = MitmProxyServer()

    static let portRangeStart: UInt16 = 6153
    static let portRangeEnd: UInt16 = 6199

    struct EngineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Port the engine bound after a successful `start`; 0 when stopped.
    private(set) var port: UInt16 = 0

    private var listenFD: Int32 = -1
    private var running = false
    private var activeRules: [RewriteRule] = []

    private init() {}

    // MARK: - Lifecycle

    @discardableResult
    func start(rules newRules: [RewriteRule]) throws -> UInt16 {
        assert(Thread.isMainThread)
        guard Settings.mitmEnabled else { return 0 }
        if running {
            activeRules = newRules
            return port
        }

        signal(SIGPIPE, SIG_IGN)

        guard let (fd, boundPort) = listenOnFreePort() else {
            throw EngineError(message: NSLocalizedString(
                "No free port available for the intercept proxy (\(Self.portRangeStart)–\(Self.portRangeEnd)).",
                comment: ""
            ))
        }
        listenFD = fd
        port = boundPort
        activeRules = newRules
        running = true

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "Waypoint MITM accept"
        thread.start()
        return boundPort
    }

    func stop() {
        assert(Thread.isMainThread)
        guard running else { return }
        running = false
        activeRules = []
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        port = 0
    }

    var isRunning: Bool { running }

    /// Starts the engine when MITM is enabled (and syncs the bound port into
    /// settings so config injection matches), no-op otherwise. Call before any
    /// effective-config generation. Returns the bound port (0 = not running).
    @discardableResult
    static func ensureRunning() -> UInt16 {
        dispatchPrecondition(condition: .onQueue(.main))
        guard Settings.mitmEnabled else {
            shared.stop()
            return 0
        }
        do {
            let boundPort = try shared.start(rules: RewriteRuleStore.load())
            if boundPort > 0, Settings.mitmEnginePort != Int(boundPort) {
                Settings.mitmEnginePort = Int(boundPort)
            }
            return boundPort
        } catch {
            Logger.log("MITM engine failed to start: \(error.localizedDescription)", level: .error)
            return 0
        }
    }

    private func listenOnFreePort() -> (Int32, UInt16)? {
        var candidate = Self.portRangeStart
        while candidate <= Self.portRangeEnd {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = candidate.bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

            let bindResult = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult == 0, listen(fd, 16) == 0 {
                return (fd, candidate)
            }
            close(fd)
            candidate += 1
        }
        return nil
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                if running { usleep(50_000) } else { break }
                continue
            }
            let session = TunnelSession(clientFD: clientFD, rules: activeRules)
            let thread = Thread { session.run() }
            thread.name = "Waypoint MITM tunnel"
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }
}

// MARK: - Tunnel session

/// One intercepted client connection, owned by its own thread.
private final class TunnelSession: @unchecked Sendable {
    private let clientFD: Int32
    private let rules: [RewriteRule]

    private var downstreamTLS: SSLContext?
    private var upstreamTLS: SSLContext?

    private var host = ""
    private var upstreamPort: UInt16 = 443
    private var upstreamConnectionFD: Int32 = -1
    private var requestHeadersRewritten = false
    private var responseHeadersRewritten = false

    init(clientFD: Int32, rules: [RewriteRule]) {
        self.clientFD = clientFD
        self.rules = rules
    }

    func run() {
        defer { teardown() }

        guard let head = receiveHeadBlock() else { return }
        guard let requestLine = String(
            bytes: headLine(of: head),
            encoding: .isoLatin1
        ) else { return }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let target = String(parts[1])

        let establishedTarget: (host: String, port: UInt16)?
        if method == "CONNECT" {
            establishedTarget = parseAuthority(target, defaultPort: 443)
        } else if target.lowercased().hasPrefix("http://") {
            let netloc = target.dropFirst("http://".count).split(separator: "/").first.map(String.init) ?? ""
            establishedTarget = parseAuthority(netloc, defaultPort: 80)
        } else if let headerHost = Self.headerValue(in: head, name: "Host") {
            establishedTarget = parseAuthority(headerHost, defaultPort: 80)
        } else {
            establishedTarget = nil
        }
        guard let destination = establishedTarget, !destination.host.isEmpty else { return }
        host = destination.host
        upstreamPort = destination.port

        if ruleApplies(kind: .reject) {
            respond(method == "CONNECT"
                ? "HTTP/1.1 403 Blocked by Waypoint\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }

        guard let upstreamFD = Raw.connect(host: host, port: upstreamPort) else { return }
        upstreamConnectionFD = upstreamFD
        Raw.configureConnected(upstreamFD)

        var payloadCarriedByThisSession: [UInt8] = []
        if method == "CONNECT" {
            respond("HTTP/1.1 200 Connection established\r\n\r\n")
            guard handshakeDownstreamTLS(), handshakeUpstreamTLS(upstreamFD: upstreamFD) else { return }
        } else {
            // Plain HTTP — this session already consumed the head block;
            // replay it (rewritten if needed) as the first upstream bytes.
            let leftoverIndex = head.firstRange(of: Array("\r\n\r\n".utf8))?.upperBound ?? head.count
            payloadCarriedByThisSession = Array(head[leftoverIndex...])
            requestHeadersRewritten = true // head block handled below explicitly
        }

        // Plain HTTP requests keep cleartext legs; CONNECT runs two TLS legs.
        let plainHTTP = method != "CONNECT"

        var rewrittenHead: [UInt8]? = nil
        if plainHTTP {
            let matched = rules.filter { $0.kind == .requestHeader && $0.matches(host: host) }
            rewrittenHead = Self.rewrittenHeaderBlock(head, rules: matched)
        }

        var fromClient = rewrittenHead ?? []
        fromClient.append(contentsOf: payloadCarriedByThisSession)
        relay(downstreamFD: clientFD,
              upstreamFD: upstreamFD,
              plainDownstream: plainHTTP,
              plainUpstream: plainHTTP,
              buffered: &fromClient)
    }

    // MARK: - Pump

    private enum ReadOutcome {
        case got([UInt8])
        case idle      // EAGAIN / TLSWouldBlock without progress
        case closed
    }

    private func relay(downstreamFD: Int32,
                       upstreamFD: Int32,
                       plainDownstream: Bool,
                       plainUpstream: Bool,
                       buffered: inout [UInt8]) {
        var upstreamBuffered: [UInt8] = []

        func flush(_ data: inout [UInt8], to fd: Int32, plain: Bool) -> Bool {
            guard !data.isEmpty else { return true }
            if plain {
                guard Raw.send(fd, data, data.count) else { return false }
            } else {
                guard let ssl = peerContext(for: fd), Raw.sslWrite(ssl, data) else { return false }
            }
            data.removeAll(keepingCapacity: true)
            return true
        }

        defer {
            _ = flush(&buffered, to: upstreamFD, plain: plainUpstream)
            _ = flush(&upstreamBuffered, to: downstreamFD, plain: plainDownstream)
        }
        guard flush(&buffered, to: upstreamFD, plain: plainUpstream) else { return }

        while true {
            var polls = [
                pollfd(fd: downstreamFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: upstreamFD, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&polls, 2, 90_000)
            guard ready > 0 else {
                if ready == 0 { continue }
                return
            }

            if polls[0].revents != 0 {
                switch read(from: downstreamFD, plain: plainDownstream) {
                case .closed: return
                case .idle: break
                case .got(var chunk):
                    guard append(chunk: &chunk, into: &buffered, direction: .request) else { return }
                    guard flush(&buffered, to: upstreamFD, plain: plainUpstream) else { return }
                }
            }
            if polls[1].revents != 0 {
                switch read(from: upstreamFD, plain: plainUpstream) {
                case .closed: return
                case .idle: break
                case .got(var chunk):
                    guard append(chunk: &chunk, into: &upstreamBuffered, direction: .response) else { return }
                    guard flush(&upstreamBuffered, to: downstreamFD, plain: plainDownstream) else { return }
                }
            }
        }
    }

    private enum Direction {
        case request
        case response
    }

    /// Buffers a chunk, applying header rewrite exactly once per direction
    /// once a complete header block is visible; bodies stream verbatim after.
    private func append(chunk: inout [UInt8], into buffer: inout [UInt8], direction: Direction) -> Bool {
        buffer.append(contentsOf: chunk)
        chunk.removeAll()

        let done = direction == .request ? requestHeadersRewritten : responseHeadersRewritten
        guard !done else { return true }

        guard let blockEnd = buffer.firstRange(of: Array("\r\n\r\n".utf8)) else {
            return buffer.count < 65_536
        }
        let kind: RewriteRule.Kind = direction == .request ? .requestHeader : .responseHeader
        let matched = rules.filter { $0.kind == kind && $0.matches(host: host) }
        let block = Array(buffer[..<blockEnd.upperBound])
        let rewritten = Self.rewrittenHeaderBlock(block, rules: matched)
        buffer.replaceSubrange(0 ..< blockEnd.upperBound, with: rewritten)
        if direction == .request {
            requestHeadersRewritten = true
        } else {
            responseHeadersRewritten = true
        }
        return true
    }

    private func read(from fd: Int32, plain: Bool) -> ReadOutcome {
        if !plain, let ssl = (fd == clientFD ? downstreamTLS : upstreamTLS) {
            var storage = [UInt8](repeating: 0, count: 16_384)
            var processed = 0
            let status = storage.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return errSSLClosedAbort }
                return SSLRead(ssl, base, raw.count, &processed)
            }
            switch status {
            case noErr, errSSLWouldBlock:
                return processed > 0 ? .got(Array(storage[0 ..< processed])) : .idle
            case errSSLClosedGraceful, errSSLClosedNoNotify, errSSLClosedAbort:
                return .closed
            default:
                return .closed
            }
        }

        var storage = [UInt8](repeating: 0, count: 16_384)
        let received = storage.withUnsafeMutableBytes { raw -> Int in
            recv(fd, raw.baseAddress, raw.count, 0)
        }
        if received > 0 { return .got(Array(storage[0 ..< received])) }
        if received == 0 { return .closed }
        return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? .idle : .closed
    }

    private func peerContext(for fd: Int32) -> SSLContext? {
        fd == clientFD ? downstreamTLS : upstreamTLS
    }

    // MARK: - TLS setup

    private func handshakeDownstreamTLS() -> Bool {
        guard let leaf = try? MitmCertificateAuthority.shared.identity(forHost: host),
              let context = SSLCreateContext(nil, .serverSide, .streamType)
        else { return false }
        SSLSetCertificate(context, [leaf.certificate, leaf.privateKey] as CFArray)

        guard Raw.attachIOCallbacks(context, read: Raw.sslReadIO, write: Raw.sslWriteIO) else { return false }
        SSLSetConnection(context, UnsafeMutableRawPointer(bitPattern: UInt(clientFD)))
        return SSLHandshake(context) == noErr
    }

    private func handshakeUpstreamTLS(upstreamFD: Int32) -> Bool {
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else { return false }
        SSLSetPeerDomainName(context, host, host.utf8.count)

        guard Raw.attachIOCallbacks(context, read: Raw.sslReadIO, write: Raw.sslWriteIO) else { return false }
        SSLSetConnection(context, UnsafeMutableRawPointer(bitPattern: UInt(upstreamFD)))
        if SSLHandshake(context) != noErr { return false }
        upstreamTLS = context
        return true
    }

    // MARK: - Parsing helpers

    private func respond(_ text: String) {
        let data = Data(text.utf8)
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = Raw.send(clientFD, base, raw.count)
        }
    }

    private func ruleApplies(kind: RewriteRule.Kind) -> Bool {
        rules.contains { $0.kind == kind && $0.matches(host: host) }
    }

    private func parseAuthority(_ authority: String, defaultPort: UInt16) -> (String, UInt16)? {
        var text = authority.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if let atSign = text.lastIndex(of: "@") {
            text = String(text[text.index(after: atSign)...])
        }
        if text.lowercased().hasPrefix("http://") {
            text = String(text.dropFirst("http://".count))
        }
        let cleaned = text.split(separator: "/").first.map(String.init) ?? text
        guard !cleaned.isEmpty else { return nil }
        if let colon = cleaned.firstIndex(of: ":"), !cleaned.hasSuffix(":") {
            let maybePort = UInt16(cleaned[cleaned.index(after: colon)...])
            let hostPart = String(cleaned[..<colon]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let portNumber = maybePort {
                return (hostPart.isEmpty ? "" : hostPart, portNumber)
            }
        }
        let hostPart = cleaned.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return (hostPart, defaultPort)
    }

    private static func rewrittenHeaderBlock(_ block: [UInt8], rules: [RewriteRule]) -> [UInt8] {
        guard let text = String(bytes: block, encoding: .isoLatin1) else { return block }
        var lines = text.components(separatedBy: "\r\n")
        guard lines.count > 1 else { return block }

        for rule in rules where !rule.headerKey.isEmpty {
            let prefix = "\(rule.headerKey.lowercased()):"
            for index in lines.indices.reversed()
            where index != lines.startIndex && lines[index].lowercased().hasPrefix(prefix) {
                lines.removeSubrange(index ... index)
            }
            if !rule.headerValue.isEmpty {
                lines.append("\(rule.headerKey): \(rule.headerValue)")
            }
        }
        let rebuilt = lines.joined(separator: "\r\n") + "\r\n\r\n"
        return Array(rebuilt.utf8)
    }

    private static func headerValue(in bytes: [UInt8], name: String) -> String? {
        guard let text = String(bytes: bytes, encoding: .isoLatin1) else { return nil }
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2,
                  fields[0].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased()
            else { continue }
            return String(fields[1])
        }
        return nil
    }

    private func headLine(of bytes: [UInt8]) -> [UInt8] {
        guard let newline = bytes.firstRange(of: Array("\r\n".utf8)) else { return bytes }
        return Array(bytes[..<newline.lowerBound])
    }

    private func receiveHeadBlock() -> [UInt8]? {
        var buffer = [UInt8]()
        var storage = [UInt8](repeating: 0, count: 4_096)
        let terminator = Array("\r\n\r\n".utf8)
        while buffer.count < 32_768 {
            let received = storage.withUnsafeMutableBytes { raw -> Int in
                recv(clientFD, raw.baseAddress, raw.count, 0)
            }
            if received <= 0 {
                if received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                    var pollItem = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
                    guard poll(&pollItem, 1, 30_000) > 0 else { return nil }
                    continue
                }
                return nil
            }
            buffer.append(contentsOf: storage[0 ..< received])
            if buffer.firstRange(of: terminator) != nil {
                return buffer
            }
        }
        return nil
    }

    private func teardown() {
        if let ssl = downstreamTLS { SSLClose(ssl) }
        if let ssl = upstreamTLS { SSLClose(ssl) }
        close(clientFD)
        if upstreamConnectionFD >= 0 { close(upstreamConnectionFD) }
    }
}

// MARK: - Raw socket + SecureTransport glue

private enum Raw {
    // macOS 26 SDK headers no longer declare SSLSetIOCallbacks; the symbol is
    // still exported by Security.framework, so resolve it at load time.
    private static let setIOCallbacksFn: (@convention(c) (SSLContext?, SSLReadFunc?, SSLWriteFunc?) -> OSStatus)? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Versions/A/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SSLSetIOCallbacks")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (SSLContext?, SSLReadFunc?, SSLWriteFunc?) -> OSStatus).self)
    }()

    static func attachIOCallbacks(_ context: SSLContext, read: SSLReadFunc, write: SSLWriteFunc) -> Bool {
        guard let fn = setIOCallbacksFn else { return false }
        return fn(context, read, write) == noErr
    }

    static func configureConnected(_ fd: Int32) {
        var value: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &value, socklen_t(MemoryLayout<Int32>.size))

        // Sockets must be non-blocking so SecureTransport reports
        // errSSLWouldBlock instead of stalling the poll loop.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    static func send(_ fd: Int32, _ bytes: [UInt8], _ count: Int) -> Bool {
        bytes.withUnsafeBufferPointer { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return send(fd, base, min(count, buffer.count))
        }
    }

    static func send(_ fd: Int32, _ bytes: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        var base = bytes
        var remaining = count
        while remaining > 0 {
            let sent = Darwin.send(fd, base, remaining, 0)
            if sent > 0 {
                base += sent
                remaining -= sent
                continue
            }
            if sent < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                var pollItem = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&pollItem, 1, 30_000) > 0 else { return false }
                continue
            }
            return false
        }
        return true
    }

    static func connect(host: String, port: UInt16) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "\(port)", &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(first) }

        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            let fd = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
            if fd >= 0 {
                if Darwin.connect(fd, current.pointee.ai_addr, current.pointee.ai_addrlen) == 0 {
                    return fd
                }
                close(fd)
            }
            node = current.pointee.ai_next
        }
        return nil
    }

    static func sslWrite(_ context: SSLContext, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { buffer -> Bool in
            guard var base = buffer.baseAddress else { return false }
            var remaining = buffer.count
            while remaining > 0 {
                var processed = 0
                let status = SSLWrite(context, base, remaining, &processed)
                if status == noErr && processed == 0 { return false }
                if processed > 0 {
                    base += processed
                    remaining -= processed
                    if remaining == 0 { return true }
                    continue
                }
                if status == errSSLWouldBlock {
                    usleep(2_000)
                    continue
                }
                return false
            }
            return remaining == 0
        }
    }

    static let sslReadIO: SSLReadFunc = { connection, data, dataLength in
        // SSLConnectionRef carries the fd we passed to SSLSetConnection as its
        // pointer value, not as pointee.
        let fd = Int32(truncatingIfNeeded: Int(bitPattern: connection))
        let wanted = dataLength.pointee
        var offset = 0
        while offset < wanted {
            let received = recv(fd, data.advanced(by: offset), wanted - offset, 0)
            if received > 0 {
                offset += received
                dataLength.pointee = offset
                return offset == wanted ? noErr : errSSLWouldBlock
            }
            if received == 0 {
                dataLength.pointee = offset
                return errSSLClosedGraceful
            }
            if errno == EINTR { continue }
            dataLength.pointee = offset
            if errno == EAGAIN || errno == EWOULDBLOCK { return errSSLWouldBlock }
            return errSSLClosedAbort
        }
        dataLength.pointee = wanted
        return noErr
    }

    static let sslWriteIO: SSLWriteFunc = { connection, data, dataLength in
        let fd = Int32(truncatingIfNeeded: Int(bitPattern: connection))
        let wanted = dataLength.pointee
        var offset = 0
        while offset < wanted {
            let sent = Darwin.send(fd, data.advanced(by: offset), wanted - offset, 0)
            if sent > 0 {
                offset += sent
                dataLength.pointee = offset
                return offset == wanted ? noErr : errSSLWouldBlock
            }
            if sent == 0 {
                dataLength.pointee = offset
                return errSSLClosedAbort
            }
            if errno == EINTR { continue }
            dataLength.pointee = offset
            if errno == EAGAIN || errno == EWOULDBLOCK { return errSSLWouldBlock }
            return errSSLClosedAbort
        }
        dataLength.pointee = offset
        return noErr
    }
}
