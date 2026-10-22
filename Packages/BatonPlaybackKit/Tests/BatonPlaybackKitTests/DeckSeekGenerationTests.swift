import AVFoundation
import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// The AVPlayer deck's item lifecycle against seeks and status.
@MainActor
final class DeckSeekGenerationTests: XCTestCase {
    private func wait(_ seconds: Double, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    }

    /// A seek in flight when a new track loads completes with `finished == false`. Its
    /// generation was never retired, so it asked the host to re-request the *new* track at the
    /// old target (C1-13).
    func testASeekInFlightWhenANewTrackLoadsDoesNotReRequestTheNewTrack() async throws {
        // A local file, so the whole of it is seekable at once, loaded as a stream that honours
        // `timeOffset`, so a seek that does not land asks the host for a re-request. An HTTP
        // fixture reports no seekable range in time to seek in place.
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/stream-fixture.mp3", withExtension: nil))
        let first = NavidromeSong(id: "lib-1", title: "one", artist: "a", album: nil, duration: 68, coverArtID: nil)
        let deck = AVPlayerDeck()
        defer { deck.clear() }
        var ready = false
        deck.onItemReady = { ready = true }
        var reloads: [TimeInterval] = []
        deck.onReloadStream = { reloads.append($0) }
        deck.load(song: first, url: fixture, startingAt: 0, autoplay: true, headers: [:], supportsTimeOffset: true)
        try await wait(8) { ready }
        try XCTSkipUnless(ready, "the fixture never became ready")
        func reachable() -> Double {
            (deck.player.currentItem?.seekableTimeRanges ?? []).map { CMTimeRangeGetEnd($0.timeRangeValue).seconds }.max() ?? 0
        }
        try await wait(8) { reachable() > 45 }
        try XCTSkipUnless(reachable() > 45, "the fixture never reported 45 s seekable")

        deck.seek(to: 40)
        XCTAssertEqual(reloads, [], "precondition: the seek is in place, not a re-request")
        let second = NavidromeSong(id: "lib-2", title: "two", artist: "a", album: nil, duration: 68, coverArtID: nil)
        deck.load(song: second, url: fixture, startingAt: 0, autoplay: true, headers: [:], supportsTimeOffset: true)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(reloads, [], "the new track was re-requested at the old track's seek target")
    }

    /// An item adopted at a gapless boundary may already have failed while it waited in the
    /// queue. Its status was observed for changes only, so that failure was never reported and
    /// the host sat on a dead item (C1-14).
    func testAnAdoptedItemThatAlreadyFailedIsReported() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/stream-fixture.mp3", withExtension: nil))
        let deck = AVPlayerDeck()
        defer { deck.clear() }
        var failures: [String] = []
        deck.onFailure = { failures.append($0) }
        deck.load(song: NavidromeSong(id: "lib-1", title: "one", artist: "a", album: nil, duration: 68, coverArtID: nil),
                  url: fixture, startingAt: 0, autoplay: false, headers: [:], supportsTimeOffset: false)
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("absent-\(UUID().uuidString).mp3")
        let next = NavidromeSong(id: missing.absoluteString, title: "two", artist: "a", album: nil, duration: 30, coverArtID: nil)
        XCTAssertTrue(deck.prepareNext(song: next, at: 1, url: missing))
        let queued = try XCTUnwrap(deck.player.items().last)
        try await wait(5) { queued.status == .failed }
        try XCTSkipUnless(queued.status == .failed, "the queued item did not fail while queued")
        XCTAssertTrue(deck.adoptPreparedNext())
        try await wait(2) { !failures.isEmpty }
        XCTAssertEqual(failures.count, 1, "the adopted item's earlier failure was never reported")
    }

    /// A seek that did not land is owed a retry when the item reports seekable ranges, but KVO
    /// reports only a change. When the ranges were already known before the failed completion
    /// parked the retry, nothing retried it while playing, and the deck's clock stayed frozen
    /// at the target over audio from 0:00: the symptom (review finding).
    func testARetryOwedWhileRangesAreAlreadyKnownStillHappensAndTheClockRuns() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/stream-fixture.mp3", withExtension: nil))
        let deck = AVPlayerDeck()
        defer { deck.clear() }
        var ready = false
        deck.onItemReady = { ready = true }
        let song = NavidromeSong(id: fixture.absoluteString, title: "file", artist: "a", album: nil, duration: 68, coverArtID: nil)
        deck.load(song: song, url: fixture, startingAt: 0, autoplay: false, headers: [:], supportsTimeOffset: false)
        try await wait(8) { ready }
        func reachable() -> Double {
            (deck.player.currentItem?.seekableTimeRanges ?? []).map { CMTimeRangeGetEnd($0.timeRangeValue).seconds }.max() ?? 0
        }
        try await wait(8) { reachable() > 45 }
        try XCTSkipUnless(reachable() > 45, "the fixture never reported 45 s seekable")

        deck.hostIntendsToPlay = { true }     // playing: the clock must not be held
        deck.parkInPlaceSeekForTesting(40)   // the ranges are known already, so no change will come
        XCTAssertFalse(deck.isSeekingForTesting, "the clock is held while a retry is owed")
        try await wait(3) { abs((deck.player.currentItem?.currentTime().seconds ?? 0) - 40) < 0.5 }
        XCTAssertEqual(deck.player.currentItem?.currentTime().seconds ?? 0, 40, accuracy: 0.5,
                       "the owed retry never ran")
    }

    /// Paused, the clock stays on the place being restored while the retry is owed, so a
    /// restored queue is not shown, or saved, at 0:00.
    func testWhilePausedTheClockStaysOnThePlace() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/stream-fixture.mp3", withExtension: nil))
        let deck = AVPlayerDeck()
        defer { deck.clear() }
        deck.hostIntendsToPlay = { false }
        let song = NavidromeSong(id: fixture.absoluteString, title: "file", artist: "a", album: nil, duration: 68, coverArtID: nil)
        deck.load(song: song, url: fixture, startingAt: 0, autoplay: false, headers: [:], supportsTimeOffset: false)
        deck.parkInPlaceSeekForTesting(40)
        XCTAssertTrue(deck.isSeekingForTesting)
    }
}
