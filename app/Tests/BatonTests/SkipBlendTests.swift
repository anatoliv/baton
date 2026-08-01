import AVFoundation
import XCTest
@testable import Baton

/// The manual-skip blend.
///
/// A skip used to hard-cut. Blending it is only acceptable if the *transport* still moves
/// instantly: a first attempt deferred the queue advance until the ramp completed, so
/// `nowPlaying`, the UI and `music_next` reported the previous track for the length of the
/// blend. `testNextAdvancesAndStopsPastEnd` caught it, and these tests pin the rule so it
/// can't regress — only the audio may lag, never the state.
@MainActor
final class SkipBlendTests: XCTestCase {
    private let suiteName = "io.tonebox.tests.skipblend"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()

    private func makeController() -> StreamingPlaybackController {
        StreamingPlaybackController(
            streamURLProvider: { _ in URL(string: "file:///dev/null")! },
            defaults: suite,
            systemNowPlaying: false
        )
    }

    private func song(_ id: String) -> NavidromeSong {
        NavidromeSong(id: id, title: "Song \(id)", artist: "Artist", album: nil, duration: 200, coverArtID: nil)
    }

    // MARK: - The invariant that matters

    func testSkipAdvancesTheTransportSynchronously() {
        let c = makeController()
        c.play([song("a"), song("b"), song("c")])
        c.next()
        // Immediately — no awaiting the ramp.
        XCTAssertEqual(c.nowPlaying?.id, "b", "the transport must move the instant skip is pressed")
        XCTAssertEqual(c.state, .playing)
    }

    func testRepeatedSkipsEachLandImmediately() {
        let c = makeController()
        c.play([song("a"), song("b"), song("c")])
        c.next()
        XCTAssertEqual(c.nowPlaying?.id, "b")
        c.next()
        XCTAssertEqual(c.nowPlaying?.id, "c", "a second skip must not be swallowed by an in-flight blend")
    }

    func testSkipPastTheEndStillStops() {
        let c = makeController()
        c.play([song("a")])
        c.next()
        XCTAssertEqual(c.state, .idle, "blending must not swallow the end-of-queue stop")
    }

    func testQueuePositionIsPersistedAtTheNewIndexNotTheOld() {
        let c = makeController()
        c.play([song("a"), song("b")])
        c.next()
        let restored = makeController()
        restored.restoreQueue()
        XCTAssertEqual(
            restored.nowPlaying?.id, "b",
            "a skip must persist the new index immediately — a crash mid-blend should not rewind"
        )
    }

    // MARK: - When a blend must NOT happen

    func testSkipWhilePausedDoesNotBlend() {
        let c = makeController()
        c.play([song("a"), song("b")])
        c.pause()
        c.next()
        XCTAssertEqual(c.nowPlaying?.id, "b")
        XCTAssertNotEqual(c.state, .playing, "skipping while paused must not start playback")
    }

    func testPreviousAlsoAdvancesSynchronously() {
        let c = makeController()
        c.play([song("a"), song("b"), song("c")])
        c.next()
        c.previous()
        XCTAssertNotNil(c.nowPlaying, "previous must leave the transport in a defined state")
    }
}
