import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// Engine follow-ups from the review (C1-15, C1-16, and the immediate pause
/// during a retry backoff noted beside C1-17).
@MainActor
final class EngineResumeFollowUpTests: XCTestCase {
    private static let bytesForOneSecond = 44 + 44_100 * 2

    /// A paused restore whose load fails offline rests at `.idle` with the playhead at the
    /// place. Resume used to load from 0:00 (C1-16).
    func testResumeAfterAFailedPausedLoadStartsAtThePlace() async throws {
        let server = try EngineHTTPServer(
            payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 30),
            delivery: .truncateAfter(bytes: Self.bytesForOneSecond, connections: 1),
            contentType: "audio/wav"
        )
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: 44_100)
        defer { harness.shutdown() }
        harness.controller.stallTimeoutSeconds = 120
        let track = EnginePlaybackController.Track(id: "restored", url: server.url, duration: 30,
                                                   supportsTimeOffset: false)
        harness.controller.play(track, atTime: 12, autoplay: false)
        try await harness.waitUntil(timeout: 20) { harness.controller.state == .idle }
        XCTAssertEqual(harness.controller.currentTime, 12, accuracy: 0.5, "precondition: the place survives the failure")

        harness.controller.resume()
        XCTAssertEqual(harness.controller.currentTime, 12, accuracy: 0.5, "Resume restarted the track at 0:00")
    }

    /// The early-end budget is per play: a track left mid-recovery handed what it had spent to
    /// the next one (C1-15).
    func testANewTrackGetsAFreshEarlyEndBudget() async throws {
        let server = try EngineHTTPServer(
            payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 2), contentType: "audio/wav")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: 44_100)
        defer { harness.shutdown() }
        harness.controller.stallTimeoutSeconds = 120
        let early = EnginePlaybackController.Track(id: "early", url: server.url, duration: 30, supportsTimeOffset: false)
        harness.controller.play(early)
        try await harness.waitUntil(timeout: 20) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 1.5
        }
        _ = try await harness.renderSeconds(2.5)
        try await harness.waitUntil(timeout: 10) { harness.controller.loadCountForTesting > 1 }
        XCTAssertGreaterThan(harness.controller.spuriousEndRecoveriesForTesting, 0, "precondition: a recovery was spent")

        let next = EnginePlaybackController.Track(id: "next", url: server.url, duration: 30, supportsTimeOffset: false)
        harness.controller.play(next)
        XCTAssertEqual(harness.controller.spuriousEndRecoveriesForTesting, 0, "the next track inherited a spent budget")
    }

    /// An immediate pause (a received-song handoff) during the retry backoff set `.paused`, so
    /// the retry abandoned itself, and Resume then set `.loading` with no load running: a
    /// spinner for good.
    func testResumeAfterAnImmediatePauseDuringARetryBackoffPlays() async throws {
        let server = try EngineHTTPServer(
            payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 30),
            delivery: .truncateAfter(bytes: Self.bytesForOneSecond, connections: 1),
            contentType: "audio/wav"
        )
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: 44_100)
        defer { harness.shutdown() }
        harness.controller.stallTimeoutSeconds = 120
        let track = EnginePlaybackController.Track(id: "handoff", url: server.url, duration: 30,
                                                   supportsTimeOffset: false)
        harness.controller.play(track)
        try await harness.waitUntil(timeout: 20) { harness.controller.sameTrackRetriesForTesting == 1 }
        XCTAssertEqual(harness.controller.state, .loading, "precondition: waiting out the first backoff")

        harness.controller.pauseImmediately()
        try await Task.sleep(for: .milliseconds(1_500))   // past the 1 s backoff
        harness.controller.resume()
        let played = await harness.waitUntilOrTimeout(seconds: 15) { harness.controller.state == .playing }
        XCTAssertTrue(played, "Resume left the engine at \(harness.controller.state) with nothing loading")
        XCTAssertGreaterThanOrEqual(server.acceptedConnections, 2, "the retry never reconnected")
    }
}
