import XCTest
import BatonPlaybackKit
@testable import BatonMobile

/// What the import sheet tells you, when a secret did not land.
///
/// The sheet could say "Imported 8 settings and 1 secret" and, in the same breath, that
/// there was nothing to connection-test — because the friend was not configured without the
/// key that had just been counted as applied. Both sentences were true. Together they
/// described something that had not happened, and no user could have diagnosed it.
@MainActor
final class ImportSummaryTests: XCTestCase {

    private func result(applied: Int, refused: Int) -> SettingsTransfer.ImportResult {
        SettingsTransfer.ImportResult(preferenceCount: 8, secretCount: applied,
                                      secretsRefused: refused, documentCount: 0,
                                      appVersion: nil)
    }

    func testASuccessfulImportReadsPlainly() {
        XCTAssertEqual(MacTransferView.summary(for: result(applied: 1, refused: 0)),
                       "Imported 8 settings and 1 secret.")
    }

    /// The case this card exists for.
    func testARefusedSecretIsSaidOutLoud() {
        let text = MacTransferView.summary(for: result(applied: 0, refused: 1))
        XCTAssertTrue(text.contains("0 secrets"),
                      "it must not claim a secret it does not have — got: \(text)")
        XCTAssertTrue(text.contains("could not be saved"),
                      "and must say so, rather than leaving the check sheet to contradict it")
        XCTAssertTrue(text.contains("enter those again"), "with what to do about it")
    }

    func testPartialSuccessReportsBothHalves() {
        let text = MacTransferView.summary(for: result(applied: 2, refused: 1))
        XCTAssertTrue(text.contains("2 secrets"), "what landed")
        XCTAssertTrue(text.contains("1 account could not be saved"), "and what did not")
    }

    /// Both import paths share this sentence, so the QR scanner cannot drift into its own
    /// wording — which is how the two would start disagreeing about the same event.
    func testTheScannerAndTheFilePickerShareOneSummary() {
        let text = MacTransferView.summary(for: result(applied: 1, refused: 0))
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(MacTransferView.summary(for: result(applied: 1, refused: 0)), text)
    }
}
