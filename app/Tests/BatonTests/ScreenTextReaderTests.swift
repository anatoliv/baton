import AppKit
import BatonSpeech
import XCTest
@testable import Baton

/// Read aloud, Phase 2: source classification and the capture hook.
///
/// The Services round-trip itself cannot be tested here — it needs two running applications and
/// a real selection — so what is tested is everything around it: that a bundle id maps to the
/// right normalizer profile, that a capture reaches its handler intact, and that the shipped
/// defaults are the ones the decisions call for.
@MainActor
final class ScreenTextReaderTests: XCTestCase {

    override func setUp() {
        ReadAloudSettings.defaults = UserDefaults(suiteName: "read-aloud-test-\(UUID().uuidString)")!
    }
    override func tearDown() {
        ReadAloudSettings.defaults = .standard
        ScreenTextReader.shared.onCapture = nil
    }

    // MARK: - Classification

    func testTerminalsAndBrowsersAreRecognised() {
        XCTAssertEqual(ScreenTextReader.profile(forBundleID: "com.mitchellh.ghostty"), .terminal)
        XCTAssertEqual(ScreenTextReader.profile(forBundleID: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(ScreenTextReader.profile(forBundleID: "com.google.Chrome"), .browser)
        XCTAssertEqual(ScreenTextReader.profile(forBundleID: "com.apple.Safari"), .browser)
    }

    /// Prefix matching, so a beta or a nightly is not silently demoted to `generic` — which
    /// would quietly stop stripping ANSI in the very terminal someone actually runs.
    func testVariantBundleIDsMatchByPrefix() {
        XCTAssertEqual(ScreenTextReader.profile(forBundleID: "com.googlecode.iterm2.beta"), .terminal)
        XCTAssertEqual(ScreenTextReader.profile(forBundleID: "com.google.Chrome.canary"), .browser)
    }

    /// Unknown sources get the shared pass only. That is the safe answer rather than a guess:
    /// the terminal profile would eat lines a text editor legitimately starts with `>`.
    func testUnknownAndMissingSourcesFallBackToGeneric() {
        XCTAssertEqual(ScreenTextReader.profile(forBundleID: "com.example.SomeEditor"), .generic)
        XCTAssertEqual(ScreenTextReader.profile(forBundleID: nil), .generic)
    }

    func testVoiceCategoriesAreOrdinarySpeechConfigCategories() {
        XCTAssertEqual(ScreenTextReader.voiceCategory(for: .terminal), "terminal")
        XCTAssertEqual(ScreenTextReader.voiceCategory(for: .browser), "browser")
        XCTAssertNil(ScreenTextReader.voiceCategory(for: .generic),
                     "generic has no category, so it resolves to the default voice")
    }

    // MARK: - Capture

    func testCaptureReachesTheHandlerAndIsRecorded() {
        var seen: ScreenTextReader.Capture?
        ScreenTextReader.shared.onCapture = { seen = $0 }
        ScreenTextReader.shared.capture("hello there", from: nil)

        XCTAssertEqual(seen?.text, "hello there")
        XCTAssertEqual(seen?.profile, .generic)
        XCTAssertEqual(ScreenTextReader.shared.lastCapture, seen)
    }

    /// The capture carries the text *unmodified*. Normalization belongs to `SpeakableText` and
    /// happens downstream, so a bug in one stage cannot be mistaken for a bug in the other.
    func testCaptureDoesNotNormalize() {
        ScreenTextReader.shared.capture("\u{1B}[31mred\u{1B}[0m", from: nil)
        XCTAssertEqual(ScreenTextReader.shared.lastCapture?.text, "\u{1B}[31mred\u{1B}[0m")
    }

    // MARK: - Shipped defaults

    /// Decision 2: unbound on first launch, so nothing is registered system-wide and no
    /// collision with an existing shortcut is possible.
    func testHotKeyIsUnboundByDefault() {
        XCTAssertNil(ReadAloudSettings.hotKey)
    }

    func testHotKeyRoundTripsAndClears() {
        ReadAloudSettings.hotKey = (keyCode: 15, modifiers: 0x0100)
        XCTAssertEqual(ReadAloudSettings.hotKey?.keyCode, 15)
        XCTAssertEqual(ReadAloudSettings.hotKey?.modifiers, 0x0100)
        ReadAloudSettings.hotKey = nil
        XCTAssertNil(ReadAloudSettings.hotKey)
    }

    /// Decision 3: built, but off, so the voice never changes without being asked.
    func testPerSourceVoicesAreOffByDefault() {
        XCTAssertFalse(ReadAloudSettings.perSourceVoices)
    }

    // MARK: - Settings surface (Phase 6)

    /// Decision 3 asks for the two categories to be *pre-populated*, so turning the toggle on
    /// needs no typing — and seeded with voices distinct from the default, so it does something
    /// audible rather than appearing broken.
    func testSeedingAddsTheReadAloudCategoriesWithDistinctVoices() {
        SpeechConfig.defaults = ReadAloudSettings.defaults
        defer { SpeechConfig.defaults = .standard }

        SpeechConfig.setVoiceMap(["default": "kokoro:af_sky"])
        ReadAloudSettings.seedVoiceCategoriesIfNeeded()

        let map = SpeechConfig.voiceMap()
        XCTAssertNotNil(map["browser"])
        XCTAssertNotNil(map["terminal"])
        XCTAssertNotEqual(map["browser"], map["terminal"], "the two sources must be distinguishable by ear")
        XCTAssertEqual(map["default"], "kokoro:af_sky", "seeding must not disturb the existing map")
    }

    /// Seeding is idempotent and never overwrites a choice the user has already made.
    func testSeedingDoesNotOverwriteAUserChoice() {
        SpeechConfig.defaults = ReadAloudSettings.defaults
        defer { SpeechConfig.defaults = .standard }

        SpeechConfig.setVoiceMap(["default": "kokoro:af_sky", "terminal": "chatterbox:Emily.wav"])
        ReadAloudSettings.seedVoiceCategoriesIfNeeded()
        ReadAloudSettings.seedVoiceCategoriesIfNeeded()

        XCTAssertEqual(SpeechConfig.voiceMap()["terminal"], "chatterbox:Emily.wav")
    }

    func testModifierTranslationAndDescription() {
        let mods = ReadAloudHotKeyRecorder.carbonModifiers([.control, .option])
        XCTAssertEqual(ReadAloudHotKeyRecorder.describe(keyCode: 15, modifiers: mods), "⌃⌥R")
        XCTAssertEqual(ReadAloudHotKeyRecorder.describe(keyCode: 49, modifiers: ReadAloudHotKeyRecorder.carbonModifiers([.command])), "⌘Space")
    }

    /// On by default because Phase 0 proved Chrome vends no `AXSelectedText` — in the most
    /// common source app this fallback *is* the hotkey path.
    func testClipboardFallbackIsOnByDefaultAndCanBeTurnedOff() {
        XCTAssertTrue(ReadAloudSettings.allowClipboardFallback)
        ReadAloudSettings.allowClipboardFallback = false
        XCTAssertFalse(ReadAloudSettings.allowClipboardFallback)
    }
}
