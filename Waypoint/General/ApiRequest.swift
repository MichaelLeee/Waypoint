//
//  ApiRequest.swift
//  Waypoint
//  mihomo REST + WebSocket client. Async/await + URLSession + Codable —
//  replaces the Alamofire / SwiftyJSON / Starscream implementation.
//

import Foundation

typealias ErrorString = String

enum ApiError: LocalizedError {
    case notRunning
    case invalidURL
    case badStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "mihomo core is not running"
        case .invalidURL:
            return "Invalid API URL"
        case let .badStatus(code, message):
            return message.isEmpty ? "mihomo returned status \(code)" : message
        }
    }
}

struct TrafficSnapshot: Sendable {
    let up: Int
    let down: Int
}

struct LogEntry: Sendable {
    let log: String
    let level: String
}

@MainActor
final class ApiRequest {
    static let shared = ApiRequest()

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 604800
        configuration.timeoutIntervalForResource = 604800
        configuration.httpMaximumConnectionsPerHost = 100
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    // MARK: - Auth & transport

    private static var authHeader: [String: String] {
        let secret = ConfigManager.shared.overrideSecret ?? ConfigManager.shared.apiSecret
        return secret.isEmpty ? [:] : ["Authorization": "Bearer \(secret)"]
    }

    private func url(for path: String) throws -> URL {
        guard let url = URL(string: ConfigManager.apiUrl + path) else {
            throw ApiError.invalidURL
        }
        return url
    }

    @discardableResult
    private func send(url: URL, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard ConfigManager.shared.isRunning else { throw ApiError.notRunning }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in Self.authHeader {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(MihomoError.self, from: data))?.message ?? ""
            throw ApiError.badStatus(http.statusCode, message)
        }
        return data
    }

    @discardableResult
    private func send(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        try await send(url: try url(for: path), method: method, body: body)
    }

    private func json<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }
}

private struct MihomoError: Decodable {
    let message: String
}

// MARK: - REST

extension ApiRequest {
    static func requestConfig() async -> WaypointConfig? {
        do {
            let data = try await shared.send("/configs")
            return try JSONDecoder().decode(WaypointConfig.self, from: data)
        } catch {
            Logger.log(error.localizedDescription)
            return nil
        }
    }

    static func requestConfigUpdate(configName: String) async throws {
        let path = await effectiveConfigPath(for: configName)
        try await requestConfigUpdate(configPath: path)
    }

    static func requestConfigUpdate(configPath: String) async throws {
        do {
            try await shared.send("/configs", method: "PUT", body: try shared.json(["path": configPath]))
            ConfigManager.shared.isRunning = true
        } catch {
            Logger.log(error.localizedDescription)
            throw error
        }
    }

    static func updateOutBoundMode(_ mode: WaypointProxyMode) async -> Bool {
        await patch(["mode": mode.rawValue])
    }

    static func updateLogLevel(_ level: WaypointLogLevel) async -> Bool {
        await patch(["log-level": level.rawValue])
    }

    static func updateAllowLan(_ allow: Bool) async {
        Logger.log("update allow lan:\(allow)", level: .debug)
        _ = try? await shared.send("/configs", method: "PATCH", body: try shared.json(["allow-lan": allow]))
    }

    static func updateIPv6(_ enable: Bool) async {
        _ = try? await shared.send("/configs", method: "PATCH", body: try shared.json(["ipv6": enable]))
    }

    static func updateProxyPort(_ port: Int) async {
        _ = try? await shared.send("/configs", method: "PATCH", body: try shared.json(["mixed-port": port]))
    }

    static func updateProxyGroup(group: String, selectProxy: String) async -> Bool {
        do {
            _ = try await shared.send("/proxies/\(group.encoded)", method: "PUT", body: try shared.json(["name": selectProxy]))
            return true
        } catch {
            return false
        }
    }

    static func requestProxyGroupList() async -> WaypointProxyResp? {
        guard let data = try? await shared.send("/proxies") else { return nil }
        return WaypointProxyResp(data)
    }

    static func requestProxyProviderList() async -> WaypointProviderResp? {
        guard let data = try? await shared.send("/providers/proxies") else { return nil }
        return try? WaypointProviderResp.decoder.decode(WaypointProviderResp.self, from: data)
    }

    static func getAllProxyList() async -> [WaypointProxyName] {
        guard let proxyInfo = await requestProxyGroupList() else { return [] }
        return proxyInfo.proxiesMap["GLOBAL"]?.all ?? []
    }

