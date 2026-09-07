import Testing
import Foundation
@testable import WaypointNetworking

struct WireModelTests {
    private let metadataJSON = #"""
    {
      "network": "tcp",
      "type": "HTTP Connect",
      "sourceIP": "127.0.0.1",
      "destinationIP": "1.2.3.4",
      "sourcePort": "59217",
      "destinationPort": "443",
      "host": "example.com",
      "chains": ["Proxy", "GLOBAL"],
      "rule": "DOMAIN-SUFFIX",
      "rulePayload": "example.com",
      "start": "2026-09-07T12:00:00.123+0000",
      "upload": 100,
      "download": 200,
      "id": "conn-1",
      "metadata": {
        "processPath": "/Applications/Foo.app/Contents/MacOS/Foo"
      }
    }
    """#

    @Test func decodesFullConnectionMetadata() throws {
        let meta = try ApiClient.connectionsDecoder.decode(
            ConnectionsWireMetadata.self, from: Data(metadataJSON.utf8))
        #expect(meta.network == "tcp")
        #expect(meta.host == "example.com")
        #expect(meta.chains == ["Proxy", "GLOBAL"])
        #expect(meta.rulePayload == "example.com")
        #expect(meta.upload == 100)
        #expect(meta.download == 200)
        #expect(meta.id == "conn-1")
        #expect(meta.processPath == "/Applications/Foo.app/Contents/MacOS/Foo")
    }

    @Test func displayHelpers() throws {
        var json = metadataJSON
        let withEmptyHost = json
            .replacingOccurrences(of: "\"host\": \"example.com\"",
                                  with: "\"host\": \"\"")
        let meta = try ApiClient.connectionsDecoder.decode(
            ConnectionsWireMetadata.self, from: Data(withEmptyHost.utf8))
        #expect(meta.displayHost == "1.2.3.4")

        json = metadataJSON
            .replacingOccurrences(of: "\"processPath\": \"/Applications/Foo.app/Contents/MacOS/Foo\"",
                                  with: "\"processPath\": \"\"")
        let noPath = try ApiClient.connectionsDecoder.decode(
            ConnectionsWireMetadata.self, from: Data(json.utf8))
        #expect(noPath.displayHost == "example.com")
        #expect(noPath.displayName == nil)

        let named = try ApiClient.connectionsDecoder.decode(
            ConnectionsWireMetadata.self, from: Data(metadataJSON.utf8))
        #expect(named.displayName == "Foo")
    }

    @Test func missingRulePayloadDefaultsToEmpty() throws {
        let json = metadataJSON
            .replacingOccurrences(of: "\"rulePayload\": \"example.com\",", with: "")
        let meta = try ApiClient.connectionsDecoder.decode(
            ConnectionsWireMetadata.self, from: Data(json.utf8))
        #expect(meta.rulePayload == "")
    }

    @Test func snapshotDecodesAndTreatsMissingConnectionsAsEmpty() throws {
        let full = #"{"downloadTotal": 10, "uploadTotal": 20, "connections": []}"#
        let snapshot = try ApiClient.connectionsDecoder.decode(
            ConnectionsSnapshot.self, from: Data(full.utf8))
        #expect(snapshot.downloadTotal == 10)
        #expect(snapshot.uploadTotal == 20)
        #expect(snapshot.connections.isEmpty)

        // mihomo drops the key once all connections are closed.
        let keyless = #"{"downloadTotal": 1, "uploadTotal": 2}"#
        let keylessSnapshot = try ApiClient.connectionsDecoder.decode(
            ConnectionsSnapshot.self, from: Data(keyless.utf8))
        #expect(keylessSnapshot.connections.isEmpty)
    }

    @Test func snapshotDecodesEmbeddedConnection() throws {
        let payload = #"{"downloadTotal": 1, "uploadTotal": 2, "connections": ["#
            + metadataJSON + #"]}"#
        let snapshot = try ApiClient.connectionsDecoder.decode(
            ConnectionsSnapshot.self, from: Data(payload.utf8))
        #expect(snapshot.connections.count == 1)
        #expect(snapshot.connections.first?.id == "conn-1")
    }
}
