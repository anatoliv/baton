import AVFoundation
import XCTest
@testable import Baton

/// Hardening coverage for the cross-process audio-focus primitive (§4 of the integration
/// spec) and the Unix-socket fast-path (§7):
///   - real **duck** mode lowers then restores the exact player volume;
///   - the generation guard still declines a resume after the user changed state;
///   - **handle expiry** on client disconnect auto-resumes a paused/ducked player;
///   - **crash recovery** restores a persisted pre-duck volume on next launch;
///   - the socket protocol round-trips and completes well under 50 ms.
///
/// A standalone `StreamingPlaybackController` is seeded exactly as
/// `StreamingPlaybackControllerTests` does (injected file URL provider, no system Now
/// Playing), so transport state flips synchronously with no real streaming.
@MainActor
final class AudioFocusHardeningTests: XCTestCase {
    private let suiteName = "io.tonebox.tests.audiofocushardening"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()

    private func makeController(defaults: UserDefaults? = nil) -> StreamingPlaybackController {
        StreamingPlaybackController(
            streamURLProvider: { _ in URL(string: "file:///dev/null")! },
            defaults: defaults ?? suite,
            systemNowPlaying: false
        )
    }

    private func song(_ id: String) -> NavidromeSong {
        NavidromeSong(id: id, title: "Song \(id)", artist: "Artist", album: nil, duration: nil, coverArtID: nil)
    }

    /// Effective AVPlayer volume the controller pushed (0…1), for asserting the duck.
    private func playerVolume(_ c: StreamingPlaybackController) -> Float {
        // No public accessor; the duck records/restores `volumePercent`, which is the
        // user-visible level we assert against. AVPlayer.volume tracks it 1:1 (no loudness
        // norm on our test songs, no fade), so `volumePercent` is the ground truth.
        Float(c.volumePercent) / 100
    }

    // MARK: - 1. Real duck mode

    func testDuckLowersAndRestoresVolume() {
        let c = makeController()
        c.setVolume(percent: 80)
        c.play([song("a")])
        XCTAssertEqual(c.state, .playing)

        let registry = BatonAudioFocusRegistry()
        let out = registry.suspend(owner: "dictation", mode: .duck, duckToPercent: 20, on: c)
        let handle = out["handle"] as! String
        XCTAssertEqual(out["suspended"] as? Bool, true)
        XCTAssertEqual(out["mode"] as? String, "duck")
        // Ducked: still playing (not paused), but the stored level dropped to the target.
        XCTAssertEqual(c.state, .playing)
        XCTAssertEqual(c.volumePercent, 20)

        let resume = registry.resume(handle: handle, on: c)
        XCTAssertEqual(resume["resumed"] as? Bool, true)
        // Restored to the exact pre-duck level.
        XCTAssertEqual(c.volumePercent, 80)
        XCTAssertEqual(c.state, .playing)
    }

    func testDuckNoOpWhenNotPlaying() {
        let c = makeController()
        c.setVolume(percent: 70)
        // Nothing playing → duck is a clean no-op.
        let registry = BatonAudioFocusRegistry()
        let out = registry.suspend(owner: "dictation", mode: .duck, duckToPercent: 20, on: c)
        XCTAssertEqual(out["suspended"] as? Bool, false)
        XCTAssertEqual(c.volumePercent, 70)
    }

    // MARK: - 2. Generation guard (resume after user-changed state)

    func testDuckResumeDoesNotRestoreAfterUserChangedVolume() {
        let c = makeController()
        c.setVolume(percent: 80)
        c.play([song("a")])
        let registry = BatonAudioFocusRegistry()
        let out = registry.suspend(owner: "dictation", mode: .duck, duckToPercent: 20, on: c)
        let handle = out["handle"] as! String
        XCTAssertEqual(c.volumePercent, 20)

        // User intervenes: bumps the generation (setVolume is user-facing).
        c.setVolume(percent: 55)
        XCTAssertEqual(c.volumePercent, 55)

        // Resume must NOT clobber the user's level back to 80 — the guard declines.
        let resume = registry.resume(handle: handle, on: c)
        XCTAssertEqual(resume["resumed"] as? Bool, false)
        XCTAssertEqual(c.volumePercent, 55, "user's post-duck volume must be preserved")
    }

