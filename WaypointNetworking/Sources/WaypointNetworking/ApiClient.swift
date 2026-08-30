//
//  ApiClient.swift
//  WaypointNetworking
//  Transport for the mihomo REST + WebSocket API: session, auth, request
//  sending and the auto-reconnecting stream endpoints. The endpoint snapshot
//  is re-fetched before every request and stream connect, so configuration
//  changes take effect without recreating the client.
//

import Foundation

public struct ApiEndpoint: Sendable {
    public let url: String
    public let secret: String
    public let isRunning: Bool

    public init(url: String, secret: String, isRunning: Bool) {
        self.url = url
        self.secret = secret
        self.isRunning = isRunning
    }
}

public actor ApiClient {
    private let session: URLSession
    private let endpointProvider: @Sendable () async -> ApiEndpoint

    public init(endpoint: @escaping @Sendable () async -> ApiEndpoint) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 604800
        configuration.timeoutIntervalForResource = 604800
        configuration.httpMaximumConnectionsPerHost = 100
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        endpointProvider = endpoint
    }

    // MARK: - Requests

    @discardableResult
    public func send(url requestURL: URL, method: String = "GET", body: Data? = nil) async throws -> Data {
        let endpoint = await endpointProvider()
        guard endpoint.isRunning else { throw ApiError.notRunning }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in Self.authHeader(secret: endpoint.secret) {
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
    public func send(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let endpoint = await endpointProvider()
        return try await send(url: try Self.url(endpoint.url + path), method: method, body: body)
    }

    // MARK: - Streams

    public func trafficStream() -> AsyncStream<TrafficSnapshot> {
        stream("/traffic") { text in
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let up = obj["up"] as? Int,
                  let down = obj["down"] as? Int else { return nil }
            return TrafficSnapshot(up: up, down: down)
        }
    }

    public func logStream(level: String) -> AsyncStream<LogEntry> {
        stream("/logs?level=\(level)") { text in
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let log = obj["payload"] as? String ?? ""
            let level = obj["type"] as? String ?? "info"
            return LogEntry(log: log, level: level)
        }
    }

    public func memoryStream() -> AsyncStream<MemorySnapshot> {
        stream("/memory") { text in
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let inuse = obj["inuse"] as? Int else { return nil }
            return MemorySnapshot(inuse: inuse, osLimit: obj["oslimit"] as? Int)
        }
    }

    public func connectionsStream() -> AsyncStream<ConnectionsSnapshot> {
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

    // MARK: - Plumbing

    private static func url(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw ApiError.invalidURL }
        return url
    }

    private static func authHeader(secret: String) -> [String: String] {
        secret.isEmpty ? [:] : ["Authorization": "Bearer \(secret)"]
    }

    // Immutable decoder, used from the stream's @Sendable transform closure.
    private static let connectionsDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: NSCalendar.Identifier.ISO8601.rawValue)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SZ"
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

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
        let endpoint = await endpointProvider()
        let requestURL = try Self.url(endpoint.url + path)
        var request = URLRequest(url: requestURL)
        for (key, value) in Self.authHeader(secret: endpoint.secret) {
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
