//
//  ApiError.swift
//  WaypointNetworking
//

import Foundation

public enum ApiError: LocalizedError {
    case notRunning
    case invalidURL
    case badStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "mihomo core is not running"
        case .invalidURL:
            return "Invalid API URL"
        case let .badStatus(code, message):
            return message.isEmpty ? "mihomo returned status \(code)" : message
        }
    }

    /// Maps a non-2xx response to an error, using the core's JSON
    /// `{"message": …}` body as the message when present.
    public static func badStatus(statusCode: Int, body: Data) -> ApiError {
        let message = (try? JSONDecoder().decode(MihomoError.self, from: body))?.message ?? ""
        return .badStatus(statusCode, message)
    }
}

struct MihomoError: Decodable {
    let message: String
}