    // Sequential awaits (not async let): the response models are non-Sendable
    // and must stay on the main actor.
    static func getMergedProxyData() async -> WaypointProxyResp? {
        guard let proxyInfo = await requestProxyGroupList(),
              let providerResp = await requestProxyProviderList() else {
            return nil
        }
        proxyInfo.updateProvider(providerResp)
        return proxyInfo
    }

    static func getProxyDelay(proxyName: String) async -> Int {
        guard var components = URLComponents(string: ConfigManager.apiUrl + "/proxies/\(proxyName.encoded)/delay") else {
            return 0
        }
        components.queryItems = [
            URLQueryItem(name: "timeout", value: "5000"),
            URLQueryItem(name: "url", value: Settings.benchMarkUrl),
        ]
        struct DelayPayload: Decodable { let delay: Int }
        guard let url = components.url,
              let data = try? await shared.send(url: url),
              let payload = try? JSONDecoder().decode(DelayPayload.self, from: data) else {
            return 0
        }
        return payload.delay
    }

    static func getRules() async -> [WaypointRule] {
        guard let data = try? await shared.send("/rules") else { return [] }
        return WaypointRuleResponse.fromData(data).rules ?? []
    }

    static func healthCheck(proxy: WaypointProviderName) async {
        Logger.log("HeathCheck for \(proxy) started")
        do {
            _ = try await shared.send("/providers/proxies/\(proxy.encoded)/healthcheck")
            Logger.log("HeathCheck for \(proxy) finished")
        } catch {
            Logger.log("HeathCheck for \(proxy) failed: \(error.localizedDescription)")
        }
    }

    private static func patch(_ body: [String: String]) async -> Bool {
        do {
            _ = try await shared.send("/configs", method: "PATCH", body: try shared.json(body))
            return true
        } catch {
            return false
        }
    }

    private static func effectiveConfigPath(for configName: String) async -> String {
        await withCheckedContinuation { continuation in
            ConfigManager.getEffectiveConfigPath(configName: configName) { path in
                continuation.resume(returning: path)
            }
        }
    }
}

// MARK: - Connections

extension ApiRequest {
    static func getConnections() async -> [WaypointConnectionBaseSnapShot.Connection] {
        guard let data = try? await shared.send("/connections") else { return [] }
        return (try? JSONDecoder().decode(WaypointConnectionBaseSnapShot.self, from: data))?.connections ?? []
    }

    static func closeConnection(_ id: String) async {
        _ = try? await shared.send("/connections/\(id)", method: "DELETE")
    }

    static func closeAllConnection() async {
        _ = try? await shared.send("/connections", method: "DELETE")
    }

    struct AllProviders {
        var proxies = [String]()
        var rules = [String]()
    }

    static func requestExternalProviderNames() async -> AllProviders {
        var providers = AllProviders()

        if let data = try? await shared.send("/providers/proxies"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dict = obj["providers"] as? [String: Any] {
            providers.proxies = httpProviderNames(in: dict)
        }

        #if PRO_VERSION
        if let data = try? await shared.send("/providers/rules"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dict = obj["providers"] as? [String: Any] {
            providers.rules = httpProviderNames(in: dict)
        }
        #endif

        return providers
    }

    private static func httpProviderNames(in providers: [String: Any]) -> [String] {
        providers.compactMap { key, value in
            let vehicleType = (value as? [String: Any])?["vehicleType"] as? String
            return vehicleType == "HTTP" ? key : nil
        }
    }

    enum ProviderType {
        case proxy
        case rule
    }

    static func updateProvider(name: String, type: ProviderType) async -> Bool {
        let path: String
        switch type {
        case .proxy: path = "/providers/proxies/\(name.encoded)"
        case .rule: path = "/providers/rules/\(name.encoded)"
        }
        do {
            _ = try await shared.send(path, method: "PUT")
            return true
        } catch {
            return false
        }
    }

    static func resetFakeIpCache() async {
        _ = try? await shared.send("/cache/fakeip/flush", method: "POST")
    }
}

// MARK: - Streams

struct MemorySnapshot: Sendable {
    let inuse: Int
    let osLimit: Int?
}

struct ConnectionsWireMetadata: Sendable, Decodable {
    let network: String
    let type: String
    let sourceIP: String
    let destinationIP: String
    let sourcePort: String
    let destinationPort: String
    let host: String
    let chains: [String]
    let rule: String
    let rulePayload: String
    let start: Date
    let upload: Int
    let download: Int
    let id: String
    let processPath: String?

    var displayHost: String { host.isEmpty ? destinationIP : host }
    var displayName: String? { processPath?.isEmpty == false ? processPath?.components(separatedBy: "/").last : nil }

    enum CodingKeys: String, CodingKey {
        case network, type, sourceIP, destinationIP, sourcePort, destinationPort
        case host, chains, rule, rulePayload, start, upload, download, id
        case metadata
        case processPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        network = try container.decode(String.self, forKey: .network)
        type = try container.decode(String.self, forKey: .type)
        sourceIP = try container.decode(String.self, forKey: .sourceIP)
        destinationIP = try container.decode(String.self, forKey: .destinationIP)
        sourcePort = try container.decode(String.self, forKey: .sourcePort)
        destinationPort = try container.decode(String.self, forKey: .destinationPort)
        host = try container.decode(String.self, forKey: .host)
        chains = try container.decode([String].self, forKey: .chains)
        rule = try container.decode(String.self, forKey: .rule)
        rulePayload = try container.decodeIfPresent(String.self, forKey: .rulePayload) ?? ""
        start = try container.decode(Date.self, forKey: .start)
        upload = try container.decode(Int.self, forKey: .upload)
        download = try container.decode(Int.self, forKey: .download)
        id = try container.decode(String.self, forKey: .id)
        let metadataContainer = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .metadata)
        processPath = try metadataContainer.decodeIfPresent(String.self, forKey: .processPath)
    }
}

struct ConnectionsSnapshot: Sendable {
    let downloadTotal: Int
    let uploadTotal: Int
    let connections: [ConnectionsWireMetadata]
}

extension ApiRequest {
    func memoryStream() -> AsyncStream<MemorySnapshot> {
        stream("/memory") { text in
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let inuse = obj["inuse"] as? Int else { return nil }
            return MemorySnapshot(inuse: inuse, osLimit: obj["oslimit"] as? Int)
        }
    }

