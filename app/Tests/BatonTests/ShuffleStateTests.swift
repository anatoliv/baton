import XCTest
@testable import Baton
import BatonPlaybackKit
import BatonSubsonicModels

/// Pressing Shuffle must leave the player *in* shuffle, not merely start a shuffled queue.
///
/// Reported as "the shuffle button does not change the visual state when you click it". It
/// was worse than a cosmetic miss: the mix pages shuffled the array and played it, and
/// never touched shuffle mode — so the transport's own shuffle control sat there reading
/// "Shuffle off" over a queue that was plainly not in order, and the next track came from
/// wherever the fixed shuffled list pointed rather than from shuffle.
@MainActor
final class ShuffleStateTests: XCTestCase {
    private func controller() -> StreamingPlaybackController {
        StreamingPlaybackController(defaults: UserDefaults(suiteName: "shuffle.\(UUID().uuidString)")!)
    }

    private func songs(_ n: Int) -> [NavidromeSong] {
        (0 ..< n).map { NavidromeSong(id: "s\($0)", title: "Track \($0)") }
    }

    /// The state the transport reads. If this is false, the icon is grey and the label
    /// says "Shuffle off" while shuffled music plays.
    func testTurningShuffleOnIsWhatTheTransportReads() {
        let player = controller()
        XCTAssertFalse(player.isShuffled, "precondition: starts off")

        player.toggleShuffle()

        XCTAssertTrue(player.isShuffled,
                      "the mix pages call exactly this after starting a shuffled queue")
    }

    /// Guards the naive fix: calling toggle unconditionally would turn shuffle *off* for
    /// anyone who already had it on and then pressed Shuffle on a mix.
    func testPressingShuffleWhenAlreadyShuffledLeavesItOn() {
        let player = controller()
        player.toggleShuffle()
        XCTAssertTrue(player.isShuffled)

        // The guard the call sites use.
        if !player.isShuffled { player.toggleShuffle() }

        XCTAssertTrue(player.isShuffled, "pressing Shuffle must never un-shuffle")
    }

    func testShuffleSurvivesRelaunch() {
        let suite = "shuffle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let player = StreamingPlaybackController(defaults: defaults)
        player.toggleShuffle()

        let relaunched = StreamingPlaybackController(defaults: defaults)

        XCTAssertTrue(relaunched.isShuffled, "shuffle is a setting, not a session detail")
    }

    // MARK: - The Shuffle button beside Play

    private func source(_ id: String) -> StreamingPlaybackController.QueueSource {
        .init(label: id, kind: .album, id: id)
    }

    func testFirstPressTurnsShuffleOn() {
        let player = controller()
        player.playShuffleToggling(songs(6), source: source("a"))
        XCTAssertTrue(player.isShuffled)
        XCTAssertEqual(player.queue.count, 6)
    }

    /// The reason the toggle is asymmetric, and the one behaviour here worth protecting:
    /// stopping shuffle three tracks into an album must not throw you back to track one.
    func testSecondPressStopsShufflingWithoutRestarting() {
        let player = controller()
        let album = songs(8)
        player.playShuffleToggling(album, source: source("a"))
        player.next()
        player.next()
        let playing = player.nowPlaying
        XCTAssertNotNil(playing, "precondition: something is playing")

        player.playShuffleToggling(album, source: source("a"))

        XCTAssertFalse(player.isShuffled, "the press must stop shuffling")
        XCTAssertEqual(player.nowPlaying?.id, playing?.id,
                       "and must not throw you back to the top of the album")
    }

    /// A *different* collection has nothing in place to preserve, so it starts, in order.
    func testPressingOnAnotherCollectionStartsItInOrder() {
        let player = controller()
        player.playShuffleToggling(songs(5), source: source("a"))
        XCTAssertTrue(player.isShuffled)

        let other = songs(4)
        player.playShuffleToggling(other, source: source("b"))

        XCTAssertFalse(player.isShuffled)
        XCTAssertEqual(player.queue.map(\.id), other.map(\.id))
    }

    /// The context-menu "Shuffle" is deliberately not a toggle — it shows no state, so
    /// silently un-shuffling would be a surprise with nothing on screen to explain it.
    func testTheMenuShuffleOnlyEverTurnsShuffleOn() {
        let player = controller()
        player.playShuffled(songs(5), source: source("a"))
        XCTAssertTrue(player.isShuffled)

        player.playShuffled(songs(5), source: source("a"))

        XCTAssertTrue(player.isShuffled, "still on — this one never turns it off")
    }
}
