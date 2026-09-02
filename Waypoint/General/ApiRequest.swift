//
//  ApiRequest.swift
//  Waypoint
//  Domain endpoints for the mihomo REST API. The transport (URLSession,
//  auth, WebSocket streams, wire models) lives in the WaypointNetworking
//  package; this facade keeps its historical call-site signatures.
//

import Foundation
import WaypointNetworking

typealias ErrorString = String

@MainActor
final class ApiRequest {
    nonisolated static let client = ApiClient(endpoint: {
        await MainActor.run {
            ApiEndpoint(url: ConfigManager.apiUrl,
                        secret: ConfigManager.shared.overrideSecret ?? ConfigManager.shared.apiSecret,
                        isRunning: ConfigManager.shared.isRunning)
        }
    })

    private static func json<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }
}

// MARK: - REST

extension ApiRequest {
    static func requestConfig() async -> WaypointConfig? {
        do {
            let data = try await client.send("/configs")
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
            try await client.send("/configs", method: "PUT", body: try json(["path": configPath]))
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

    static func updateAllowLan(_ allow: Bool) async -> Bool {
        Logger.log("update allow lan:\(allow)", level: .debug)
        do {
            _ = try await client.send("/configs", method: "PATCH", body: try json(["allow-lan": allow]))
            return true
        } catch {
            return false
        }
    }

    static func updateIPv6(_ enable: Bool) async -> Bool {
        do {
            _ = try await client.send("/configs", method: "PATCH", body: try json(["ipv6": enable]))
            return true
        } catch {
            Logger.log("failed to update ipv6: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    static func updateProxyPort(_ port: Int) async -> Bool {
        do {
            _ = try await client.send("/configs", method: "PATCH", body: try json(["mixed-port": port]))
            return true
        } catch {
            Logger.log("failed to update port: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    static func updateProxyGroup(group: String, selectProxy: String) async -> Bool {
        do {
            _ = try await client.send("/proxies/\(group.encoded)", method: "PUT", body: try json(["name": selectProxy]))
            return true
        } catch {
            return false
        }
    }

    static func requestProxyGroupList() async -> WaypointProxyResp? {
        guard let data = try? await client.send("/proxies") else { return nil }
        return WaypointProxyResp(data)
    }

    static func requestProxyProviderList() async -> WaypointProviderResp? {
        guard let data = try? await client.send("/providers/proxies") else { return nil }
        return try? WaypointProviderResp.decoder.decode(WaypointProviderResp.self, from: data)
    }

    static func getAllProxyList() async -> [WaypointProxyName] {
        guard let proxyInfo = await requestProxyGroupList() else { return [] }
        return proxyInfo.proxiesMap["GLOBAL"]?.all ?? []
    }

    static func getMergedProxyData() async -> WaypointProxyResp? {
        guard var proxyInfo = await requestProxyGroupList(),
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
              let data = try? await client.send(url: url),
              let payload = try? JSONDecoder().decode(DelayPayload.self, from: data) else {
            return 0
        }
        return payload.delay
    }

    static func getRules() async -> [WaypointRule] {
        guard let data = try? await client.send("/rules") else { return [] }
        return WaypointRuleResponse.fromData(data).rules ?? []
    }

    static func healthCheck(proxy: WaypointProviderName) async {
        Logger.log("HeathCheck for \(proxy) started")
        do {
            _ = try await client.send("/providers/proxies/\(proxy.encoded)/healthcheck")
            Logger.log("HeathCheck for \(proxy) finished")
        } catch {
            Logger.log("HeathCheck for \(proxy) failed: \(error.localizedDescription)")
        }
    }

    private static func patch(_ body: [String: String]) async -> Bool {
        do {
            _ = try await client.send("/configs", method: "PATCH", body: try json(body))
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
        guard let data = try? await client.send("/connections") else { return [] }
        return (try? JSONDecoder().decode(WaypointConnectionBaseSnapShot.self, from: data))?.connections ?? []
    }

    static func closeConnection(_ id: String) async {
        _ = try? await client.send("/connections/\(id)", method: "DELETE")
    }

    static func closeAllConnection() async {
        _ = try? await client.send("/connections", method: "DELETE")
    }

    struct AllProviders {
        var proxies = [String]()
        var rules = [String]()
    }

    static func requestExternalProviderNames() async -> AllProviders {
        var providers = AllProviders()

        if let data = try? await client.send("/providers/proxies"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dict = obj["providers"] as? [String: Any] {
            providers.proxies = httpProviderNames(in: dict)
        }

        #if PRO_VERSION
        if let data = try? await client.send("/providers/rules"),
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
            _ = try await client.send(path, method: "PUT")
            return true
        } catch {
            return false
        }
    }

    static func resetFakeIpCache() async {
        _ = try? await client.send("/cache/fakeip/flush", method: "POST")
    }
}
