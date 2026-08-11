import AVFoundation
import XCTest
@testable import BatonMobile
@testable import BatonPlaybackKit

/// The phone-only half of the engine: the `AVAudioSession` rules that have no macOS
/// equivalent, and which the Mac gate therefore cannot possibly catch.
///
/// Three things are true on iOS and not on the Mac. An `AVAudioEngine` will not start
/// without an active session. Activating the session interrupts whatever else is playing.
/// And the audio server can be reset out from under the app, leaving every CoreAudio
/// object a dead handle. The wiring in `MobileModel` and `MobileAudioSession` exists for
/// those three facts, so it is tested against those three facts.
@MainActor
final class EngineSessionWiringTests: XCTestCase {

    // MARK: - The session must not be activated before the user asks for audio

    /// Baton configures a category at launch and deliberately does NOT activate. Cold
    /// launch while Spotify is playing must leave Spotify playing.
    ///
    /// Asserted against the real session: `configure()` sets the category and nothing
    /// else, so `isOtherAudioPlaying` and our own activation state are untouched.
    func testConfiguringDoesNotActivateTheSession() {
        let controller = StreamingPlaybackController(systemNowPlaying: false)
        let session = MobileAudioSession(controller: controller)

        session.configure()

        XCTAssertEqual(
            AVAudioSession.sharedInstance().category, .playback,
            "the category was not declared — the app cannot play in the background"
        )
        // Activation is observable through the session's own route: an inactive session
        // holds no route inputs/outputs it did not already have. The stronger statement —
        // "another app is still playing" — needs another app, so the guard here is that
        // configure() never calls setActive, asserted at the source below.
    }

    /// The rule above is one line away from being lost, and losing it is silent: everything
    /// works, except that opening Baton stops someone's podcast. Pin it in the source.
    func testConfigureNeverActivates() throws {
        let source = try sourceOf("MobileAudioSession.swift")
        let configure = try body(of: "func configure()", in: source)
        XCTAssertFalse(
            configure.contains("setActive"),
            "configure() activates the session — cold launch will interrupt whatever the user is already listening to"
        )
    }

    // MARK: - Media services reset

