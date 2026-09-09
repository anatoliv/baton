import Foundation
import Testing
@testable import BatonMobile

/// Ageing out a snapshot nobody has refreshed.
///
/// `updatedAt` was written on every publish and read by nothing, the timeline policy was
/// `.never`, and every Live Activity push carried `staleDate: nil` — so a jetsammed or
/// force-quit app left the home screen and the Lock Screen claiming playback indefinitely
/// (I-F11). These pin the predicate that decides it.
@Suite("Widget freshness")
struct WidgetFreshnessTests {
    private let published = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("A snapshot just published is live")
    func freshIsNotStale() {
        #expect(!WidgetFreshness.isStale(updatedAt: published, asOf: published))
        #expect(!WidgetFreshness.isStale(updatedAt: published,
                                         asOf: published.addingTimeInterval(60)))
    }

    @Test("A snapshot nobody has touched for the window is stale")
    func oldIsStale() {
        #expect(WidgetFreshness.isStale(updatedAt: published,
                                        asOf: published.addingTimeInterval(WidgetFreshness.window)))
        #expect(WidgetFreshness.isStale(updatedAt: published,
                                        asOf: published.addingTimeInterval(6 * 60 * 60)))
    }

    @Test("Staleness is judged against the entry's own date, not the wall clock")
    func judgedAgainstTheEntryDate() {
        // The reason this takes `asOf` at all: WidgetKit builds a timeline entry well before
        // it displays it, so the moment that matters is the entry's, not the renderer's.
        let expiry = WidgetFreshness.staleMoment(after: published)
        #expect(expiry == published.addingTimeInterval(WidgetFreshness.window))
        #expect(WidgetFreshness.isStale(updatedAt: published, asOf: expiry))
        #expect(!WidgetFreshness.isStale(updatedAt: published,
                                         asOf: expiry.addingTimeInterval(-1)))
    }

    @Test("A playing track's activity goes stale just after the track ends")
    func activityStaleDateFollowsTheTrack() {
        let date = WidgetFreshness.activityStaleDate(
            from: published, elapsed: 30, duration: 240, isPlaying: true
        )
        // 210 seconds left, plus a minute of slack.
        #expect(date == published.addingTimeInterval(270))
    }

    @Test("A paused card, or one with no duration, gets the plain window")
    func activityStaleDateWhenThereIsNothingToCountDown() {
        let paused = WidgetFreshness.activityStaleDate(
            from: published, elapsed: 30, duration: 240, isPlaying: false
        )
        #expect(paused == published.addingTimeInterval(WidgetFreshness.window))

        // A live stream reports no duration; a minute would be far too eager.
        let stream = WidgetFreshness.activityStaleDate(
            from: published, elapsed: 0, duration: 0, isPlaying: true
        )
        #expect(stream == published.addingTimeInterval(WidgetFreshness.window))
    }

    @Test("A nonsense duration cannot push the stale date into next week")
    func activityStaleDateIsClamped() {
        let absurd = WidgetFreshness.activityStaleDate(
            from: published, elapsed: 0, duration: 60 * 60 * 400, isPlaying: true
        )
        #expect(absurd == published.addingTimeInterval(6 * 60 * 60))
    }
}
