//
//  ApiClient+Endpoints.swift
//  Waypoint
//  Domain endpoints for the mihomo REST API, layered on the WaypointNetworking
//  transport actor. The shared instance re-reads its endpoint (URL, secret,
//  running flag) on every request via the endpointProvider closure, so it
//  stays correct across config reloads without any manual refresh.
//
//  Domain models stay in the app target: WaypointConfig is gated behind the
//  PRO_VERSION build flag and the connection models are NSImage-bound, so
//  they cannot move into WaypointNetworking yet.
//

import Foundation
import WaypointNetworking

typealias ErrorString = String

extension ApiClient {
    static let shared = ApiClient(endpoint: {
        await MainActor.run {
            ApiEndpoint(url: ConfigManager.apiUrl,
                        secret: ConfigManager.shared.overrideSecret ?? ConfigManager.shared.apiSecret,
                        isRunning: ConfigManager.shared.isRunning)
        }
    })

    private func json<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }
}

// MARK: - Configs

extension ApiClient {
    func requestConfig() async -> WaypointConfig? {
        do {
            let data = try await send("/configs")
            return try JSONDecoder().decode(WaypointConfig.self, from: data)
        } catch {
            Logger.log(error.localizedDescription)
            return nil
        }
    }

    /// PUTs the config file path. Side effects that used to live here
    /// (marking the core running, re-applying runtime PATCHes) belong to
    /// the caller after this returns successfully.
    func requestConfigUpdate(configName: String) async throws {
        let path = await effectiveConfigPath(for: configName)
        try await requestConfigUpdate(configPath: path)
    }

    func requestConfigUpdate(configPath: String) async throws {
        try await send("/configs", method: "PUT", body: try json(["path": configPath]))
    }

    /// A file reload resets every runtime PATCH (mode, log level, allow-lan,
    /// IPv6, port) back to the values stored in the file; call this after a
    /// successful reload to re-apply the app's runtime state on top of it.
    func reapplyRuntimeSettings() async {
        let mode = await ConfigManager.selectOutBoundMode
        _ = await updateOutBoundMode(mode)
        _ = await updateLogLevel(ConfigManager.selectLoggingApiLevel)
        let allowLan = await ConfigManager.allowConnectFromLan
        _ = await updateAllowLan(allowLan)
        _ = await updateIPv6(Settings.enableIPV6)
        if Settings.proxyPort > 0 {
            _ = await updateProxyPort(Settings.proxyPort)
        }
    }

    func updateOutBoundMode(_ mode: WaypointProxyMode) async -> Bool {
        await patch(["mode": mode.rawValue])
    }

    func updateLogLevel(_ level: WaypointLogLevel) async -> Bool {
        await patch(["log-level": level.rawValue])
    }

    func updateAllowLan(_ allow: Bool) async -> Bool {
        Logger.log("update allow lan:\(allow)", level: .debug)
        do {
            _ = try await send("/configs", method: "PATCH", body: try json(["allow-lan": allow]))
            return true
        } catch {
            return false
        }
    }

