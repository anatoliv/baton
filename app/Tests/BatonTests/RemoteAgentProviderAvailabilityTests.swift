import XCTest
@testable import BatonAgentKit

@MainActor
final class RemoteAgentProviderAvailabilityTests: XCTestCase {
    func testQuotaRefusalIsUnavailableAndDoesNotExposeProviderPayload() throws {
        XCTAssertThrowsError(try RemoteAgentLiveTests.skipIfRateLimited(
            RemoteNaturalLanguage.Failure.http(status: 429, body: "private-provider-payload"))) { error in
            XCTAssertTrue(error is XCTSkip)
            XCTAssertFalse(String(describing: error).contains("private-provider-payload"))
        }
    }

    func testOtherHTTPFailuresAreNotSkipped() throws {
        for status in [400, 401, 403, 404, 500, 503] {
            XCTAssertNoThrow(try RemoteAgentLiveTests.skipIfRateLimited(
                RemoteNaturalLanguage.Failure.http(status: status, body: "test")))
        }
    }

    func testMalformedRepliesAreNotSkipped() throws {
        XCTAssertNoThrow(try RemoteAgentLiveTests.skipIfRateLimited(
            RemoteNaturalLanguage.Failure.malformed("test")))
    }
}
