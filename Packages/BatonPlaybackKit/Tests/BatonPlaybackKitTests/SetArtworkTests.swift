import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// A book's cover changed while its chapters are queued: the queue shows the new
/// picture, and so does the order shuffle returns to, since the old picture's file is gone.
@MainActor
final class SetArtworkTests: XCTestCase {
    private func controller() -> StreamingPlaybackController {
        StreamingPlaybackController(
            streamURLProvider: { URL(string: "file:///dev/null?id=\($0)")! },
            defaults: UserDefaults(suiteName: ThrowawayDefaults.name("set-artwork"))!,
            systemNowPlaying: false
        )
    }

    private func chapter(_ n: Int, art: URL?) -> NavidromeSong {
        var song = NavidromeSong(id: "file:///book/chapter-\(n).m4a", title: "Chapter \(n)", artist: "A. Writer",
                                 album: "The Book", duration: 60, coverArtID: nil)
        song.artworkURL = art
        return song
    }

    func testANewCoverWhileShuffledSurvivesTurningShuffleOff() {
        let player = controller()
        let old = URL(fileURLWithPath: "/covers/book-aaaaaaaaaaaa.jpg")
        let new = URL(fileURLWithPath: "/covers/book-bbbbbbbbbbbb.png")
        let other = NavidromeSong(id: "song-x", title: "A song", artist: "Someone", album: "An album", duration: 60, coverArtID: "c")
        player.play([chapter(1, art: old), chapter(2, art: old), other, chapter(3, art: old)])
        player.toggleShuffle()
        XCTAssertTrue(player.isShuffled)

        let ids = Set((1...3).map { "file:///book/chapter-\($0).m4a" })
        player.setArtwork(new, forSongIDs: ids)
        XCTAssertTrue(player.queue.filter { ids.contains($0.id) }.allSatisfy { $0.artworkURL == new })

        player.toggleShuffle()
        XCTAssertFalse(player.isShuffled)
        XCTAssertEqual(player.queue.map(\.id), ["file:///book/chapter-1.m4a", "file:///book/chapter-2.m4a", "song-x",
                                                "file:///book/chapter-3.m4a"], "the order before shuffle is back")
        XCTAssertTrue(player.queue.filter { ids.contains($0.id) }.allSatisfy { $0.artworkURL == new },
                      "and its chapters carry the new cover, not the deleted one")
        XCTAssertNil(player.queue.first { $0.id == "song-x" }?.artworkURL, "other tracks are untouched")
    }

    func testANewCoverReachesTheQueueWithoutShuffle() {
        let player = controller()
        let new = URL(fileURLWithPath: "/covers/book-cccccccccccc.jpg")
        player.play([chapter(1, art: nil), chapter(2, art: nil)])
        player.setArtwork(new, forSongIDs: ["file:///book/chapter-2.m4a"])
        XCTAssertNil(player.queue[0].artworkURL)
        XCTAssertEqual(player.queue[1].artworkURL, new)
    }
}
