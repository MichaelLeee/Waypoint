import Testing
import Foundation
@testable import WaypointNetworking

struct ApiErrorTests {
    @Test func descriptions() {
        #expect(ApiError.notRunning.errorDescription == "mihomo core is not running")
        #expect(ApiError.invalidURL.errorDescription == "Invalid API URL")
        #expect(ApiError.badStatus(502, "").errorDescription == "mihomo returned status 502")
        #expect(ApiError.badStatus(401, "auth fail").errorDescription == "auth fail")
    }

    @Test func badStatusUsesCoreJSONMessage() {
        let body = Data(#"{"message":"authentication failed"}"#.utf8)
        guard case let .badStatus(code, message) = ApiError.badStatus(statusCode: 401, body: body) else {
            Issue.record("expected .badStatus")
            return
        }
        #expect(code == 401)
        #expect(message == "authentication failed")
    }

    @Test func badStatusFallsBackToEmptyMessageOnNonJSONBody() {
        guard case let .badStatus(_, message) = ApiError.badStatus(statusCode: 500, body: Data("oops".utf8)) else {
            Issue.record("expected .badStatus")
            return
        }
        #expect(message.isEmpty)
    }
}

struct AuthHeaderTests {
    @Test func emptySecretOmitsHeader() {
        #expect(ApiClient.authHeader(secret: "") == [:])
    }

    @Test func secretBecomesBearerToken() {
        #expect(ApiClient.authHeader(secret: "s3cret") == ["Authorization": "Bearer s3cret"])
    }
}
