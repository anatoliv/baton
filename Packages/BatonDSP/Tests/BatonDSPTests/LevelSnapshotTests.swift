import XCTest
@testable import BatonDSP

/// The lock-free hand-off from the audio render thread to the UI.
///
/// The whole point of packing four levels into one word is that a reader can never observe
/// a mixture of an old frame and a new one. These tests pin the packing and then hammer it
/// from several threads to show a reader only ever sees whole frames.
final class LevelSnapshotTests: XCTestCase {
    func testRoundTripsWithinAByteOfResolution() {
        let levels = BandLevels(low: 0.1, lowMid: 0.5, highMid: 0.75, high: 1.0)
        let out = LevelSnapshot.unpack(LevelSnapshot.pack(levels))
        for i in 0 ..< 4 {
            XCTAssertEqual(out[i], levels[i], accuracy: 1.0 / 255)
        }
    }

    func testBandsDoNotBleedIntoEachOther() {
        // Only one band set: the others must come back at zero, or the shifts are wrong.
        let out = LevelSnapshot.unpack(LevelSnapshot.pack(.init(low: 0, lowMid: 1, highMid: 0, high: 0)))
        XCTAssertEqual(out.low, 0)
        XCTAssertEqual(out.highMid, 0)
        XCTAssertEqual(out.high, 0)
        XCTAssertEqual(out.lowMid, 1, accuracy: 1.0 / 255)
    }

    func testOutOfRangeAndNonFiniteValuesAreClamped() {
        let out = LevelSnapshot.unpack(LevelSnapshot.pack(
            .init(low: -5, lowMid: 12, highMid: .nan, high: .infinity)
        ))
        XCTAssertEqual(out.low, 0)
        XCTAssertEqual(out.lowMid, 1, accuracy: 1.0 / 255)
        XCTAssertEqual(out.highMid, 0, "a NaN must publish as silence, not as garbage height")
        XCTAssertEqual(out.high, 0)
    }

    func testClearReturnsToSilence() {
        let snapshot = LevelSnapshot()
        snapshot.store(.init(low: 1, lowMid: 1, highMid: 1, high: 1))
        snapshot.clear()
        XCTAssertEqual(snapshot.load(), .silent)
    }

    /// A reader must never see half of one frame and half of another. Writers publish only
    /// frames where all four bands share a value, so any torn read shows up as a mismatch.
    func testConcurrentReadsNeverSeeATornFrame() {
        let snapshot = LevelSnapshot()
        let done = expectation(description: "readers finished")
        done.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for i in 0 ..< 20_000 {
                let v = Float(i % 256) / 255
                snapshot.store(.init(low: v, lowMid: v, highMid: v, high: v))
            }
        }
        for _ in 0 ..< 2 {
            DispatchQueue.global().async {
                for _ in 0 ..< 20_000 {
                    let l = snapshot.load()
                    XCTAssertEqual(l.low, l.lowMid)
                    XCTAssertEqual(l.low, l.highMid)
                    XCTAssertEqual(l.low, l.high)
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 20)
    }
}
