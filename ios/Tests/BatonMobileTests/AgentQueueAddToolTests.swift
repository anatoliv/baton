import XCTest
import BatonPlaybackKit
import BatonSubsonicModels
@testable import BatonMobile

/// `music_queue_add` appends; it does not re-play the queue. Re-playing it reset
/// shuffle and counted the search results as part of the collection that was playing.
@MainActor
final class AgentQueueAddToolTests: XCTestCase {
    private func songs(_ prefix: String, _ n: Int) -> [NavidromeSong] {
        (0 ..< n).map { NavidromeSong(id: "\(prefix)\($0)", title: "\(prefix) \($0)") }
    }

    func testQueueAddKeepsShuffleSourceAndMembers() async {
        let model = MobileModel()
        let album = StreamingPlaybackController.QueueSource(label: "Album", kind: .album, id: "al-1")
        let tracks = songs("t", 6)
        model.music.playShuffled(tracks, source: album)
        let before = model.music.queue.map(\.id)
        let tools = AgentTools(model: model, canShare: { false })
        tools.lastResults = songs("found", 2)

        let result = await tools.run(name: "music_queue_add", arguments: [:], sessionID: nil)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(model.music.isShuffled, "adding to the queue leaves shuffle on")
        XCTAssertEqual(model.music.queueSource, album, "and the playing source as it was")
        XCTAssertEqual(model.music.queueSourceSongIDs, Set(tracks.map(\.id)), "search results are not album members")
        XCTAssertEqual(model.music.queue.map(\.id), before + ["found0", "found1"], "appended after the queue")
        XCTAssertTrue(model.music.isShuffling(album), "the album's Shuffle still reads on")
        model.music.clearQueue()
        if model.music.isShuffled { model.music.toggleShuffle() }
    }
}
