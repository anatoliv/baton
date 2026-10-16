@testable import BatonMobile
import BatonSubsonicModels
import Foundation
import XCTest

/// Run the overflow case alone in a fresh owned simulator. The original failure
/// terminates its app-hosted test process; it must not invalidate other counts.
@MainActor
final class MixtapeSelectionLimitTests: XCTestCase {
    private func sharing() -> SongSharing {
        SongSharing(ledgerURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("mixtape-limit-" + UUID().uuidString)
            .appendingPathComponent("ledger.json"), base: URL(string: "http://127.0.0.1:1")!)
    }
    func testOverflowingDurationsRefuseBeforeCredentialsOrNetwork() async throws {
        guard !CrashReporting.isConfigured else {
            throw XCTSkip("An intentional overflow reproduction requires an unconfigured crash artifact")
        }
        let model = sharing()
        let songs = [NavidromeSong(id: "synthetic-one", title: "One", duration: Int.max),
                     NavidromeSong(id: "synthetic-two", title: "Two", duration: 1)]
        do {
            _ = try await model.shareMixtape(songs, title: "Synthetic limits", options: .init())
            XCTFail("An overflowing duration declaration must be refused")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                "Choose 2 to 12 server tracks, up to 20 minutes in total.")
        }
        XCTAssertNil(model.stage)
    }
    func testTwentyMinutesPlusOneSecondRefusesBeforeCredentialsOrNetwork() async throws {
        let model = sharing()
        let songs = [NavidromeSong(id: "synthetic-one", title: "One", duration: 600),
                     NavidromeSong(id: "synthetic-two", title: "Two", duration: 601)]
        do {
            _ = try await model.shareMixtape(songs, title: "Synthetic limits", options: .init())
            XCTFail("The aggregate limit is 1200 seconds")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                "Choose 2 to 12 server tracks, up to 20 minutes in total.")
        }
        XCTAssertNil(model.stage)
    }
}
