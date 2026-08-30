//
//  WireModels.swift
//  WaypointNetworking
//  Sendable snapshots decoded from the mihomo streaming API.
//

public struct TrafficSnapshot: Sendable {
    public let up: Int
    public let down: Int

    public init(up: Int, down: Int) {
        self.up = up
        self.down = down
    }
}

public struct LogEntry: Sendable {
    public let log: String
    public let level: String

    public init(log: String, level: String) {
        self.log = log
        self.level = level
    }
}

public struct MemorySnapshot: Sendable {
    public let inuse: Int
    public let osLimit: Int?

    public init(inuse: Int, osLimit: Int?) {
        self.inuse = inuse
        self.osLimit = osLimit
    }
}

public struct ConnectionsWireMetadata: Sendable, Decodable {
    public let network: String
    public let type: String
    public let sourceIP: String
    public let destinationIP: String
    public let sourcePort: String
    public let destinationPort: String
    public let host: String
    public let chains: [String]
    public let rule: String
    public let rulePayload: String
    public let start: Date
    public let upload: Int
    public let download: Int
    public let id: String
    public let processPath: String?

    public var displayHost: String { host.isEmpty ? destinationIP : host }
    public var displayName: String? { processPath?.isEmpty == false ? processPath?.components(separatedBy: "/").last : nil }

    enum CodingKeys: String, CodingKey {
        case network, type, sourceIP, destinationIP, sourcePort, destinationPort
        case host, chains, rule, rulePayload, start, upload, download, id
        case metadata
        case processPath
    }

    public init(from decoder: Decoder) throws {
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

public struct ConnectionsSnapshot: Sendable {
    public let downloadTotal: Int
    public let uploadTotal: Int
    public let connections: [ConnectionsWireMetadata]

    public init(downloadTotal: Int, uploadTotal: Int, connections: [ConnectionsWireMetadata]) {
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.connections = connections
    }
}
