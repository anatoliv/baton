import XCTest
@testable import BatonPlaybackKit

/// Resolved audio-focus handles were kept for good, one per spoken summary or dictation
/// They are kept for the time bound, to answer a repeated resume, and
/// then dropped by the periodic sweep.
@MainActor
final class AudioFocusRegistryPruneTests: XCTestCase {
    func testResolvedHandlesAreDroppedAfterTheTimeBound() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let registry = BatonAudioFocusRegistry(now: { clock })
        let suite = UserDefaults(suiteName: "io.tonebox.tests.focusprune")!
        suite.removePersistentDomain(forName: "io.tonebox.tests.focusprune")
        let music = StreamingPlaybackController(defaults: suite, systemNowPlaying: false)

        let handle = registry.suspend(owner: "summary", on: music)["handle"] as! String
        _ = registry.resume(handle: handle, on: music)
        XCTAssertEqual(registry.resume(handle: handle, on: music)["reason"] as? String, "already-resumed",
                       "a repeated resume is still answered within the bound")

        clock = clock.addingTimeInterval(BatonAudioFocusRegistry.handleMaxAge + 1)
        registry.expireStaleHandles(on: music)
        XCTAssertEqual(registry.storedHandleCountForTesting, 0, "a resolved handle was kept for good")
    }
}
