//
//  ApiError.swift
//  WaypointNetworking
//

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
}

struct MihomoError: Decodable {
    let message: String
}
