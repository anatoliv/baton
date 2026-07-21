import AVFoundation
import XCTest
@testable import Baton

/// W-11: the persisted queue is actually restored on launch, and resuming a restored
/// (loaded-paused) track fires its start side effects exactly once — so a restored track
/// logs history / "now playing" and scrobbles against the resume time, not app-launch time.
@MainActor
final class QueueRestoreTests: XCTestCase {
    private let suiteName = "io.tonebox.tests.queuerestore"
    private lazy var suite: UserDefaults = {
        let s = UserDefaults(suiteName: suiteName)!
        s.removePersistentDomain(forName: suiteName)
        return s
    }()
    private func makeController() -> StreamingPlaybackController {
        StreamingPlaybackController(
            streamURLProvider: { _ in URL(string: "file:///dev/null")! },
            defaults: suite,
            systemNowPlaying: false
        )
    }
    private func song(_ id: String) -> NavidromeSong {
        NavidromeSong(id: id, title: "Song \(id)", artist: "Artist", album: nil, duration: nil, coverArtID: nil)
    }

    func testQueueRoundTripsThroughPersistence() {
        let c1 = makeController()
        c1.play([song("a"), song("b"), song("c")], startAt: 1)

        let c2 = makeController()
        XCTAssertTrue(c2.queue.isEmpty)
        c2.restoreQueue()
        XCTAssertEqual(c2.queue.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(c2.nowPlaying?.id, "b")
        XCTAssertEqual(c2.state, .paused, "restore never auto-plays")
    }

    func testPausePersistsTheQueue() {
        let c1 = makeController()
        c1.play([song("x"), song("y")])
        c1.pause()
        let c2 = makeController()
        c2.restoreQueue()
        XCTAssertEqual(c2.queue.map(\.id), ["x", "y"])
    }

    func testResumeAfterRestoreFiresTrackStartExactlyOnce() {
        makeController().play([song("a"), song("b")]) // seed a persisted queue

        let c = makeController()
        var starts: [String] = []
        c.onTrackStarted = { starts.append($0.id) }
        c.restoreQueue()          // loads paused → no start yet
        XCTAssertEqual(starts, [])
        c.resume()                // first play of the restored item → start fires once
        XCTAssertEqual(starts, ["a"])
        c.pause(); c.resume()     // a later resume must NOT re-fire the start
        XCTAssertEqual(starts, ["a"])
    }
}
