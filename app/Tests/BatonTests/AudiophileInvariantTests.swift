import XCTest
@testable import Baton

/// F3 — regression guards for the audiophile "crown jewels" (docs/09 finding on the
/// audiophile cluster: it's over-delivered and *correct* — keep it). The EQ bit-exact
/// math and the ReplayGain math are already covered (`EqualizerDSPTests`,
/// `MusicLoudnessTests`); these fill the two gaps that had no guard: the
/// **gapless ⊕ crossfade mutual-exclusivity** invariant and **EQ-off-by-default**.
@MainActor
final class AudiophileInvariantTests: XCTestCase {
    private let suiteName = "io.tonebox.tests.audiophileinvariant"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()

    private func makeController() -> StreamingPlaybackController {
        StreamingPlaybackController(
            streamURLProvider: { _ in URL(string: "file:///dev/null")! },
            defaults: suite,
            systemNowPlaying: false
        )
    }

    // MARK: - Gapless ⊕ crossfade are mutually exclusive

    /// True-gapless is active only when it's enabled *and* crossfade is effectively off
    /// (< 0.05 s). Crossfade always wins — the two transition strategies can't both run.
    func testGaplessAndCrossfadeAreMutuallyExclusive() {
        let c = makeController()

        c.gaplessEnabled = false; c.crossfadeSeconds = 0
        XCTAssertFalse(c.isGaplessModeForTesting, "gapless off, no crossfade → not gapless")

        c.gaplessEnabled = true; c.crossfadeSeconds = 0
        XCTAssertTrue(c.isGaplessModeForTesting, "gapless on, no crossfade → gapless active")

        c.gaplessEnabled = true; c.crossfadeSeconds = 2
        XCTAssertFalse(c.isGaplessModeForTesting, "crossfade set → crossfade wins, gapless yields")

        c.gaplessEnabled = false; c.crossfadeSeconds = 2
        XCTAssertFalse(c.isGaplessModeForTesting, "gapless off + crossfade → not gapless")
    }

    /// The 0.05 s threshold is the boundary: just under counts as gapless, at/over doesn't.
    func testCrossfadeThresholdBoundary() {
        let c = makeController()
        c.gaplessEnabled = true

        c.crossfadeSeconds = 0.04
        XCTAssertTrue(c.isGaplessModeForTesting, "sub-threshold crossfade is still gapless")

        c.crossfadeSeconds = 0.05
        XCTAssertFalse(c.isGaplessModeForTesting, "at the threshold, crossfade takes over")
    }

    // MARK: - Equalizer is off by default (bit-exact pass-through until asked otherwise)

    func testEqualizerDisabledByDefault() {
        let eq = MusicEqualizer(defaults: suite)
        XCTAssertFalse(eq.isEnabled, "the EQ must ship OFF so playback is bit-exact until the user opts in")
    }
}
