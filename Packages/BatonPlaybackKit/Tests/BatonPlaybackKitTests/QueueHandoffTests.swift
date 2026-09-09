import BatonSubsonicKit
import BatonSubsonicModels
import XCTest
@testable import BatonPlaybackKit

/// Handoff had no tests at all, which is how the Mac shipped the saving half without the
/// asking half (M-F7) and how the public demo, whose `demo` account is shared with the
/// whole internet, was a server like any other (M-F13).
@MainActor
final class QueueHandoffTests: XCTestCase {

    // MARK: - Doubles

    /// Records what handoff asked the server to do, and hands back a queue on request.
    private final class ServerSpy: @unchecked Sendable {
        var urlString = "https://music.example"
        var isConfigured = true
        var saved: NavidromePlayQueue?
        var fetches = 0
        var saves = 0
        var storedQueue: NavidromePlayQueue?

        @MainActor
        func server() -> QueueHandoff.Server {
            QueueHandoff.Server(
                urlString: { self.urlString },
                isConfigured: { self.isConfigured },
                fetchQueue: {
                    self.fetches += 1
                    return self.storedQueue
                },
                saveQueue: { ids, current, positionMs in
                    self.saves += 1
                    self.saved = NavidromePlayQueue(
                        songs: ids.map { Self.song($0) }, currentID: current, positionMs: positionMs
                    )
                }
            )
        }

        static func song(_ id: String) -> NavidromeSong {
            NavidromeSong(id: id, title: "Title \(id)", artist: "Artist", album: nil,
                          albumID: nil, duration: 200, coverArtID: nil)
        }
    }

    private func song(_ id: String) -> NavidromeSong { ServerSpy.song(id) }

    /// `saveNow` hands the write to a detached Task, so an assertion made in the same turn
    /// sees nothing whether the save was suppressed or merely not yet run. Waiting first is
    /// what makes "no save" a real observation instead of a race the test always wins.
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func makeController() -> StreamingPlaybackController {
        StreamingPlaybackController(
            streamURLProvider: { URL(string: "file:///dev/null?id=\($0)")! },
            defaults: UserDefaults(suiteName: "handoff.\(UUID().uuidString)")!,
            systemNowPlaying: false
        )
    }

    // MARK: - M-F7: the Mac has to be able to receive an offer

    func testAQueueSavedByAnotherClientBecomesAnOffer() async {
        let spy = ServerSpy()
        spy.storedQueue = NavidromePlayQueue(
            songs: [song("a"), song("b")], currentID: "b", positionMs: 42_000, changedBy: "baton-ios"
        )
        let handoff = QueueHandoff(controller: makeController(), server: spy.server())

        await handoff.checkForHandoff()

        XCTAssertNotNil(handoff.offer)
        XCTAssertEqual(handoff.offer?.currentTitle, "Title b")
    }

    func testOurOwnSnapshotIsNeverOfferedBack() async {
        let spy = ServerSpy()
        spy.storedQueue = NavidromePlayQueue(
            songs: [song("a")], currentID: "a", positionMs: 0, changedBy: QueueHandoff.ownClientName
        )
        let handoff = QueueHandoff(controller: makeController(), server: spy.server())

        await handoff.checkForHandoff()

        XCTAssertNil(handoff.offer)
    }

    // MARK: - M-F13: never the shared public demo

    /// The play-queue slot is per account, and on the demo the account is `demo`/`demo`,
    /// published on Navidrome's own site. Saving there publishes the queue to strangers.
    func testNothingIsSavedToThePublicDemo() async {
        let spy = ServerSpy()
        spy.urlString = NavidromePublicDemo.url
        let controller = makeController()
        let handoff = QueueHandoff(controller: controller, server: spy.server())
        controller.play([song("a"), song("b")])

        handoff.saveNow()
        await settle()

        XCTAssertEqual(spy.saves, 0)
        XCTAssertNil(spy.saved)
    }

    func testNoOfferIsFetchedFromThePublicDemo() async {
        let spy = ServerSpy()
        spy.urlString = NavidromePublicDemo.url
        spy.storedQueue = NavidromePlayQueue(songs: [song("a")], changedBy: "someone-else")
        let handoff = QueueHandoff(controller: makeController(), server: spy.server())

        await handoff.checkForHandoff()

        XCTAssertEqual(spy.fetches, 0, "the demo slot must not even be read")
        XCTAssertNil(handoff.offer)
    }

    /// Matched on host, so an edited scheme, port or path is still the demo — and an
    /// ordinary server is still ordinary.
    func testTheDemoIsRecognisedByHostAlone() {
        XCTAssertTrue(QueueHandoff.isSharedPublicServer("https://demo.navidrome.org"))
        XCTAssertTrue(QueueHandoff.isSharedPublicServer("http://demo.navidrome.org:4533/music"))
        XCTAssertTrue(QueueHandoff.isSharedPublicServer("https://DEMO.Navidrome.ORG"))
        XCTAssertFalse(QueueHandoff.isSharedPublicServer("https://music.example"))
        XCTAssertFalse(QueueHandoff.isSharedPublicServer("https://demo.navidrome.org.example.com"))
        XCTAssertFalse(QueueHandoff.isSharedPublicServer(""))
    }

    /// The gate is the demo, not handoff itself: an ordinary server still saves.
    func testAnOrdinaryServerStillSaves() async {
        let spy = ServerSpy()
        let controller = makeController()
        let handoff = QueueHandoff(controller: controller, server: spy.server())
        controller.play([song("a"), song("b")])

        handoff.saveNow()
        await settle()

        XCTAssertEqual(spy.saves, 1)
        XCTAssertEqual(spy.saved?.songs.map(\.id), ["a", "b"])
    }
}
