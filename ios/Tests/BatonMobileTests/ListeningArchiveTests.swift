import BatonPlaybackKit
import BatonSubsonicModels
import XCTest
@testable import BatonMobile

/// The private listening archive has to mean the same thing on both apps.
///
/// The Mac writes it from the scrobble threshold and says so in a comment. The phone wrote
/// it from `onTrackStarted`, so a track skipped after two seconds was a play. That archive
/// feeds Recently Played, lifetime totals, top tracks, top artists and the listening trend,
/// and the phone labels those numbers "plays on this iPhone" next to a server-ranked "All
/// devices" view, so the two are read side by side. The phone's top tracks were a ranking
/// of skips.
@MainActor
final class ListeningArchiveTests: XCTestCase {

    private func song(_ id: String = "track-1") -> NavidromeSong {
        NavidromeSong(id: id, title: "Title \(id)", artist: "Artist", album: "Album",
                      albumID: nil, duration: 240, coverArtID: nil)
    }

    /// Starting a track is not listening to one.
    func testStartingATrackRecordsNothing() {
        let model = MobileModel()
        model.history.clear()

        model.music.onTrackStarted?(song())

        XCTAssertEqual(model.history.playCount(since: .distantPast), 0,
                       "the phone counted a track start as a play, so every skip was a listen")
        model.history.clear()
    }

    /// Crossing the scrobble threshold is.
    func testCrossingTheThresholdRecordsOneListen() {
        let model = MobileModel()
        model.history.clear()

        model.music.onScrobbleEligible?(song(), Date())

        XCTAssertEqual(model.history.playCount(since: .distantPast), 1,
                       "the threshold has to reach the archive, or nothing is recorded at all")
        model.history.clear()
    }

    /// Start then threshold is one listen, not two: the archive now has exactly one writer.
    func testAStartFollowedByAThresholdIsOnePlay() {
        let model = MobileModel()
        model.history.clear()
        let track = song()

        model.music.onTrackStarted?(track)
        model.music.onScrobbleEligible?(track, Date())

        XCTAssertEqual(model.history.playCount(since: .distantPast), 1)
        model.history.clear()
    }
}
