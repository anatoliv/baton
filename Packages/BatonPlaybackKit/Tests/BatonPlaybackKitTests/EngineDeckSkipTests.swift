import XCTest
@testable import BatonPlaybackKit

/// Pressing Next on the engine deck must reach the deck.
///
/// It didn't: `next()` tries `beginSkipBlend` first, which is AVPlayer machinery — it moves
/// every observable property to the next track and then crossfades between two AVPlayer
/// instances. With the engine deck owning playback those players are silent, so the UI
/// showed the next track while the engine carried on rendering the previous one, and the
/// playhead oscillated between the two clocks. `beginSkipBlend` returning early is what
/// sends `next()` down `loadCurrent`, the only path that reaches the deck.
///
/// The automatic end-of-track crossfade already carried this guard; the manual skip did
/// not, which is exactly the kind of asymmetry a test should hold in place.
@MainActor
final class EngineDeckSkipTests: XCTestCase {
    /// The guard is a source-level invariant: both blend entry points must refuse while a
    /// deck is attached. Asserted on the source because constructing a live AVPlayer queue
    /// plus an engine deck in a unit test would prove less and break more.
    func testBothBlendPathsRefuseWhileTheEngineDeckIsAttached() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BatonPlaybackKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // BatonPlaybackKit
            .appendingPathComponent("Sources/BatonPlaybackKit/StreamingPlaybackController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        func body(of function: String) throws -> String {
            let start = try XCTUnwrap(source.range(of: function), "\(function) not found")
            let rest = source[start.upperBound...]
            // Up to the next function at the same indentation — enough to cover the guards.
            let end = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    public func ")
            return String(end.map { rest[..<$0.lowerBound] } ?? rest)
        }

        let manualSkip = try body(of: "private func beginSkipBlend")
        XCTAssertTrue(
            manualSkip.contains("engineDeck == nil"),
            "beginSkipBlend does not refuse on the engine deck — Next will advance the UI while the old track keeps playing"
        )

        let autoCrossfade = try body(of: "private func maybeStartCrossfade")
        XCTAssertTrue(
            autoCrossfade.contains("!engineOwnsPlayback"),
            "maybeStartCrossfade does not refuse on the engine deck"
        )
    }

    /// Only one thing may publish the playhead at a time.
    ///
    /// The AVPlayer periodic observer writes `currentTime` from
    /// `streamStartOffset + time.seconds`. It stays installed while the engine deck owns
    /// playback, and on a track change it can fire with a zeroed player clock while
    /// `streamStartOffset` still holds the *previous* track's offset — so it publishes the
    /// old position, and the engine's own tick corrects it to zero a moment later. On every
    /// Next, the playhead jumps somewhere and snaps back.
    ///
    /// This is why fixing the engine's stale tick did not end the symptom: two writers of
    /// one value, and only one of them had been fixed. Asserted on the source because
    /// driving a real AVPlayer observer while an engine deck owns playback needs both
    /// engines live, which proves less and breaks more than reading the guard.
    @MainActor
    func testTheAVPlayerClockStandsDownWhileTheEngineOwnsPlayback() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BatonPlaybackKit/StreamingPlaybackController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        let observer = try XCTUnwrap(source.range(of: "addPeriodicTimeObserver"),
                                     "the periodic observer has moved or been renamed")
        let body = String(source[observer.upperBound...].prefix(3000))

        let guardRange = try XCTUnwrap(
            body.range(of: "guard !self.engineOwnsPlayback else { return }"),
            "the AVPlayer clock no longer stands down for the engine deck — the playhead will jump on every track change"
        )
        let publish = try XCTUnwrap(body.range(of: "self.currentTime = playhead"),
                                    "the observer no longer publishes the playhead")
        XCTAssertTrue(
            guardRange.upperBound < publish.lowerBound,
            "the engine guard sits after the playhead is published, so the stale value is written anyway"
        )
    }


    /// A radio queue must not open with the same track twice.
    ///
    /// Reported with a screenshot: "Painting Yellow" listed twice at the top of the queue,
    /// both rows showing the now-playing bars, because both carry the same song id.
    ///
    /// Four places build a radio queue as `[seed] + similar`, and exactly one of them
    /// filtered the seed out of `similar`. That is the shape this codebase keeps paying for
    /// — nine Shuffle call sites, eleven layout keys, twelve now-playing indicators — so the
    /// fix belongs at the source rather than in the fourth caller: `similarSongs` never
    /// returns the seed, and all four are correct at once, along with the "related" and
    /// "because you liked" shelves that were showing it too.
    @MainActor
    func testSimilarSongsNeverReturnsTheSeedItself() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BatonPlaybackKit/MusicLibraryStore.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        let start = try XCTUnwrap(source.range(of: "public func similarSongs(seedID: String)"),
                                  "similarSongs has moved or been renamed")
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    /// "), "could not bound the function body")
        let body = String(rest[..<end.lowerBound])

        // Every return path — demo, similar, and the random fallback — has to exclude it.
        let filters = body.components(separatedBy: "id != seedID").count - 1
        XCTAssertGreaterThanOrEqual(
            filters, 3,
            """
            a return path in similarSongs can hand back the seed. Whichever one it is, the \
            radio queue it feeds will open with the same track twice and show the \
            now-playing indicator on both rows.
            """
        )
    }


    /// The equalizer must not claim to affect music it cannot affect.
    ///
    /// The tap it rides does not run for a streamed item, so on the standard player it
    /// reaches downloads and nothing else — while the Mac's Settings said "applied to
    /// everything Baton plays" and the phone's said nothing at all. A control that looks
    /// like it works and doesn't is worse than a missing one: a missing feature gets asked
    /// for, a decorative one just makes people doubt their ears.
    ///
    /// One sentence, shared by both apps, so the two cannot drift — and so that switching
    /// the experimental engine on changes the answer in both places at once.
    func testTheEqualizerSaysWhereItActuallyApplies() {
        let standard = MusicEqualizer.scopeExplanation(experimentalEngineEnabled: false)
        XCTAssertTrue(standard.lowercased().contains("download"),
                      "the standard-player answer does not mention downloads, which is the only thing it reaches")
        XCTAssertTrue(standard.lowercased().contains("stream"),
                      "the standard-player answer does not mention streamed music, which is what it cannot reach")

        let engine = MusicEqualizer.scopeExplanation(experimentalEngineEnabled: true)
        XCTAssertNotEqual(standard, engine,
                          "the answer does not change when the engine is on — then one of the two is a lie")
        XCTAssertTrue(engine.lowercased().contains("everything"),
                      "with the engine on the equalizer does reach everything, and should say so")
    }

}