    func updateIPv6(_ enable: Bool) async -> Bool {
        do {
            _ = try await send("/configs", method: "PATCH", body: try json(["ipv6": enable]))
            return true
        } catch {
            Logger.log("failed to update ipv6: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    func updateProxyPort(_ port: Int) async -> Bool {
        do {
            _ = try await send("/configs", method: "PATCH", body: try json(["mixed-port": port]))
            return true
        } catch {
            Logger.log("failed to update port: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    private func patch(_ body: [String: String]) async -> Bool {
        do {
            _ = try await send("/configs", method: "PATCH", body: try json(body))
            return true
        } catch {
            return false
        }
    }

    private func effectiveConfigPath(for configName: String) async -> String {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                ConfigManager.getEffectiveConfigPath(configName: configName) { path in
                    continuation.resume(returning: path)
                }
            }
        }
    }
}

// MARK: - Proxies

extension ApiClient {
    func updateProxyGroup(group: String, selectProxy: String) async -> Bool {
        do {
            _ = try await send("/proxies/\(group.encoded)", method: "PUT", body: try json(["name": selectProxy]))
            return true
        } catch {
            return false
        }
    }

    func requestProxyGroupList() async -> WaypointProxyResp? {
        guard let data = try? await send("/proxies") else { return nil }
        return WaypointProxyResp(data)
    }

    func requestProxyProviderList() async -> WaypointProviderResp? {
        guard let data = try? await send("/providers/proxies") else { return nil }
        return try? WaypointProviderResp.decoder.decode(WaypointProviderResp.self, from: data)
    }

    func getAllProxyList() async -> [WaypointProxyName] {
        guard let proxyInfo = await requestProxyGroupList() else { return [] }
        return proxyInfo.proxiesMap["GLOBAL"]?.all ?? []
    }

    func getMergedProxyData() async -> WaypointProxyResp? {
        guard var proxyInfo = await requestProxyGroupList(),
              let providerResp = await requestProxyProviderList() else {
            return nil
        }
        proxyInfo.updateProvider(providerResp)
        return proxyInfo
    }

    func getProxyDelay(proxyName: String) async -> Int {
        let baseURL = await MainActor.run { ConfigManager.apiUrl }
        guard var components = URLComponents(string: baseURL + "/proxies/\(proxyName.encoded)/delay") else {
            return 0
        }
        components.queryItems = [
            URLQueryItem(name: "timeout", value: "5000"),
            URLQueryItem(name: "url", value: Settings.benchMarkUrl),
        ]
        struct DelayPayload: Decodable { let delay: Int }
        guard let url = components.url,
              let data = try? await send(url: url),
              let payload = try? JSONDecoder().decode(DelayPayload.self, from: data) else {
            return 0
        }
        return payload.delay
    }

    func healthCheck(proxy: WaypointProviderName) async {
        Logger.log("HeathCheck for \(proxy) started")
        do {
            _ = try await send("/providers/proxies/\(proxy.encoded)/healthcheck")
            Logger.log("HeathCheck for \(proxy) finished")
        } catch {
            Logger.log("HeathCheck for \(proxy) failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Rules

extension ApiClient {
    func getRules() async -> [WaypointRule] {
        guard let data = try? await send("/rules") else { return [] }
        return WaypointRuleResponse.fromData(data).rules ?? []
    }
}

// MARK: - Connections

extension ApiClient {
    func getConnections() async -> [ConnectionsWireMetadata] {
        guard let data = try? await send("/connections") else { return [] }
        return (try? JSONDecoder().decode(ConnectionsSnapshot.self, from: data))?.connections ?? []
    }

    func closeConnection(_ id: String) async {
        _ = try? await send("/connections/\(id)", method: "DELETE")
    }

    func closeAllConnection() async {
        _ = try? await send("/connections", method: "DELETE")
    }
}

// MARK: - Providers

extension ApiClient {
    struct AllProviders {
        var proxies = [String]()
        var rules = [String]()
    }

    func requestExternalProviderNames() async -> AllProviders {
        var providers = AllProviders()

        if let data = try? await send("/providers/proxies"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dict = obj["providers"] as? [String: Any] {
            providers.proxies = httpProviderNames(in: dict)
        }

        #if PRO_VERSION
        if let data = try? await send("/providers/rules"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dict = obj["providers"] as? [String: Any] {
            providers.rules = httpProviderNames(in: dict)
        }
        #endif

        return providers
    }

    private func httpProviderNames(in providers: [String: Any]) -> [String] {
        providers.compactMap { key, value in
            let vehicleType = (value as? [String: Any])?["vehicleType"] as? String
            return vehicleType == "HTTP" ? key : nil
        }
    }

    enum ProviderType {
        case proxy
        case rule
    }

    func updateProvider(name: String, type: ProviderType) async -> Bool {
        let path: String
        switch type {
        case .proxy: path = "/providers/proxies/\(name.encoded)"
        case .rule: path = "/providers/rules/\(name.encoded)"
        }
        do {
            _ = try await send(path, method: "PUT")
            return true
        } catch {
            return false
        }
    }

    func resetFakeIpCache() async {
        _ = try? await send("/cache/fakeip/flush", method: "POST")
    }
}
