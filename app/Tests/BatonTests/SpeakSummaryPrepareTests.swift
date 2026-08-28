import BatonSpeech
import XCTest
@testable import Baton

/// `speak_summary`'s `prepare` argument — the path the `baton-say` CLI and the terminal watch
/// hook use to hand Baton raw command output.
///
/// The reason this file exists is a bug that shipped past every other test and was caught only
/// by driving the running app: the text was cleaned before *speaking* but the **raw** text was
/// written to `SpeechHistory`, which persists to `UserDefaults` on disk. A redactor that
/// protects the speaker and then writes the secret to disk protects nothing.
@MainActor
final class SpeakSummaryPrepareTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        suite = UserDefaults(suiteName: "speak-prepare-\(UUID().uuidString)")!
        SpeechConfig.defaults = suite
        // A closed port, so synthesis fails immediately rather than waiting on a connect
        // timeout, and the native fallback carries the utterance without touching the network.
        SpeechConfig.kokoroBaseURL = "http://127.0.0.1:9"
        SpeechConfig.fallbackEnabled = true
        // Deliver as a notification only: nothing should speak out loud during a test run.
        SpeechConfig.announceImmediately = false
        SpeechConfig.alertWithNotification = true
        SpeechConfig.alertWithBanner = false
    }

    override func tearDown() { SpeechConfig.defaults = .standard }

    private let scrapings = """
    anatoli@mac baton % ./deploy.sh
    exporting SENTRY_AUTH_TOKEN=sntrys_abcdefghijklmnopqrs.tuvwxyz
    deploy finished in 42 seconds
    """

    /// The one that matters: nothing shaped like a credential may reach the persisted history.
    func testPreparedTextIsWhatGetsRecorded() async throws {
        let music = MusicModel()
        _ = try await BatonMCPSpeakTools.run(
            ["text": scrapings, "prepare": "terminal", "mode": "notify"], music
        )

        let recorded = try XCTUnwrap(music.speechHistory.entries.first?.text)
        XCTAssertFalse(recorded.contains("sntrys_"),
                       "the raw token must never reach the persisted history")
        XCTAssertFalse(recorded.contains("anatoli@mac"),
                       "the prompt line should have been cleaned before recording, not after")
        XCTAssertTrue(recorded.contains("deploy finished in 42 seconds"),
                      "the content itself must survive")
    }

    /// Without `prepare`, an agent's authored summary is recorded verbatim — cleaning is
    /// opt-in, and must not start rewriting what agents say.
    func testWithoutPrepareTheTextIsRecordedVerbatim() async throws {
        let music = MusicModel()
        let summary = "Deploy finished, all checks green."
        _ = try await BatonMCPSpeakTools.run(["text": summary, "mode": "notify"], music)

        XCTAssertEqual(music.speechHistory.entries.first?.text, summary)
    }

    func testUnknownPrepareProfileIsRejected() async {
        let music = MusicModel()
        do {
            _ = try await BatonMCPSpeakTools.run(
                ["text": "hello there", "prepare": "sideways", "mode": "notify"], music
            )
            XCTFail("an unknown profile should be refused rather than silently ignored")
        } catch {
            XCTAssertTrue("\(error)".contains("sideways"))
        }
    }
}
