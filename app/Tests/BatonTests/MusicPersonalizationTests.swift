import XCTest
@testable import Baton

/// Coverage for deriving playback defaults from listen history. History is built in an
/// isolated `UserDefaults` suite so tests never read or write the real play log.
@MainActor
final class MusicPersonalizationTests: XCTestCase {

    private func isolatedHistory() -> MusicPlayHistory {
        let suite = UserDefaults(suiteName: "personalization-test-\(UUID().uuidString)")!
        // Inject a unique directory too: the archive persists to an on-disk JSONL, so
        // sharing the default file would let other tests' plays leak in and skew the profile.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perso-\(UUID())", isDirectory: true)
        return MusicPlayHistory(defaults: suite, directory: dir)
    }

    private func song(_ id: String, album: String?) -> NavidromeSong {
        NavidromeSong(id: id, title: "Song \(id)", artist: "Artist \(id)", album: album,
                      duration: 180, coverArtID: nil)
    }

    func testAnalyzeReturnsNilBelowThreshold() {
        let h = isolatedHistory()
        for i in 0 ..< (MusicPersonalization.minPlays - 1) { h.record(song("\(i)", album: "A")) }
        XCTAssertNil(MusicPersonalization.analyze(h), "too little history should not personalize")
    }

    func testAlbumListenerGetsGapless() {
        let h = isolatedHistory()
        // 25 consecutive plays from the same album → high continuity.
        for i in 0 ..< 25 { h.record(song("\(i)", album: "Kind of Blue")) }
        let profile = MusicPersonalization.analyze(h)
        XCTAssertNotNil(profile)
        XCTAssertGreaterThanOrEqual(profile!.albumContinuity, MusicPersonalization.albumListenerThreshold)
        let rec = MusicPersonalization.recommend(profile!)
        XCTAssertTrue(rec.gaplessEnabled, "album listeners get gapless")
        XCTAssertEqual(rec.crossfadeSeconds, 0)
        XCTAssertFalse(rec.autoplayEnabled)
    }

    func testShuffleListenerGetsCrossfade() {
        let h = isolatedHistory()
        // 25 plays, each a different album → near-zero continuity.
        for i in 0 ..< 25 { h.record(song("\(i)", album: "Album \(i)")) }
        let profile = MusicPersonalization.analyze(h)
        XCTAssertNotNil(profile)
        XCTAssertLessThan(profile!.albumContinuity, MusicPersonalization.albumListenerThreshold)
        let rec = MusicPersonalization.recommend(profile!)
        XCTAssertFalse(rec.gaplessEnabled)
        XCTAssertEqual(rec.crossfadeSeconds, 6)
        XCTAssertTrue(rec.autoplayEnabled, "singles/mix listeners get autoplay radio")
    }

    func testApplyWritesToPlayer() {
        let model = MusicModel()
        let suite = UserDefaults(suiteName: "personalization-apply-\(UUID().uuidString)")!
        let rec = MusicPersonalization.Recommendation(
            gaplessEnabled: true, crossfadeSeconds: 0, autoplayEnabled: false, rationale: "test")
        MusicPersonalization.apply(rec, to: model, defaults: suite)
        XCTAssertTrue(model.music.gaplessEnabled)
        XCTAssertEqual(model.music.crossfadeSeconds, 0)
        XCTAssertFalse(model.music.autoplayEnabled)
        XCTAssertEqual(suite.string(forKey: MusicPersonalization.rationaleKey), "test")
    }

    func testFirstRunSetsFlagAndIsIdempotent() {
        let model = MusicModel()
        let suite = UserDefaults(suiteName: "personalization-firstrun-\(UUID().uuidString)")!
        // Seed enough history on the model, then run first-run personalization.
        for i in 0 ..< 25 { model.musicHistory.record(song("\(i)", album: "One Album")) }
        MusicPersonalization.applyFirstRunIfNeeded(model, defaults: suite)
        XCTAssertTrue(suite.bool(forKey: MusicPersonalization.appliedKey), "first run must set the flag")
        // A second call must be a no-op (flag already set) — flip a value and confirm it stays.
        model.music.gaplessEnabled = false
        MusicPersonalization.applyFirstRunIfNeeded(model, defaults: suite)
        XCTAssertFalse(model.music.gaplessEnabled, "must not re-apply after the first run")
    }
}
