import XCTest
@testable import BatonMobile

/// The pairing scanner after a bad code (TBX-1000000505 B-4): it stopped reporting codes after
/// the first one, and its screen stopped accepting them after the first failure, so it sat dead
/// with the camera on until Cancel.
final class PairingScannerGateTests: XCTestCase {
    func testADifferentCodeIsTriedAtOnceAfterABadOne() {
        var gate = ScanGate()
        let start = Date()
        XCTAssertTrue(gate.shouldReport("a wifi code", now: start))
        XCTAssertFalse(gate.shouldReport("a wifi code", now: start.addingTimeInterval(0.05)), "one code is one attempt per frame burst")
        XCTAssertTrue(gate.shouldReport("baton-pair:the-right-one", now: start.addingTimeInterval(0.5)),
                      "the scanner was dead after the first code")
    }

    func testTheSameCodeIsTriedAgainAfterAPause() {
        var gate = ScanGate()
        let start = Date()
        XCTAssertTrue(gate.shouldReport("baton-pair:x", now: start))
        XCTAssertFalse(gate.shouldReport("baton-pair:x", now: start.addingTimeInterval(2.9)))
        XCTAssertTrue(gate.shouldReport("baton-pair:x", now: start.addingTimeInterval(3.1)),
                      "a redeem that failed on the network gets another try while pointed at it")
    }

    func testAFailureAcceptsTheNextScanAndAnAttemptInFlightDoesNot() {
        XCTAssertTrue(PairingScannerView.Status.scanning.acceptsScan)
        XCTAssertTrue(PairingScannerView.Status.failed("That isn't a Baton pairing code.").acceptsScan)
        XCTAssertFalse(PairingScannerView.Status.connecting.acceptsScan)
        XCTAssertFalse(PairingScannerView.Status.linked(preferences: 3, secrets: 1).acceptsScan)
    }
}
