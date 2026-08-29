import XCTest
@testable import Baton

/// Several speak requests arriving at once.
///
/// Reported as "all speak at the same time". The audio queue was never the problem — `play()`
/// appends and `beginSessionIfIdle()` sets `isSpeaking` synchronously, so two calls on the main
/// actor cannot both start. What *was* broken is the surface next to it: banners lived in a single
/// `Alert?` slot, so a second summary arriving before the first was answered overwrote it and was
/// never seen or heard by anyone — while `speak_summary` had already reported `banner_shown` to
/// the agent that sent it.
///
/// That is the worst shape a bug can have here: several agents speaking at once is the case this
/// whole feature exists for, so the losing case was the designed-for case, and nothing in the
/// suite or on screen distinguished "queued" from "silently discarded".
@MainActor
final class SpeechQueueTests: XCTestCase {

    private func engine() -> SpeechPlaybackEngine { SpeechPlaybackEngine() }

    private func alert(_ text: String) -> (String, SpeechPlaybackEngine.Utterance) {
        (text, .native(text))
    }

    // MARK: - The suite does not talk out loud

    /// The test host is Baton, so without this a speech suite plays through the speakers of
    /// whoever is running the gate, over the top of the real app — which sounds exactly like the
    /// app misbehaving, and was a candidate explanation for the report behind these tests.
    ///
    /// Asserted rather than assumed because the mute is set by the bundle's principal class, and
    /// "a principal class that stopped being instantiated" is precisely the kind of thing that
    /// fails silently. `RunnerExitDiagnostic` carries the same warning about its own arming.
    func testTheTestHostIsMuted() {
        XCTAssertTrue(SpeechAudioPlayer.isMuted,
                      "the bundle's principal class did not run, so the gate will speak out loud")
    }

    /// And has no menu-bar icon to be quit from.
    ///
    /// `.accessory` hides the Dock icon and the app menu but **not** a `MenuBarExtra`, which is a
    /// separate scene and is exactly what an accessory app still shows. A release died on that
    /// gap after TBX-3862 was thought fixed, and the diagnostic named `BatonMenuBarContent` in
    /// the backtrace. The scene is now omitted under tests; this asserts the signal that decides
    /// it, since a wrong answer here silently restores a Quit button that ends gate runs.
    func testTheTestHostKnowsItIsATestHost() {
        XCTAssertTrue(BatonApp.isRunningUnderTests,
                      "the menu-bar extra would be built, putting a Quit item back in the menu bar")
    }

    // MARK: - Nothing is dropped

    func testASecondBannerWaitsInsteadOfReplacingTheFirst() {
        let engine = engine()
        engine.presentBanner(text: "First", utterance: .native("First"))
        engine.presentBanner(text: "Second", utterance: .native("Second"))
        engine.presentBanner(text: "Third", utterance: .native("Third"))

        XCTAssertEqual(engine.pendingAlerts.count, 3, "summaries were overwritten instead of queued")
        XCTAssertEqual(engine.pendingAlert?.text, "First", "the oldest should be the one on screen")
    }

    /// Answering one shows the next rather than clearing the lot. Confirming a summary is a
    /// decision about that summary.
    ///
    /// The utterance is a **missing file** on purpose. `confirmBanner` plays what it confirms, and
    /// a `.native` one would drive a real `AVAudioEngine` — which segfaulted this suite when it
    /// ran alongside another that also builds one. A missing file takes the engine's
    /// "temp file missing" path, which logs and finishes the utterance without touching the audio
    /// graph, so what is asserted here stays the queue rather than the speaker.
    func testConfirmingOneAdvancesToTheNext() {
        let engine = engine()
        let missing = URL(fileURLWithPath: "/nonexistent/baton-queue-test.wav")
        engine.presentBanner(text: "First", utterance: .file(missing))
        engine.presentBanner(text: "Second", utterance: .file(missing))

        engine.confirmBanner()
        XCTAssertEqual(engine.pendingAlert?.text, "Second", "the next waiting summary should appear")
        XCTAssertEqual(engine.pendingAlerts.count, 1)
    }

    /// Dismissing is the same: it says "not this one", not "none of them".
    func testDismissingOneAdvancesToTheNext() {
        let engine = engine()
        engine.presentBanner(text: "First", utterance: .native("First"))
        engine.presentBanner(text: "Second", utterance: .native("Second"))

        engine.dismissBanner()
        XCTAssertEqual(engine.pendingAlert?.text, "Second")
        XCTAssertEqual(engine.pendingAlerts.count, 1)
    }

    /// The × on the HUD is the exception, and it should be: "close this" plainly means all of it,
    /// and having the next banner pop up behind the one you just closed would be a surprise.
    func testClosingTheCardDismissesEveryWaitingSummary() {
        let engine = engine()
        engine.presentBanner(text: "First", utterance: .native("First"))
        engine.presentBanner(text: "Second", utterance: .native("Second"))

        engine.dismissAllBanners()
        XCTAssertTrue(engine.pendingAlerts.isEmpty)
        XCTAssertNil(engine.pendingAlert)
    }

    func testDismissingWhenNothingIsWaitingIsHarmless() {
        let engine = engine()
        engine.dismissBanner()
        engine.confirmBanner()
        XCTAssertTrue(engine.pendingAlerts.isEmpty)
    }

    // MARK: - The count the UI shows

    /// Silent at zero. An indicator that says "0 more waiting" on every ordinary summary is noise,
    /// and noise is how an indicator stops being read.
    func testNothingIsWaitingWhenNothingIsWaiting() {
        XCTAssertEqual(engine().waitingCount, 0)
    }

    /// Banners are not counted at all, and this is the regression that reached a real screen.
    ///
    /// The first version added the pending banner queue to this number. With delivery routed to
    /// speak *and* banner, every summary is spoken and also leaves a banner, so once the audio
    /// had drained the label sat at "7 more waiting" with nothing playing and nothing about to.
    /// A banner waits for a decision, not for a turn to be spoken; one number cannot mean both.
    func testBannersAreNotCountedAsWaitingToBeSpoken() {
        let engine = engine()
        engine.presentBanner(text: "One", utterance: .native("One"))
        engine.presentBanner(text: "Two", utterance: .native("Two"))
        engine.presentBanner(text: "Three", utterance: .native("Three"))

        XCTAssertEqual(engine.waitingCount, 0,
                       "banners are waiting for an answer, not to be spoken — counting them left "
                           + "the label stuck at a number that would never come down")
        XCTAssertEqual(engine.pendingAlerts.count, 3, "they are still queued, just not counted")
    }

    /// A reading is a queue of *sentences of one document*. Counting them would say "23 more
    /// waiting" for a single article, which is true of the queue and false of anything the
    /// listener cares about.
    func testAReadingsSentencesAreNotCountedAsWaitingSummaries() {
        let engine = engine()
        engine.reading = .init(text: "One. Two. Three.", spokenRange: NSRange(location: 0, length: 4))
        engine.presentBanner(text: "First", utterance: .native("First"))
        engine.presentBanner(text: "Second", utterance: .native("Second"))

        XCTAssertEqual(engine.waitingCount, 0, "neither sentences nor banners are spoken-and-waiting")
    }
}
