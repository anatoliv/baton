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
    /// The guard is a source-level invariant: both blend entry points must refuse while the
    /// engine owns playback. Asserted on the source because constructing a live AVPlayer
    /// queue plus an engine deck in a unit test would prove less and break more.
    ///
    /// Anchored through `SourceInvariant`, which matches `func <name>` and bounds the body
    /// by its braces. The previous version pinned `"private func beginSkipBlend"` and cut
    /// the body at the next `private func` — so making either function `internal`, or
    /// giving it an attribute, would have reported a skip-blend regression that had not
    /// happened.
    func testBothBlendPathsRefuseWhileTheEngineOwnsPlayback() throws {
        let source = try SourceInvariant.source("StreamingPlaybackController.swift")

        let manualSkip = try SourceInvariant.functionBody(of: "beginSkipBlend", in: source)
        // Ownership, not attachment. This used to pin the literal `engineDeck == nil`, and
        // that predicate was broader than its own rationale: it disabled the blend for
        // downloads too, from the moment a deck existed, on both apps. (Podcasts lost
        // nothing — they have always had their own `isPodcastEpisode` guard.) The asymmetry
        // with `maybeStartCrossfade`'s narrower `!engineOwnsPlayback` — asserted below,
        // unchanged — was the tell that one of them was wrong.
        SourceInvariant.assert(
            manualSkip, contains: "!engineOwnsPlayback",
            rule: "a manual skip refuses to blend while the engine owns playback, or Next advances the UI while the old track keeps playing",
            within: "the body of `beginSkipBlend`"
        )
        // And the incoming half: a track that would route to the deck must not be blended
        // into as an AVPlayer item, or the wrong renderer ends up playing it.
        SourceInvariant.assert(
            manualSkip, contains: "EngineDeckBridge.canPlay",
            rule: "a manual skip checks whether the incoming track belongs on the deck",
            within: "the body of `beginSkipBlend`"
        )

        let autoCrossfade = try SourceInvariant.functionBody(of: "maybeStartCrossfade", in: source)
        SourceInvariant.assert(
            autoCrossfade, contains: "!engineOwnsPlayback",
            rule: "the automatic end-of-track crossfade refuses while the engine owns playback",
            within: "the body of `maybeStartCrossfade`"
        )
    }

    /// Only one thing may publish the playhead at a time.
    ///
    /// The AVPlayer periodic observer writes the playhead from
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
    ///
    /// **The anchor moved with the rule** (Stage 5b): the observer is now `AVPlayerDeck`'s,
    /// it reports rather than publishes, and the ownership gate sits once on the callback
    /// wiring instead of twice at the top of two observer bodies. Both halves are pinned
    /// here — the gate, and the deck's own structural stand-down.
    @MainActor
    func testTheAVPlayerClockStandsDownWhileTheEngineOwnsPlayback() throws {
        // The host half: every deck's clock callback is gated on whether that deck is the
        // one that owns playback, so only one of them can ever reach the single clock body.
        let wiring = try SourceInvariant.functionBody(
            of: "wire", in: try SourceInvariant.source("StreamingPlaybackController.swift")
        )
        try SourceInvariant.assert(
            wiring,
            has: "engineOwnsPlayback == isEngine",
            before: "handleClock",
            rule: "a deck's clock only reaches the host while that deck owns playback, or the playhead has two publishers and jumps on every track change",
            within: "the body of `wire`"
        )

        // The deck half: an emptied queue stands the observer down entirely. The engine
        // taking a track calls `clear()`, so this is structural rather than a flag someone
        // has to remember to check.
        //
        // Bounded by braces, not by a character count. This was a `prefix(3000)` window and
        // it failed on correct code the moment the guard above it grew a comment — the
        // fourth time in one day a test written that way had cried wolf. A window sized by
        // guesswork tests the guess.
        let observer = try SourceInvariant.closureBody(
            after: "addPeriodicTimeObserver", in: try SourceInvariant.source("AVPlayerDeck.swift")
        )
        try SourceInvariant.assert(
            observer,
            has: "guard self.player.currentItem != nil else { return }",
            before: "self.onClock?",
            rule: "the AVPlayer clock stands down before reporting when it has no item, or it republishes a stale stream offset over the engine's playhead",
            within: "the periodic time observer in `AVPlayerDeck`"
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
        let source = try SourceInvariant.source("MusicLibraryStore.swift")
        // Anchored on the name alone. It used to pin `"public func similarSongs(seedID: String)"`
        // — the visibility *and* the full parameter list — so adding a `limit:` argument
        // would have reported a duplicate-seed regression instead of a signature change.
        // The old bound was the next doc comment, which is a convention rather than a
        // structure; this one is the closing brace.
        let body = try SourceInvariant.functionBody(of: "similarSongs", in: source)

        // Every return path — demo, similar, and the random fallback — has to exclude it.
        let filters = body.components(separatedBy: "id != seedID").count - 1
        XCTAssertGreaterThanOrEqual(
            filters, 3,
            SourceInvariant.Failure(
                rule: """
                every return path in `similarSongs` excludes the seed, or the radio queue it \
                feeds opens with the same track twice and shows the now-playing indicator on \
                both rows
                """,
                searched: "at least 3 occurrences of `id != seedID` in the body of `similarSongs`, and found \(filters)",
                file: #filePath, line: #line
            ).message
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

/// Only one thing may publish the playhead during a skip blend either.
///
/// The engine-side fix stopped AVPlayer's clock writing over an engine-owned playhead. This
/// is the same bug between two AVPlayers, which is where it was actually being seen: a skip
/// advances the transport and zeroes the playhead immediately, but the periodic observer
/// stays attached to the *outgoing* player until the incoming one is promoted, so it kept
/// publishing the old track's position over that zero — the bar jumping to wherever the
/// previous track had reached and snapping back a moment later.
///
/// Asserted on the source: reproducing it needs two live AVPlayers mid-ramp, which proves
/// less than reading the guard and breaks far more often.
@MainActor
final class SkipBlendPlayheadTests: XCTestCase {
    private func controllerSource() throws -> String {
        try SourceInvariant.source("StreamingPlaybackController.swift")
    }

    /// Bounded by braces, not by a character count. Three tests in one day were written with
    /// `prefix(n)` windows and all three failed on correct code the moment a comment grew —
    /// the guard was still there, just past the window.
    ///
    /// The anchor moved with the rule (Stage 5b): there is one clock body now, `handleClock`,
    /// so the guard is asserted there rather than inside the AVPlayer observer. The deck
    /// carries its own copy against its own ramp, pinned below.
    func testTheClockStandsDownDuringASkipBlend() throws {
        let clock = try SourceInvariant.functionBody(of: "handleClock", in: try controllerSource())
        try SourceInvariant.assert(
            clock,
            has: "guard !isCrossfading else { return }",
            before: "currentTime = time",
            rule: "the clock stands down before publishing during a skip blend, or the playhead jumps to the outgoing track's position",
            within: "the body of `handleClock`"
        )

        let observer = try SourceInvariant.closureBody(
            after: "addPeriodicTimeObserver", in: try SourceInvariant.source("AVPlayerDeck.swift")
        )
        try SourceInvariant.assert(
            observer,
            has: "guard !self.crossfadeRamp.isActive else { return }",
            before: "self.onClock?",
            rule: "the deck's own clock stands down while its ramp is running, or the outgoing player reports over the incoming track's zero",
            within: "the periodic time observer in `AVPlayerDeck`"
        )
    }

    /// The offset the clock adds must be cleared when the blended-in player is promoted, or
    /// the new track's clock is read against the old track's starting point.
    ///
    /// It used to be cleared in `beginSkipBlend`, at the top of the blend. It now happens in
    /// `AVPlayerDeck.promoteCrossfade`, at the bottom — which is the moment the offset
    /// actually stops applying, since until then the outgoing stream is still sounding.
    func testTheSkipClearsTheStreamOffset() throws {
        let promotion = try SourceInvariant.functionBody(
            of: "promoteCrossfade", in: try SourceInvariant.source("AVPlayerDeck.swift")
        )
        SourceInvariant.assert(
            promotion, contains: "streamStartOffset = 0",
            rule: "promoting a blended-in player clears the stream offset, or a skip after an offset load re-adds the old offset to the new track's clock",
            within: "the body of `promoteCrossfade`"
        )

        let body = try SourceInvariant.functionBody(of: "beginSkipBlend", in: try controllerSource())
        SourceInvariant.assert(
            body, contains: "lastClockSample = nil",
            rule: "a skip resets the listening accumulator, or it carries the outgoing track's last position into the new one",
            within: "the body of `beginSkipBlend`"
        )
    }
}
