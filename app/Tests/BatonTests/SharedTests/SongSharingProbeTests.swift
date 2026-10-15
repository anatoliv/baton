import BatonShareKit
import Foundation
import XCTest
@testable import Baton

final class SongSharingProbeTests: XCTestCase {
    @MainActor func testSharingHistoryAndToolArgumentsCannotOptIntoPreservation() throws {
        XCTAssertFalse(SongSharing.Options().reviewPreservation)
        let options = try SongSharing.toolOptions(["reviewPreservation": true, "expires_days": 7], from: "Synthetic")
        XCTAssertFalse(options.reviewPreservation)
    }

    func testOrdinaryLaunchCannotRedirectShares() {
        XCTAssertEqual(SongSharing.probeBase(isProbe: false,
                                            environment: ["baton.share.baseURL": "http://127.0.0.1:8790"]),
                       ShareLink.defaultBase)
    }

    func testIsolatedProbeCanUseLocalFixture() {
        let local = URL(string: "http://127.0.0.1:8790")!
        XCTAssertEqual(SongSharing.probeBase(isProbe: true,
                                            environment: ["baton.share.baseURL": local.absoluteString]), local)
    }

    func testProbeCannotRedirectToAnExternalOrCredentialBearingURL() {
        for raw in ["https://batonmusic.app", "http://example.com", "http://127.0.0.1.evil.test",
                    "http://person:secret@127.0.0.1:8790", "http://127.0.0.1:8790/other",
                    "http://127.0.0.1:8790?token=secret", "http://127.0.0.1:8790#key", "invalid"] {
            XCTAssertEqual(SongSharing.probeBase(isProbe: true, environment: ["baton.share.baseURL": raw]),
                           ShareLink.defaultBase, raw)
        }
    }
}
