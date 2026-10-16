import AVFoundation
import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// Speed and the end-of-chapter sleep timer for spoken items.
@MainActor
final class SpokenRateTests: XCTestCase {
    private let podcast = NavidromeSong(id: "https://example.invalid/ep1.mp3", title: "Episode", artist: "Show", duration: 600)
    private let chapter1 = NavidromeSong(id: "file:///tmp/baton-tbx-10961/ch1.m4a", title: "Chapter 1", artist: "Author", duration: 300)
    private let chapter2 = NavidromeSong(id: "file:///tmp/baton-tbx-10961/ch2.m4a", title: "Chapter 2", artist: "Author", duration: 300)
    private let demoTrack = NavidromeSong(id: "file:///tmp/baton-tbx-10961/demo-song.m4a", title: "Song", artist: "Band", duration: 200)
    private let libraryTrack = NavidromeSong(id: "lib-1", title: "Library song", artist: "Band", duration: 200)

    /// No duration, so a simulated end counts as a genuine one (`StreamSeek.isGenuineEnd`).
    private func untimed(_ song: NavidromeSong) -> NavidromeSong {
        NavidromeSong(id: song.id, title: song.title, artist: song.artist)
    }

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: ThrowawayDefaults.name("tbx10961.spokenRate"))!
    }

    private func controller(_ defaults: UserDefaults) -> StreamingPlaybackController {
        let c = StreamingPlaybackController(
            streamURLProvider: { id in
                id.contains("://") ? URL(string: id)! : URL(fileURLWithPath: "/tmp/baton-tbx-10961/\(id).m4a")
            },
            coverArtURLProvider: { _ in nil },
            defaults: defaults,
            systemNowPlaying: false
        )
        // What the apps install: podcasts, plus the clippings Baton made (book chapters).
        c.isSpokenItem = { $0.isPodcastEpisode || $0.id.contains("/ch") }
        return c
    }

    /// The leak this card found: a speed chosen for a podcast carried on into the next song.
    func testMusicPlaysAtOneTimesWhateverTheSpokenSpeed() {
        let c = controller(suite())
        c.play([podcast, libraryTrack, chapter1], startAt: 0)
        c.spokenRate = 1.5
        XCTAssertEqual(c.playbackRate, 1.5, "the episode plays at the spoken speed")
        c.play([podcast, libraryTrack, chapter1], startAt: 1)
        XCTAssertEqual(c.playbackRate, 1.0, "a song is never sped up")
        c.play([podcast, libraryTrack, chapter1], startAt: 2)
        XCTAssertEqual(c.playbackRate, 1.5, "a book chapter shares the spoken speed")
        XCTAssertEqual(c.spokenRate, 1.5, "playing music does not reset the spoken speed")
    }

    /// A local file is not speech just because it is local: the bundled demo songs are music.
    func testALocalMusicFileIsNotSpoken() {
        let c = controller(suite())
        c.spokenRate = 1.75
        c.play([demoTrack], startAt: 0)
        XCTAssertFalse(c.isSpokenNowPlaying)
        XCTAssertEqual(c.playbackRate, 1.0)
    }

    /// Changing the speed while a song plays stores it for the next spoken item and leaves the
    /// song alone — the phone's podcast list can set it at any time.
    func testSettingTheSpeedDuringMusicDoesNotTouchTheSong() {
        let c = controller(suite())
        c.play([libraryTrack, chapter1], startAt: 0)
        c.spokenRate = 2.0
        XCTAssertEqual(c.playbackRate, 1.0)
        c.play([libraryTrack, chapter1], startAt: 1)
        XCTAssertEqual(c.playbackRate, 2.0)
    }

    func testTheSpeedIsRememberedAcrossLaunches() {
        let defaults = suite()
        let first = controller(defaults)
        first.spokenRate = 1.25
        let relaunched = controller(defaults)
        XCTAssertEqual(relaunched.spokenRate, 1.25)
        relaunched.play([chapter1], startAt: 0)
        XCTAssertEqual(relaunched.playbackRate, 1.25)
    }

    /// The value another device wrote through sync is picked up at the next item.
    func testASyncedSpeedIsAdoptedAtTheNextItem() {
        let defaults = suite()
        let c = controller(defaults)
        c.play([libraryTrack], startAt: 0)
        defaults.set(1.75, forKey: StreamingPlaybackController.spokenRateKey)
        c.play([chapter1], startAt: 0)
        XCTAssertEqual(c.spokenRate, 1.75)
        XCTAssertEqual(c.playbackRate, 1.75)
    }

    func testTheSpeedIsClampedToTheOfferedRange() {
        let c = controller(suite())
        c.spokenRate = 0.5
        XCTAssertEqual(c.spokenRate, 0.75)
        c.spokenRate = 3
        XCTAssertEqual(c.spokenRate, 2.0)
        c.spokenRate = .nan
        XCTAssertEqual(c.spokenRate, 1.0)
    }

    func testTheSpeedTravelsBetweenDevices() {
        XCTAssertTrue(PreferenceSync.syncedKeys.contains(StreamingPlaybackController.spokenRateKey))
    }

    /// Pitch is preserved: every item the AVPlayer deck plays uses the time-domain stretcher.
    func testItemsUseThePitchPreservingAlgorithm() {
        let c = controller(suite())
        c.play([chapter1], startAt: 0)
        XCTAssertEqual(c.currentItemTimePitchForTesting, .timeDomain)
    }

    /// "End of chapter" stops between chapters, with the next one loaded and paused, so Play
    /// goes on with the book instead of repeating the chapter just heard.
    func testEndOfChapterStopsOnTheNextChapter() {
        let c = controller(suite())
        c.play([untimed(chapter1), untimed(chapter2)], startAt: 0)
        c.sleepAtEndOfTrack()
        c.simulateTrackEndedForTesting()
        XCTAssertEqual(c.state, .paused)
        XCTAssertEqual(c.currentIndex, 1)
        XCTAssertEqual(c.nowPlaying?.id, chapter2.id)
        XCTAssertFalse(c.sleepTimerArmed, "the timer is used up")
    }

    /// Music is unchanged: "end of track" pauses on the track that ended.
    func testEndOfTrackForMusicIsUnchanged() {
        let c = controller(suite())
        c.play([untimed(libraryTrack), untimed(demoTrack)], startAt: 0)
        c.sleepAtEndOfTrack()
        c.simulateTrackEndedForTesting()
        XCTAssertEqual(c.state, .paused)
        XCTAssertEqual(c.currentIndex, 0)
    }

    func testLabels() {
        XCTAssertEqual(SpokenPlaybackOptions.rateLabel(1), "1×")
        XCTAssertEqual(SpokenPlaybackOptions.rateLabel(2), "2×")
        XCTAssertEqual(SpokenPlaybackOptions.rateLabel(1.25), "1.25×")
        XCTAssertEqual(SpokenPlaybackOptions.rateLabel(0.75), "0.75×")
        XCTAssertEqual(SpokenPlaybackOptions.rateLabel(1.5), "1.5×")
        XCTAssertEqual(SpokenPlaybackOptions.rates.first, 0.75)
        XCTAssertEqual(SpokenPlaybackOptions.rates.last, 2.0)
        XCTAssertEqual(SleepTimerOptions.minutes.prefix(4), [15, 30, 45, 60])
        XCTAssertEqual(SleepTimerOptions.endLabel(for: chapter1, isSpoken: true), "End of chapter")
        XCTAssertEqual(SleepTimerOptions.endLabel(for: podcast, isSpoken: true), "End of episode")
        XCTAssertEqual(SleepTimerOptions.endLabel(for: demoTrack, isSpoken: false), "End of track")
    }
}
