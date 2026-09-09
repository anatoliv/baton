import BatonSubsonicModels
import XCTest
@testable import BatonSpeech

/// The package's first tests (S-F24). `BatonSpeech` is 991 lines that both apps compile, and
/// every assertion it had lived in the macOS app target, so `swift test` here proved nothing
/// and the iPhone gate ran none of it.
///
/// Config parsing and resolution: the part that decides which engine gets called and with
/// what voice, from a `UserDefaults` domain this test owns and throws away.
final class SpeechConfigTests: XCTestCase {
    private var suiteName = ""
    private var suite: UserDefaults!
    private var saved: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "BatonSpeechTests.\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        saved = SpeechConfig.defaults
        SpeechConfig.defaults = suite
    }

    override func tearDown() {
        SpeechConfig.defaults = saved
        suite.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Spec parsing

    func testAnEngineColonVoiceSpecResolvesToThatEngine() {
        let voice = SpeechConfig.resolve(category: nil, explicitVoice: "chatterbox:Emily.wav",
                                         engineOverride: nil)
        XCTAssertEqual(voice, SpeechConfig.Voice(engine: .chatterbox, voice: "Emily.wav"))
    }

    func testTheEngineHalfOfASpecIsCaseInsensitive() {
        XCTAssertEqual(
            SpeechConfig.resolve(category: nil, explicitVoice: "KOKORO:af_sky", engineOverride: nil),
            SpeechConfig.Voice(engine: .kokoro, voice: "af_sky"))
    }

    /// A voice id may contain a colon of its own, so only the first one separates.
    func testOnlyTheFirstColonSplitsASpec() {
        XCTAssertEqual(
            SpeechConfig.resolve(category: nil, explicitVoice: "chatterbox:some:voice.wav",
                                 engineOverride: nil),
            SpeechConfig.Voice(engine: .chatterbox, voice: "some:voice.wav"))
    }

    /// A bare value is a voice, not an engine, and an unknown engine prefix is not silently
    /// dropped: the whole string stays the voice, so the failure is visible at the server
    /// rather than becoming a different voice here.
    func testABareOrUnknownEngineFallsBackWithTheWholeStringAsTheVoice() {
        XCTAssertEqual(
            SpeechConfig.resolve(category: nil, explicitVoice: "af_bella", engineOverride: nil),
            SpeechConfig.Voice(engine: .kokoro, voice: "af_bella"))
        XCTAssertEqual(
            SpeechConfig.resolve(category: nil, explicitVoice: "piper:en_GB", engineOverride: nil),
            SpeechConfig.Voice(engine: .kokoro, voice: "piper:en_GB"))
    }

    // MARK: - Resolution precedence

    func testAnExplicitVoiceOutranksTheCategoryMap() {
        SpeechConfig.setVoiceMap(["deploy": "kokoro:am_michael"])
        let voice = SpeechConfig.resolve(category: "deploy", explicitVoice: "kokoro:af_nova",
                                         engineOverride: nil)
        XCTAssertEqual(voice.voice, "af_nova")
    }

    /// Session beats category: with several agents running, two of them reporting a deploy is
    /// exactly the case you need to tell apart by ear.
    func testASessionVoiceOutranksTheCategoryMap() {
        SpeechConfig.setVoiceMap(["deploy": "kokoro:am_michael"])
        SpeechConfig.setSessionVoiceList([.init(label: "baton", voice: "kokoro:af_sky")])
        let voice = SpeechConfig.resolve(category: "deploy", explicitVoice: nil,
                                         engineOverride: nil, session: "baton")
        XCTAssertEqual(voice.voice, "af_sky")
    }

    /// "Ops"/"OPS" must resolve like "ops" rather than falling through to "default".
    func testTheCategoryLookupIsCaseInsensitive() {
        SpeechConfig.setVoiceMap(["default": "kokoro:af_heart", "ops": "kokoro:am_fenrir"])
        XCTAssertEqual(SpeechConfig.resolve(category: "OPS", explicitVoice: nil, engineOverride: nil).voice,
                       "am_fenrir")
        XCTAssertEqual(SpeechConfig.resolve(category: "Ops", explicitVoice: nil, engineOverride: nil).voice,
                       "am_fenrir")
    }

    func testAnUnknownCategoryFallsBackToTheDefaultRow() {
        SpeechConfig.setVoiceMap(["default": "kokoro:af_heart"])
        XCTAssertEqual(
            SpeechConfig.resolve(category: "nothing-like-this", explicitVoice: nil, engineOverride: nil).voice,
            "af_heart")
    }

    /// The engine override is the tool's `engine` argument, and it wins over whatever the
    /// spec said, whichever branch produced the spec.
    func testAnEngineOverrideWinsOverEveryBranch() {
        SpeechConfig.setVoiceMap(["default": "kokoro:af_heart"])
        SpeechConfig.setSessionVoiceList([.init(label: "baton", voice: "kokoro:af_sky")])
        for (category, explicit, session) in [
            (nil, "kokoro:af_bella", nil), (nil, nil, "baton"), ("default", nil, nil),
        ] as [(String?, String?, String?)] {
            let voice = SpeechConfig.resolve(category: category, explicitVoice: explicit,
                                             engineOverride: .chatterbox, session: session)
            XCTAssertEqual(voice.engine, .chatterbox)
        }
    }

    func testAnEmptyStoredVoiceMapFallsBackToTheShippedDefaults() {
        SpeechConfig.setVoiceMap([:])
        XCTAssertEqual(SpeechConfig.voiceMap(), SpeechConfig.defaultVoiceMap)
    }

    // MARK: - A voice per agent

    /// Trimmed and case-folded, so "Baton", " baton " and "baton" are one project.
    func testSessionLabelsNormaliseToOneProject() {
        SpeechConfig.setSessionVoiceList([.init(label: "Baton", voice: "kokoro:af_sky")])
        for spelling in ["baton", " Baton ", "BATON", "\tbaton\n"] {
            XCTAssertEqual(SpeechConfig.assignedVoice(for: spelling), "kokoro:af_sky", spelling)
        }
        XCTAssertNil(SpeechConfig.assignedVoice(for: "   "), "whitespace is not a label")
    }

    /// An unlisted project gets a voice from outside the list, and the same one every launch:
    /// derived from the name, because a fresh random pick would say "not one of your named
    /// ones" instead of "this one again".
    func testAnUnlistedSessionGetsAStableVoiceFromOutsideTheList() {
        SpeechConfig.setSessionVoiceList([.init(label: "baton", voice: "kokoro:af_heart")])
        let first = SpeechConfig.assignedVoice(for: "night build")
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, "kokoro:af_heart", "a named project never shares its sound")
        for _ in 0 ..< 5 {
            XCTAssertEqual(SpeechConfig.assignedVoice(for: "night build"), first)
        }
    }

    /// Every voice in the pool can actually be chosen, bucket 0 included. One voice being
    /// unreachable is the failure the fold before the modulo was added against, and nothing
    /// reported it at the time.
    ///
    /// **Measured caveat, so nobody trusts this test for more than it does.** Deleting
    /// `hash ^= hash >> 32` from `stableSlot` and re-running leaves this test *green* over
    /// these 24 names: the fold changes which name lands where, not whether the set covers
    /// the pool. The test below, with its recorded literals, is the one that goes red on that
    /// change. Both are kept: this one guards the property, that one guards the values.
    func testEveryBucketInThePoolIsReachable() {
        var seen: Set<Int> = []
        for name in ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
                     "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "phi",
                     "psi", "omega", "home", "radio", "podcast", "queue"] {
            let slot = SpeechConfig.stableSlot(for: name, count: 8)
            XCTAssertTrue((0 ..< 8).contains(slot), "\(name) landed outside the pool")
            seen.insert(slot)
        }
        XCTAssertEqual(seen, Set(0 ..< 8), "every voice in the pool must be reachable, bucket 0 included")
        XCTAssertEqual(SpeechConfig.stableSlot(for: "anything", count: 0), 0, "an empty pool is slot 0")
    }

    /// Written down as literals rather than merely compared to itself: a slot that is stable
    /// within one process but reshuffles between launches is exactly the bug this hash exists
    /// to avoid, and only a value recorded outside the run can catch it.
    func testTheStableSlotIsTheSameEveryRun() {
        XCTAssertEqual(SpeechConfig.stableSlot(for: "baton", count: 8), 3)
        XCTAssertEqual(SpeechConfig.stableSlot(for: "tonebox", count: 8), 5)
        XCTAssertEqual(SpeechConfig.stableSlot(for: "alpha", count: 8), 0)
    }

    func testTheSessionVoiceListSurvivesAWriteAndARead() {
        let list = [SpeechConfig.SessionVoice(label: "baton", voice: "kokoro:af_sky"),
                    SpeechConfig.SessionVoice(label: "tonebox", voice: "chatterbox:Emily.wav")]
        SpeechConfig.setSessionVoiceList(list)
        XCTAssertEqual(SpeechConfig.sessionVoiceList(), list)
    }

    /// The 0.17.4 pin map was `[label: voice]`, which is a list with the order lost. It runs
    /// once and clears the old key, so a later edit is never overwritten by it.
    func testTheLegacyPinMapMigratesOnceAndThenStopsMattering() {
        suite.set(["baton": "kokoro:af_sky", "tonebox": "kokoro:am_puck"],
                  forKey: SpeechConfig.legacySessionVoicesKey)
        SpeechConfig.migrateLegacySessionVoicesIfNeeded()

        XCTAssertEqual(SpeechConfig.sessionVoiceList().map(\.label), ["baton", "tonebox"])
        XCTAssertNil(suite.dictionary(forKey: SpeechConfig.legacySessionVoicesKey))

        SpeechConfig.setSessionVoiceList([.init(label: "baton", voice: "kokoro:bf_emma")])
        SpeechConfig.migrateLegacySessionVoicesIfNeeded()
        XCTAssertEqual(SpeechConfig.sessionVoiceList().map(\.voice), ["kokoro:bf_emma"],
                       "a second run must not resurrect the old pins over a later edit")
    }

    func testMigrationDoesNotOverwriteALabelTheListAlreadyHas() {
        SpeechConfig.setSessionVoiceList([.init(label: "Baton", voice: "kokoro:bf_emma")])
        suite.set(["baton": "kokoro:af_sky"], forKey: SpeechConfig.legacySessionVoicesKey)
        SpeechConfig.migrateLegacySessionVoicesIfNeeded()
        XCTAssertEqual(SpeechConfig.sessionVoiceList().map(\.voice), ["kokoro:bf_emma"])
    }

    // MARK: - Delivery plan

    func testAnnounceImmediatelySpeaksNowWhateverTheAgentAsked() {
        let plan = SpeechConfig.deliveryPlan(announceImmediately: true, allowAgentAutoPlay: false,
                                             notification: false, banner: false, requestedMode: "notify")
        XCTAssertTrue(plan.speakNow)
    }

    /// The auto-play gate: an agent may only make audio start on its own if the
    /// person switched that on, otherwise a leaked MCP token is an audio-spam vector.
    func testAnAgentsAutoModeNeedsThePersonsPermission() {
        let refused = SpeechConfig.deliveryPlan(announceImmediately: false, allowAgentAutoPlay: false,
                                                notification: true, banner: false, requestedMode: "auto")
        XCTAssertFalse(refused.speakNow)
        XCTAssertTrue(refused.notify)

        let allowed = SpeechConfig.deliveryPlan(announceImmediately: false, allowAgentAutoPlay: true,
                                                notification: true, banner: false, requestedMode: "auto")
        XCTAssertTrue(allowed.speakNow)
    }

    /// One invariant: a summary must always be reachable somehow.
    func testASummaryThatWouldSurfaceNowhereKeepsABanner() {
        let plan = SpeechConfig.deliveryPlan(announceImmediately: false, allowAgentAutoPlay: false,
                                             notification: false, banner: false, requestedMode: "notify")
        XCTAssertTrue(plan.banner)
        XCTAssertFalse(plan.speakNow)
    }

    /// Speaking now is not a reason to drop the record, so the alert surfaces still apply.
    func testTheAlertSurfacesApplyUnderBothPrimaries() {
        let plan = SpeechConfig.deliveryPlan(announceImmediately: true, allowAgentAutoPlay: false,
                                             notification: true, banner: true, requestedMode: "notify")
        XCTAssertEqual(plan, SpeechConfig.DeliveryPlan(speakNow: true, notify: true, banner: true))
    }

    // MARK: - Hosts and gates

    /// A localhost placeholder is the right answer to "where do I send a request" and the
    /// wrong one to "should a failure here read as broken". Settings greeted a fresh install
    /// with two red failures for services nobody had set up.
    func testAnUnsetHostHandsOutAPlaceholderButDoesNotCountAsStored() {
        XCTAssertFalse(SpeechConfig.hasStoredHost(for: .kokoro))
        XCTAssertFalse(SpeechConfig.hasStoredHost(for: .chatterbox))
        XCTAssertEqual(SpeechConfig.baseURL(for: .kokoro), "http://127.0.0.1:8880")
        XCTAssertEqual(SpeechConfig.baseURL(for: .chatterbox), "http://127.0.0.1:8004")

        SpeechConfig.kokoroBaseURL = "http://127.0.0.1:8880"
        XCTAssertTrue(SpeechConfig.hasStoredHost(for: .kokoro),
                      "somebody running Kokoro here would type exactly the placeholder, and that "
                          + "is a configured host")
        SpeechConfig.kokoroBaseURL = "   "
        XCTAssertFalse(SpeechConfig.hasStoredHost(for: .kokoro), "whitespace is not an address")
    }

    /// Transcription ships audio off the device, which is a different promise from playing
    /// it, so it is never inferred from a host happening to be set.
    func testTranscriptionIsOffUntilItIsSwitchedOnAndPointedSomewhereReal() {
        XCTAssertFalse(SpeechConfig.transcriptionEnabled)
        XCTAssertFalse(SpeechConfig.isTranscriptionConfigured)

        SpeechConfig.whisperBaseURL = "http://asr.example:8001"
        XCTAssertFalse(SpeechConfig.isTranscriptionConfigured, "a host alone is not consent")

        SpeechConfig.transcriptionEnabled = true
        XCTAssertTrue(SpeechConfig.isTranscriptionConfigured)

        SpeechConfig.whisperBaseURL = "not a url"
        XCTAssertFalse(SpeechConfig.isTranscriptionConfigured, "enabled but unconfigured is not ready")
    }

    /// Empty on iOS, where the phone is never the machine running Whisper: it shipped as a
    /// saved-looking value that could only report itself unreachable.
    func testTheWhisperHostDefaultIsPlatformScoped() {
        #if os(iOS)
        XCTAssertEqual(SpeechConfig.whisperBaseURL, "")
        #else
        XCTAssertEqual(SpeechConfig.whisperBaseURL, "http://127.0.0.1:8001")
        #endif
    }

    func testTheWhisperModelFallsBackToTheOpenAICompatibleID() {
        XCTAssertEqual(SpeechConfig.whisperModel, "whisper-1")
        SpeechConfig.whisperModel = ""
        XCTAssertEqual(SpeechConfig.whisperModel, "whisper-1", "an empty setting is not a model id")
        SpeechConfig.whisperModel = "large-v3"
        XCTAssertEqual(SpeechConfig.whisperModel, "large-v3")
    }

    func testTheBluetoothTimingsHaveDefaultsAndAreClamped() {
        XCTAssertEqual(SpeechConfig.bluetoothWarmup, 0.7, accuracy: 0.0001)
        XCTAssertEqual(SpeechConfig.engineLinger, 25, accuracy: 0.0001)

        SpeechConfig.bluetoothWarmup = 99
        XCTAssertEqual(SpeechConfig.bluetoothWarmup, 5, accuracy: 0.0001)
        SpeechConfig.bluetoothWarmup = -3
        XCTAssertEqual(SpeechConfig.bluetoothWarmup, 0, accuracy: 0.0001, "zero disables the padding")

        SpeechConfig.engineLinger = 9_999
        XCTAssertEqual(SpeechConfig.engineLinger, 300, accuracy: 0.0001)
    }

    /// Hosts are your servers, not a shippable default, so a reset leaves them alone unless
    /// asked.
    func testResetRestoresTheDefaultsAndLeavesHostsAloneUnlessAsked() {
        SpeechConfig.setVoiceMap(["default": "chatterbox:Emily.wav"])
        SpeechConfig.allowAutoPlay = true
        SpeechConfig.transcriptionEnabled = true
        SpeechConfig.kokoroBaseURL = "http://tts.example:8880"

        SpeechConfig.resetToDefaults()
        XCTAssertEqual(SpeechConfig.voiceMap(), SpeechConfig.defaultVoiceMap)
        XCTAssertFalse(SpeechConfig.allowAutoPlay)
        XCTAssertFalse(SpeechConfig.transcriptionEnabled)
        XCTAssertTrue(SpeechConfig.fallbackEnabled)
        XCTAssertEqual(SpeechConfig.kokoroBaseURL, "http://tts.example:8880")

        SpeechConfig.resetToDefaults(includeHosts: true)
        XCTAssertEqual(SpeechConfig.kokoroBaseURL, "http://127.0.0.1:8880")
        XCTAssertFalse(SpeechConfig.hasStoredHost(for: .kokoro))
    }

    func testTheSummaryCapIsASummaryNotAnEssay() {
        XCTAssertEqual(SpeechConfig.maxSummaryChars, 2000)
    }
}