    func connectionsStream() -> AsyncStream<ConnectionsSnapshot> {
        stream("/connections") { text in
            guard let data = text.data(using: .utf8) else { return nil }
            struct Payload: Decodable {
                let downloadTotal: Int
                let uploadTotal: Int
                let connections: [ConnectionsWireMetadata]?
            }
            guard let payload = try? Self.connectionsDecoder.decode(Payload.self, from: data) else {
                return nil
            }
            return ConnectionsSnapshot(
                downloadTotal: payload.downloadTotal,
                uploadTotal: payload.uploadTotal,
                connections: payload.connections ?? []
            )
        }
    }

    // Immutable decoder, used from the stream's @Sendable transform closure.
    nonisolated private static let connectionsDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(DateFormatter.js)
        return decoder
    }()
}

extension ApiRequest {
    static func webSocketRequest(path: String) throws -> URLRequest {
        guard let url = URL(string: ConfigManager.apiUrl + path) else {
            throw ApiError.invalidURL
        }
        var request = URLRequest(url: url)
        for (key, value) in authHeader {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    func trafficStream() -> AsyncStream<TrafficSnapshot> {
        stream("/traffic") { text in
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let up = obj["up"] as? Int,
                  let down = obj["down"] as? Int else { return nil }
            return TrafficSnapshot(up: up, down: down)
        }
    }

    func logStream() -> AsyncStream<LogEntry> {
        stream("/logs?level=\(ConfigManager.selectLoggingApiLevel.rawValue)") { text in
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let log = obj["payload"] as? String ?? ""
            let level = obj["type"] as? String ?? "info"
            return LogEntry(log: log, level: level)
        }
    }

    private func stream<T: Sendable>(
        _ path: String,
        parse: @escaping @Sendable (String) -> T?
    ) -> AsyncStream<T> {
        AsyncStream { continuation in
            let task = Task {
                await self.runStream(path: path, continuation: continuation, parse: parse)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream<T: Sendable>(
        path: String,
        continuation: AsyncStream<T>.Continuation,
        parse: @escaping @Sendable (String) -> T?
    ) async {
        var retryDelay: TimeInterval = 1
        while !Task.isCancelled {
            do {
                try await connect(path: path, continuation: continuation, parse: parse)
                retryDelay = 1
            } catch {
                // connection failed or dropped; back off and retry below
            }
            guard !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            retryDelay = min(retryDelay * 2, 30)
        }
        continuation.finish()
    }

    private func connect<T: Sendable>(
        path: String,
        continuation: AsyncStream<T>.Continuation,
        parse: @escaping @Sendable (String) -> T?
    ) async throws {
        let url = try url(for: path)
        var request = URLRequest(url: url)
        for (key, value) in Self.authHeader {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        while !Task.isCancelled {
            let message = try await socket.receive()
            if case let .string(text) = message, let value = parse(text) {
                continuation.yield(value)
            }
        }
    }
}
