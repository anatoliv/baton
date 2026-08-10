import BatonSubsonicModels
import XCTest
@testable import BatonPlaybackKit

/// The seed must appear once.
///
/// Navidrome returns the seed among its own similar songs, and the Mac's six call sites all
/// wrote `[song] + radio` — so starting a radio from a track played that track, then played
/// it again a few minutes later. Nobody files that; it reads as the shuffle being odd.
final class RadioQueueTests: XCTestCase {
    private func song(_ id: String) -> NavidromeSong {
        NavidromeSong(id: id, title: id, artist: nil, album: nil, albumID: nil,
                      duration: 180, coverArtID: nil)
    }

    func testTheSeedPlaysFirstAndOnlyOnce() {
        let seed = song("a")
        // The server includes the seed in its own similars, which is the whole trap.
        let queue = RadioQueue.build(seed: seed, similar: [song("b"), song("a"), song("c")])
        XCTAssertEqual(queue.map(\.id), ["a", "b", "c"])
    }

    func testRepeatsWithinTheServerResultAreCollapsed() {
        let queue = RadioQueue.build(seed: song("a"), similar: [song("b"), song("b"), song("c")])
        XCTAssertEqual(queue.map(\.id), ["a", "b", "c"])
    }

    /// Doing nothing on a tap is indistinguishable from a bug, so an empty similar list
    /// falls back — to the collection when there is one, to the seed alone otherwise.
    func testNoSimilarsStillPlaysSomething() {
        XCTAssertEqual(RadioQueue.build(seed: song("a"), similar: []).map(\.id), ["a"])
        XCTAssertEqual(
            RadioQueue.build(seed: song("a"), similar: [], fallback: [song("x"), song("y")]).map(\.id),
            ["x", "y"]
        )
    }

    /// Artist and collection radios have no single seed track.
    func testASeedlessRadioIsJustTheSimilars() {
        XCTAssertEqual(RadioQueue.build(seed: nil, similar: [song("b"), song("b")]).map(\.id), ["b"])
        XCTAssertTrue(RadioQueue.build(seed: nil, similar: []).isEmpty)
    }

    /// One spelling. The Mac said "Absolutely Radio", the phone "Radio · Absolutely", and a
    /// third site just "Radio" — for the same feature, in the queue header.
    func testOneLabelSpelling() {
        XCTAssertEqual(RadioQueue.label("Absolutely"), "Absolutely Radio")
    }
}
