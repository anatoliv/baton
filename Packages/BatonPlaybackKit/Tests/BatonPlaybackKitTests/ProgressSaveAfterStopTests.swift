import XCTest
@testable import BatonPlaybackKit

/// Stop rewinds the player to 0:00, and that rewind's clock tick must not be saved as the
/// listener's place (TBX-10974: a book stopped in chapter 2 at 0:30 resumed at 0:00 of chapter 2
/// on the Mac and on the iPhone).
final class ProgressSaveAfterStopTests: XCTestCase {
    func testTheRewindAfterStopIsNotSaved() {
        XCTAssertFalse(StreamingPlaybackController.progressSaveDue(state: .idle, time: 0, lastSaved: 30, duration: 55))
    }

    func testPlayingSavesEveryFiveSeconds() {
        XCTAssertTrue(StreamingPlaybackController.progressSaveDue(state: .playing, time: 35, lastSaved: 30, duration: 55))
        XCTAssertFalse(StreamingPlaybackController.progressSaveDue(state: .playing, time: 33, lastSaved: 30, duration: 55))
    }

    func testASeekWhilePausedStillSaves() {
        XCTAssertTrue(StreamingPlaybackController.progressSaveDue(state: .paused, time: 10, lastSaved: 30, duration: 55))
    }

    func testAnItemWithNoLengthYetIsNotSaved() {
        XCTAssertFalse(StreamingPlaybackController.progressSaveDue(state: .playing, time: 10, lastSaved: 0, duration: 0))
    }
}