    /// A reset must reach the host, or the engine stays a dead handle: no sound, no error.
    func testMediaServicesResetIsObservedAndForwarded() async throws {
        let controller = StreamingPlaybackController(systemNowPlaying: false)
        let session = MobileAudioSession(controller: controller)
        session.configure()

        var resets = 0
        session.onMediaServicesReset = { resets += 1 }

        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )
        // The observer hops to the main actor via a Task; let it land.
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(resets, 1, "a media-services reset never reached the host — the engine would stay dead until relaunch")
    }

    /// Recovery is "detach and re-arm", not "rebuild now". Rebuilding immediately would
    /// activate the session while the user is not playing anything.
    func testResetRecoveryDetachesAndRearmsRatherThanRebuilding() throws {
        let source = try sourceOf("MobileModel.swift", inSources: true)
        let recover = try body(of: "private func rebuildEngineAfterReset()", in: source)

        XCTAssertTrue(recover.contains("attachEngineDeck(nil)"),
                      "the dead deck is not detached, so the controller keeps routing to a corpse")
        XCTAssertTrue(recover.contains("installExperimentalEngineIfEnabled()"),
                      "the provider is not re-armed, so the phone stays on AVPlayer until relaunch")
        XCTAssertFalse(recover.contains("deviceBridge()"),
                       "recovery builds an engine immediately — that activates the audio session behind the user's back")
    }

    // MARK: - The provider builds late, and activates as it does

    /// The provider is the one place allowed to activate the session, and it must activate
    /// *before* building: an `AVAudioEngine` started against an inactive session produces
    /// silence rather than an error, which is the worst of both.
    func testTheProviderActivatesBeforeBuilding() throws {
        let source = try sourceOf("MobileModel.swift", inSources: true)
        let install = try body(of: "private func installExperimentalEngineIfEnabled(force:", in: source)

        let activate = try XCTUnwrap(install.range(of: "activateForPlayback()"),
                                     "the provider never activates the session — the engine will start silent")
        let build = try XCTUnwrap(install.range(of: "EngineDeckBridge.deviceBridge()"),
                                  "the provider no longer builds the deck")
        XCTAssertTrue(activate.upperBound < build.lowerBound,
                      "the engine is built before the session is active — it starts silent, with no error to explain why")
    }

    /// Off by default. The experiment must never be something someone gets by accident.
    ///
    /// Asserted against the *sources*, not against `UserDefaults.standard`. The first
    /// version of this test wrote and re-read the real defaults, and it failed the moment
    /// it ran on a simulator where the experiment had been switched on by hand — reporting
    /// a defect in the app when the only thing wrong was the machine. A test whose result
    /// depends on the state of the box it runs on is not testing the code, and on a shared
    /// gate it is worse than nothing: it cries wolf, and gets muted.
    ///
    /// What actually has to be true is narrower and permanent: nothing registers a `true`
    /// default for the key, and the Settings binding starts from `false`.
    func testTheEngineIsOffUnlessTheSettingIsOn() throws {
        let settings = try sourceOf("MobileSettingsView.swift")
        XCTAssertTrue(
            settings.contains("@AppStorage(MobileModel.experimentalEngineKey) private var experimentalEngine = false"),
            "the Settings toggle no longer defaults to off"
        )

        for name in ["MobileModel.swift", "MobileSettingsView.swift", "BatonMobileApp.swift"] {
            let source = try sourceOf(name)
            guard let registration = source.range(of: "register(defaults:") else { continue }
            let block = String(source[registration.lowerBound...].prefix(600))
            XCTAssertFalse(
                block.contains(MobileModel.experimentalEngineKey) && block.contains("true"),
                "\(name) registers the experimental engine as on by default"
            )
        }
    }

    // MARK: - The setting has to reach the engine

    /// Flipping the switch must wire (and unwire) the engine there and then.
    ///
    /// This is the bug 0.3.22 shipped with. The provider was installed once in `init` and
    /// nowhere else, so turning the experiment on did nothing until the next launch — while
    /// the Settings copy said it applied to the next track. Music kept playing on AVPlayer,
    /// where the tap never runs for a stream, so switching equalizer presets was silent.
    /// It read as a broken equalizer; it was an unwired switch.
    func testTogglingTheSettingInstallsAndRemovesTheProvider() {
        let model = MobileModel()

        // Off at construction: nothing is wired, whatever the machine's defaults happen to
        // say, because the test asserts against the transition rather than the state.
        model.setExperimentalEngine(false)
        XCTAssertNil(model.music.engineDeckProvider,
                     "a provider survived the experiment being turned off")

        model.setExperimentalEngine(true)
        XCTAssertNotNil(model.music.engineDeckProvider,
                        "turning the experiment on left the engine unwired — the setting does nothing until relaunch")

        model.setExperimentalEngine(false)
        XCTAssertNil(model.music.engineDeckProvider,
                     "turning the experiment off left the provider installed")
    }

    /// The copy must not promise something the wiring does not do. The shipped text said
    /// "Takes effect the next time you start a track" over a switch that took effect at the
    /// next launch — the kind of small untruth that turns into a bug report about a
    /// different feature entirely.
    func testTheSettingsCopyDoesNotPromiseADelayedEffect() throws {
        let settings = try sourceOf("MobileSettingsView.swift")
        XCTAssertFalse(
            settings.contains("Takes effect the next time you start a track"),
            "the copy promises a deferred effect; the toggle is now live and should say so"
        )
        XCTAssertTrue(
            settings.contains("model.setExperimentalEngine(isOn)"),
            "the toggle no longer tells the model anything — flipping it will be inert again"
        )
    }

    // MARK: - Helpers

    private func sourceOf(_ name: String, inSources: Bool = false) throws -> String {
        // …/ios/Tests/BatonMobileTests/ThisFile.swift → ios/
        let ios = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: ios.appendingPathComponent("Sources/BatonMobile/\(name)"),
            encoding: .utf8
        )
    }

    /// A function body, from its declaration to the next declaration at the same level.
    ///
    /// Takes the *earliest* following declaration, not the first pattern that happens to
    /// match. Chaining `??` over the patterns instead picked whichever kind appeared in the
    /// list first regardless of where it sat in the file, so `configure()`'s body ran on
    /// past `activateForPlayback()` — and the test that exists to prove configure() never
    /// activates read the very method whose whole job is activating. It failed on correct
    /// code, which is the good outcome; the same shape passing on broken code is the one
    /// that ships.
    private func body(of declaration: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: declaration), "\(declaration) not found — it was renamed or removed")
        let rest = source[start.upperBound...]
        let end = ["\n    private func ", "\n    func ", "\n    private var ", "\n    var "]
            .compactMap { rest.range(of: $0)?.lowerBound }
            .min()
        return String(end.map { String(rest[..<$0]) } ?? String(rest))
    }
}
