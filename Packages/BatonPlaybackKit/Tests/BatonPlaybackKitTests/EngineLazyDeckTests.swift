import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// The deck can arrive late, because on iOS it has to.
///
/// The Mac builds its engine deck in the composition root and hands it over fully formed.
/// The phone cannot: an `AVAudioEngine` will not start until the `AVAudioSession` is
/// active, and activating the session at launch cuts off whatever the user is already
/// listening to — Spotify, a podcast — before they have asked Baton for anything. Those
/// two rules genuinely conflict, and `engineDeckProvider` is what resolves them: the host
/// supplies a closure that runs at the first moment a routable track is about to play.
///
/// Every rule below decides, in production, whether someone's equalizer works or silently
/// does nothing — the exact failure the engine exists to end. None of them is observable
/// without driving real audio, so they are pinned here.
@MainActor
final class EngineLazyDeckTests: XCTestCase {

    private let suiteName = "io.tonebox.tests.lazydeck"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()

    /// An offline pipeline: a real deck, no audio hardware, no output device.
    private func makeBridge() throws -> (EngineDeckBridge, EngineAudioPipeline) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 2, interleaved: false)!
        let pipeline = try EngineAudioPipeline(outputMode: .offline(format: format, maxFrames: 4096))
        return (EngineDeckBridge(pipeline: pipeline), pipeline)
    }

    private func makeController() -> StreamingPlaybackController {
        StreamingPlaybackController(
            streamURLProvider: { id in URL(string: "http://127.0.0.1:1/\(id)")! },
            defaults: suite,
            systemNowPlaying: false
        )
    }

    /// Installing a provider must not build anything. On the phone, building is what
    /// activates the audio session — so a provider that ran at launch would interrupt
    /// another app's playback merely because Baton had been opened.
    func testInstallingAProviderBuildsNothing() throws {
        let controller = makeController()
        var calls = 0
        controller.engineDeckProvider = { calls += 1; return nil }
        XCTAssertEqual(calls, 0, "the provider ran at install time — on iOS that activates the audio session unasked")
    }

    func testTheProviderRunsOnceAndItsDeckIsAdopted() throws {
        let controller = makeController()
        let (bridge, pipeline) = try makeBridge()
        defer { bridge.stop(); pipeline.shutdown() }

        var calls = 0
        controller.engineDeckProvider = { calls += 1; return bridge }

        let first = controller.resolveEngineDeckForTesting()
        XCTAssertTrue(first === bridge, "the provider's deck was not adopted")
        XCTAssertEqual(calls, 1)

        // Second and third resolutions reuse it. A provider run per track would build an
        // audio engine per track.
        XCTAssertTrue(controller.resolveEngineDeckForTesting() === bridge)
        XCTAssertTrue(controller.resolveEngineDeckForTesting() === bridge)
        XCTAssertEqual(calls, 1, "the provider ran more than once")
    }

    /// A provider that fails — no output, engine refused to start — degrades to AVPlayer
    /// permanently rather than retrying on every track. Retrying would mean an engine
    /// construction attempt (and on iOS a session activation) at every track change, for
    /// a device that has already said no.
    func testAFailedProviderIsNotRetried() throws {
        let controller = makeController()
        var calls = 0
        controller.engineDeckProvider = { calls += 1; return nil }

        XCTAssertNil(controller.resolveEngineDeckForTesting())
        XCTAssertNil(controller.resolveEngineDeckForTesting())
        XCTAssertNil(controller.resolveEngineDeckForTesting())
        XCTAssertEqual(calls, 1, "a refusing provider is being retried on every track")
    }

    /// Detaching re-arms the provider. This is the iOS media-services-reset path: the
    /// audio server dies, every CoreAudio object the app holds becomes a dead handle, and
    /// recovery is precisely "throw the deck away and let the next track build a fresh
    /// one". A one-shot latch would refuse that and leave the phone silently on AVPlayer —
    /// no error, no sound from the equalizer — until the app was relaunched.
    func testDetachingRearmsTheProviderSoAResetCanRecover() throws {
        let controller = makeController()
        let (first, firstPipeline) = try makeBridge()
        let (second, secondPipeline) = try makeBridge()
        defer {
            first.stop(); firstPipeline.shutdown()
            second.stop(); secondPipeline.shutdown()
        }

        var built: [EngineDeckBridge] = [first, second]
        var calls = 0
        controller.engineDeckProvider = {
            calls += 1
            return built.isEmpty ? nil : built.removeFirst()
        }

        XCTAssertTrue(controller.resolveEngineDeckForTesting() === first)
        XCTAssertEqual(calls, 1)

        // Media services reset: the host detaches the corpse.
        controller.attachEngineDeck(nil)

        XCTAssertTrue(
            controller.resolveEngineDeckForTesting() === second,
            "after a detach the provider was never asked again — a reset would strand the phone on AVPlayer until relaunch"
        )
        XCTAssertEqual(calls, 2)
    }

    /// Whether a track is engine-routable must be settled BEFORE the deck is resolved.
    ///
    /// Reversed, the phone would build an audio engine — and activate the audio session —
    /// to discover the track was a podcast, which routes to AVPlayer anyway. The cost is
    /// invisible on the Mac, where the deck already exists, which is exactly why it needs
    /// pinning rather than trusting: the ordering is load-bearing only on the platform the
    /// gate cannot run.
    func testRoutabilityIsDecidedBeforeTheDeckIsBuilt() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BatonPlaybackKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // BatonPlaybackKit
            .appendingPathComponent("Sources/BatonPlaybackKit/StreamingPlaybackController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        let canPlay = try XCTUnwrap(
            source.range(of: "EngineDeckBridge.canPlay(songID: song.id, url: engineURL)"),
            "the routing site's canPlay check has moved or been renamed"
        )
        let resolve = try XCTUnwrap(
            source.range(of: "let deck = resolveEngineDeck()"),
            "the routing site no longer resolves the deck lazily"
        )
        XCTAssertTrue(
            canPlay.upperBound < resolve.lowerBound,
            "the deck is resolved before routability is known — on iOS that activates the audio session to play a podcast"
        )
    }
}