    func testPauseResumeDoesNotResumeAfterUserStopped() {
        let c = makeController()
        c.play([song("a")])
        let registry = BatonAudioFocusRegistry()
        let out = registry.suspend(owner: "dictation", mode: .pause, on: c)
        let handle = out["handle"] as! String
        XCTAssertEqual(c.state, .paused)

        // User stops in the interim — generation moves, state is no longer .paused-by-us.
        c.stop()
        XCTAssertEqual(c.state, .idle)

        let resume = registry.resume(handle: handle, on: c)
        XCTAssertEqual(resume["resumed"] as? Bool, false)
        XCTAssertEqual(resume["reason"] as? String, "user-changed-state")
        XCTAssertEqual(c.state, .idle)
    }

    // MARK: - 3. Handle expiry on client disconnect

    func testExpireHandlesAutoResumesPausedPlayer() {
        let c = makeController()
        c.play([song("a")])
        let registry = BatonAudioFocusRegistry()
        _ = registry.suspend(owner: "dictation", mode: .pause, connectionID: "sess-1", on: c)
        XCTAssertEqual(c.state, .paused)

        // The client's stream closes → its handles expire → paused player auto-resumes.
        let n = registry.expireHandles(forConnection: "sess-1", on: c)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(c.state, .playing, "a crashed client must not leave music paused forever")
        XCTAssertEqual(registry.liveHandleCount, 0)
    }

    func testExpireHandlesAutoRestoresDuckedPlayer() {
        let c = makeController()
        c.setVolume(percent: 90)
        c.play([song("a")])
        let registry = BatonAudioFocusRegistry()
        _ = registry.suspend(owner: "dictation", mode: .duck, duckToPercent: 15, connectionID: "sess-2", on: c)
        XCTAssertEqual(c.volumePercent, 15)

        let n = registry.expireHandles(forConnection: "sess-2", on: c)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(c.volumePercent, 90, "handle expiry must restore the ducked volume")
    }

    func testExpireOnlyTargetsMatchingConnection() {
        let c = makeController()
        c.play([song("a")])
        let registry = BatonAudioFocusRegistry()
        _ = registry.suspend(owner: "dictation", mode: .pause, connectionID: "sess-A", on: c)
        // A different session's disconnect must not expire this handle.
        let n = registry.expireHandles(forConnection: "sess-B", on: c)
        XCTAssertEqual(n, 0)
        XCTAssertEqual(c.state, .paused)
        XCTAssertEqual(registry.liveHandleCount, 1)
    }

    func testStaleHandleExpiresPastTimeBound() {
        // Drive the clock so a handle ages past the 10-minute time-bound without waiting.
        var fakeNow = Date()
        let registry = BatonAudioFocusRegistry(now: { fakeNow })
        let c = makeController()
        c.play([song("a")])
        _ = registry.suspend(owner: "orphan", mode: .pause, connectionID: nil, on: c)
        XCTAssertEqual(c.state, .paused)

        // Not yet stale.
        XCTAssertEqual(registry.expireStaleHandles(on: c), 0)
        XCTAssertEqual(c.state, .paused)

        // Advance past the max age → the orphaned handle auto-expires and resumes.
        fakeNow = fakeNow.addingTimeInterval(BatonAudioFocusRegistry.handleMaxAge + 1)
        XCTAssertEqual(registry.expireStaleHandles(on: c), 1)
        XCTAssertEqual(c.state, .playing)
    }

    // MARK: - 4. Crash recovery

    func testCrashRecoveryRestoresStrandedDuckVolume() {
        // Session 1: duck, then "crash" (drop the controller without releasing focus).
        let store = UserDefaults(suiteName: "\(suiteName).crash")!
        store.removePersistentDomain(forName: "\(suiteName).crash")

        do {
            let c1 = makeController(defaults: store)
            c1.setVolume(percent: 85)
            c1.play([song("a")])
            let registry = BatonAudioFocusRegistry()
            _ = registry.suspend(owner: "dictation", mode: .duck, duckToPercent: 10, on: c1)
            XCTAssertEqual(c1.volumePercent, 10)
            // Persisted the pre-duck level; c1 goes away WITHOUT a resume (simulated crash).
        }

        // The persisted volume on disk still reflects the ducked level (10) — a naive
        // relaunch would strand the user quiet.
        XCTAssertEqual(store.integer(forKey: StreamingPlaybackController.volumeKey), 10)

        // Session 2: a fresh controller runs crash recovery in init and restores 85.
        let c2 = makeController(defaults: store)
        XCTAssertEqual(c2.volumePercent, 85, "crash recovery must restore the pre-duck volume")
        // Record cleared so a third launch doesn't re-restore.
        XCTAssertNil(store.object(forKey: StreamingPlaybackController.activeSuspendVolumeKey))
    }

