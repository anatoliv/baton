import XCTest
@testable import Baton

/// Coverage for `PodcastProgressStore` — resume offsets, the finished/played threshold, and
/// persistence. This is the logic behind "pick up where I left off" and played/unplayed state.
@MainActor
final class PodcastProgressTests: XCTestCase {
    private func makeStore() -> (PodcastProgressStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (PodcastProgressStore(directory: dir), dir)
    }

    func testRecordThenResumeOffset() {
        let (store, _) = makeStore()
        // 10 min into a 46-min episode → resumes there.
        let finished = store.record(id: "ep1", position: 600, duration: 2760)
        XCTAssertFalse(finished)
        XCTAssertEqual(store.resumeOffset(id: "ep1"), 600)
        XCTAssertFalse(store.isPlayed(id: "ep1"))
        XCTAssertEqual(store.fraction(id: "ep1")!, 600.0 / 2760.0, accuracy: 0.001)
        XCTAssertEqual(store.remaining(id: "ep1")!, 2760 - 600, accuracy: 0.001)
    }

    func testNoResumeNearStartOrEnd() {
        let (store, _) = makeStore()
        store.record(id: "a", position: 3, duration: 2760)   // barely started
        XCTAssertNil(store.resumeOffset(id: "a"))
        store.record(id: "b", position: 2755, duration: 2760) // basically over → played
        XCTAssertNil(store.resumeOffset(id: "b"))
        XCTAssertTrue(store.isPlayed(id: "b"))
    }

    func testCrossingThresholdMarksPlayedAndReports() {
        let (store, _) = makeStore()
        XCTAssertFalse(store.record(id: "ep", position: 100, duration: 2760))
        // Within the 30s tail → finished; record returns true exactly on the transition.
        XCTAssertTrue(store.record(id: "ep", position: 2740, duration: 2760))
        XCTAssertTrue(store.isPlayed(id: "ep"))
        XCTAssertEqual(store.fraction(id: "ep"), 1)
        XCTAssertNil(store.resumeOffset(id: "ep"))
        // Already played → no second transition.
        XCTAssertFalse(store.record(id: "ep", position: 2760, duration: 2760))
    }

    func testRemoveForgetsProgress() {
        let (store, _) = makeStore()
        store.record(id: "a", position: 300, duration: 2760)
        store.record(id: "b", position: 100, duration: 2760)
        store.remove(ids: ["a", "missing"])
        XCTAssertNil(store.resumeOffset(id: "a"))
        XCTAssertEqual(store.resumeOffset(id: "b"), 100) // untouched
    }

    func testMarkPlayedUnplayed() {
        let (store, _) = makeStore()
        store.record(id: "ep", position: 300, duration: 2760)
        store.markPlayed(id: "ep")
        XCTAssertTrue(store.isPlayed(id: "ep"))
        XCTAssertNil(store.resumeOffset(id: "ep"))
        store.markUnplayed(id: "ep")
        XCTAssertFalse(store.isPlayed(id: "ep"))
    }

    func testIsFinishedThresholds() {
        XCTAssertFalse(PodcastProgressStore.isFinished(position: 1000, duration: 2760))
        XCTAssertTrue(PodcastProgressStore.isFinished(position: 2740, duration: 2760))  // within 30s tail
        XCTAssertTrue(PodcastProgressStore.isFinished(position: 2690, duration: 2760))  // ≥97%
        XCTAssertFalse(PodcastProgressStore.isFinished(position: 100, duration: nil))   // unknown duration
    }

    func testPersistsAcrossReload() async throws {
        let (store, dir) = makeStore()
        store.record(id: "ep", position: 600, duration: 2760)
        // The write is now off the main actor; wait for the (atomic) file to land before
        // reloading. File-exists ⟹ complete, so no partial read.
        let fileURL = dir.appendingPathComponent("podcast-progress.json")
        for _ in 0 ..< 100 where !FileManager.default.fileExists(atPath: fileURL.path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let reborn = PodcastProgressStore(directory: dir)
        reborn.loadIfNeeded()
        XCTAssertEqual(reborn.resumeOffset(id: "ep"), 600)
    }

    /// Only client-side podcast episodes (http-URL ids) get resume/progress — library tracks
    /// (Subsonic ids) never do.
    func testPodcastEpisodeGate() {
        func song(_ id: String) -> NavidromeSong {
            NavidromeSong(id: id, title: "t", artist: nil, album: nil, duration: nil, coverArtID: nil)
        }
        XCTAssertTrue(MusicModel.isPodcastEpisode(song("https://cdn.example/ep.mp3")))
        XCTAssertFalse(MusicModel.isPodcastEpisode(song("al-1234")))
    }
}