    func testCleanResumeLeavesNoCrashRecord() {
        let store = UserDefaults(suiteName: "\(suiteName).clean")!
        store.removePersistentDomain(forName: "\(suiteName).clean")
        let c = makeController(defaults: store)
        c.setVolume(percent: 75)
        c.play([song("a")])
        let registry = BatonAudioFocusRegistry()
        let out = registry.suspend(owner: "dictation", mode: .duck, duckToPercent: 20, on: c)
        _ = registry.resume(handle: out["handle"] as! String, on: c)
        // A clean release clears the pending record — no phantom recovery next launch.
        XCTAssertNil(store.object(forKey: StreamingPlaybackController.activeSuspendVolumeKey))
    }

    // MARK: - 5. Fast-path socket round-trip + latency

    func testSocketRoundTripInteroperatesWithRegistry() {
        // The socket shares the SAME registry as the MCP path: a socket SUSPEND yields a
        // handle a subsequent registry (MCP) RESUME can redeem.
        let c = makeController()
        c.play([song("a")])
        let registry = BatonAudioFocusRegistry()
        let socket = BatonControlSocket.makeForTesting(focus: registry, controller: c)

        let suspendReply = socket.dispatchLine("SUSPEND dictation pause", connectionID: "conn-1")
        XCTAssertTrue(suspendReply.hasPrefix("HANDLE "), "got: \(suspendReply)")
        XCTAssertEqual(c.state, .paused)
        let handle = suspendReply
            .replacingOccurrences(of: "HANDLE ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Cross-transport: resume via the registry (the MCP path) — must interoperate.
        let resume = registry.resume(handle: handle, on: c)
        XCTAssertEqual(resume["resumed"] as? Bool, true)
        XCTAssertEqual(c.state, .playing)
    }

    func testSocketDuckRoundTrip() {
        let c = makeController()
        c.setVolume(percent: 80)
        c.play([song("a")])
        let registry = BatonAudioFocusRegistry()
        let socket = BatonControlSocket.makeForTesting(focus: registry, controller: c)

        let reply = socket.dispatchLine("SUSPEND dictation duck 25", connectionID: "conn-2")
        XCTAssertTrue(reply.hasPrefix("HANDLE "))
        XCTAssertEqual(c.volumePercent, 25)
        let handle = reply.replacingOccurrences(of: "HANDLE ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

        let resume = socket.dispatchLine("RESUME \(handle)", connectionID: "conn-2")
        XCTAssertEqual(resume, "OK\n")
        XCTAssertEqual(c.volumePercent, 80)
    }

    func testSocketRoundTripLatencyUnderBudget() {
        let c = makeController()
        c.play([song("a")])
        let registry = BatonAudioFocusRegistry()
        let socket = BatonControlSocket.makeForTesting(focus: registry, controller: c)

        // Warm up (first call pays one-time allocation costs).
        let warm = socket.dispatchLine("SUSPEND dictation pause", connectionID: "warm")
        _ = socket.dispatchLine("RESUME \(warm.replacingOccurrences(of: "HANDLE ", with: "").trimmingCharacters(in: .whitespacesAndNewlines))", connectionID: "warm")

        // Measured suspend→resume round-trip with a monotonic clock.
        let start = DispatchTime.now()
        let suspendReply = socket.dispatchLine("SUSPEND dictation pause", connectionID: "timed")
        let handle = suspendReply.replacingOccurrences(of: "HANDLE ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        _ = socket.dispatchLine("RESUME \(handle)", connectionID: "timed")
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000

        print("MEASURED socket suspend→resume round-trip: \(String(format: "%.4f", elapsedMS)) ms")
        XCTAssertLessThan(elapsedMS, 50, "fast-path round-trip must be well under 50 ms")
    }
}
