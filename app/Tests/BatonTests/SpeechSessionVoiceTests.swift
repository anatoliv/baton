import Foundation
import Testing
@testable import Baton

/// One voice per agent, from a list you write.
///
/// The feature exists because several agents speak through Baton at once and the ear is the
/// only channel free while you work in another app. A name above the transcript tells you who
/// spoke once you look; a voice tells you before you do.
///
/// This replaced a fixed pool of five that assigned voices by hashing the name. That design
/// could not keep its central promise: five names into five slots avoid each other only about
/// 4% of the time, so in practice three of the user's projects shared one voice. A list you
/// write has no such failure mode — you said which voice, so that is the voice.
@Suite("Agent voices")
@MainActor
struct SpeechSessionVoiceTests {

    @discardableResult
    private func isolatedDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "baton.tests.voices.\(UUID().uuidString)")!
        SpeechConfig.defaults = d
        return d
    }

    private func list(_ pairs: [(String, String)]) {
        SpeechConfig.setSessionVoiceList(pairs.map { .init(label: $0.0, voice: $0.1) })
    }

    // MARK: - Matching

    @Test("A listed agent speaks in the voice it was given")
    func listedAgentUsesItsVoice() {
        isolatedDefaults()
        list([("alpha", "kokoro:af_bella"), ("bravo", "chatterbox:Emily.wav")])
        #expect(SpeechConfig.assignedVoice(for: "alpha") == "kokoro:af_bella")
        #expect(SpeechConfig.assignedVoice(for: "bravo") == "chatterbox:Emily.wav")
    }

    /// Agents send whatever they send. A label that only matched an exact byte sequence would
    /// fail the first time someone typed a capital, and fail *silently* — the agent would just
    /// sound like an unlisted one, which is a working state rather than an error.
    @Test("Case and surrounding whitespace don't stop a match")
    func matchingIsForgiving() {
        isolatedDefaults()
        list([("Alpha", "kokoro:af_bella")])
        #expect(SpeechConfig.assignedVoice(for: "alpha") == "kokoro:af_bella")
        #expect(SpeechConfig.assignedVoice(for: "  ALPHA  ") == "kokoro:af_bella")
    }

    @Test("The first row wins when two claim the same label")
    func firstDuplicateWins() {
        isolatedDefaults()
        list([("alpha", "kokoro:af_bella"), ("alpha", "kokoro:am_michael")])
        #expect(SpeechConfig.assignedVoice(for: "alpha") == "kokoro:af_bella")
    }

    @Test("A row with no voice is not a match")
    func emptyVoiceFallsThrough() {
        isolatedDefaults()
        list([("alpha", "")])
        let voice = SpeechConfig.assignedVoice(for: "alpha")
        #expect(voice != "")
        #expect(voice != nil, "it should fall through to the unlisted pool, not to nothing")
    }

    // MARK: - Everyone else

    /// The promise that makes the list worth writing: a project you named never sounds like
    /// one you did not.
    @Test("An unlisted agent never borrows a listed agent's voice")
    func unlistedStaysOutOfTheList() {
        isolatedDefaults()
        let taken = Array(SpeechConfig.unlistedVoicePool.prefix(3))
        list(taken.enumerated().map { ("listed-\($0.offset)", $0.element) })

        for name in ["charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india"] {
            let voice = SpeechConfig.assignedVoice(for: name)
            #expect(voice != nil)
            #expect(!taken.contains(voice ?? ""), "\(name) borrowed \(voice ?? "") from the list")
        }
    }

    /// "Some other voice" must not mean "a different one each time". An unlisted project that
    /// changed voice on every launch would tell you only that it is unlisted, when the useful
    /// thing is recognising it as the same one again.
    @Test("An unlisted agent sounds the same every time")
    func unlistedIsStable() {
        isolatedDefaults()
        list([("alpha", "kokoro:af_bella")])
        let first = SpeechConfig.assignedVoice(for: "charlie")
        #expect(first != nil)
        for _ in 0 ..< 5 {
            #expect(SpeechConfig.assignedVoice(for: "charlie") == first)
        }
    }

    /// The bucketing has to reach every voice it is offered. An earlier version used a bare
    /// `hash % n`, which only looks at the low bits: measured across twenty names it never
    /// produced bucket 0, so one voice was unreachable and nothing reported it.
    @Test("Every voice in the unlisted pool is reachable")
    func everyUnlistedVoiceIsReachable() {
        isolatedDefaults()
        let names = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
                     "india", "juliett", "kilo", "lima", "mike", "november", "oscar", "papa",
                     "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey",
                     "xray", "yankee", "zulu"]
        let used = Set(names.compactMap { SpeechConfig.assignedVoice(for: $0) })
        #expect(used.count == SpeechConfig.unlistedVoicePool.count,
                "unreachable: \(Set(SpeechConfig.unlistedVoicePool).subtracting(used))")
    }

    @Test("With every pool voice claimed, the category map decides instead of nothing")
    func exhaustedPoolFallsThroughToTheMap() {
        isolatedDefaults()
        list(SpeechConfig.unlistedVoicePool.enumerated().map { ("listed-\($0.offset)", $0.element) })
        #expect(SpeechConfig.assignedVoice(for: "charlie") == nil)

        // nil means "no opinion", so resolve falls through to the category map, not to silence.
        let v = SpeechConfig.resolve(
            category: "alert", explicitVoice: nil, engineOverride: nil, session: "charlie")
        #expect(v.voice == "af_nova", "the alert row of the default map")
    }

    @Test("A blank session name is no session at all")
    func blankSessionIsIgnored() {
        isolatedDefaults()
        #expect(SpeechConfig.assignedVoice(for: "   ") == nil)
    }

    // MARK: - Resolution order

    @Test("An explicit voice still outranks the list")
    func explicitVoiceWins() {
        isolatedDefaults()
        list([("alpha", "kokoro:af_bella")])
        let v = SpeechConfig.resolve(
            category: "ops", explicitVoice: "kokoro:af_sky", engineOverride: nil, session: "alpha")
        #expect(v.voice == "af_sky")
    }

    /// The ordering worth locking, because it could be argued the other way: two agents both
    /// reporting a deploy is exactly when you need them apart, and category-wins would give
    /// them the same voice at that moment.
    @Test("The agent outranks the category map")
    func sessionBeatsCategory() {
        isolatedDefaults()
        list([("alpha", "chatterbox:Emily.wav")])
        let withAgent = SpeechConfig.resolve(
            category: "ops", explicitVoice: nil, engineOverride: nil, session: "alpha")
        #expect(withAgent.engine == .chatterbox)
        #expect(withAgent.voice == "Emily.wav")

        let without = SpeechConfig.resolve(
            category: "ops", explicitVoice: nil, engineOverride: nil, session: nil)
        #expect(without.voice == "am_fenrir", "the ops row of the default map")
    }

    @Test("An engine override still forces the engine")
    func engineOverrideApplies() {
        isolatedDefaults()
        list([("alpha", "kokoro:af_bella")])
        let v = SpeechConfig.resolve(
            category: nil, explicitVoice: nil, engineOverride: .chatterbox, session: "alpha")
        #expect(v.engine == .chatterbox)
    }

    // MARK: - Storage and migration

    @Test("The list survives a round trip, order intact")
    func listRoundTrips() {
        isolatedDefaults()
        list([("alpha", "kokoro:af_bella"), ("bravo", "kokoro:am_michael")])
        let read = SpeechConfig.sessionVoiceList()
        #expect(read.map(\.label) == ["alpha", "bravo"])
        #expect(read.map(\.voice) == ["kokoro:af_bella", "kokoro:am_michael"])
    }

    /// 0.17.4 shipped pins as a `[label: voice]` dictionary — a list with the order lost.
    /// Anyone who set one up in that release must not have to do it again.
    @Test("Pins from 0.17.4 are carried over, once")
    func legacyPinsMigrate() {
        let defaults = isolatedDefaults()
        defaults.set(["alpha": "kokoro:af_bella", "bravo": "kokoro:am_michael"],
                     forKey: SpeechConfig.legacySessionVoicesKey)

        SpeechConfig.migrateLegacySessionVoicesIfNeeded()
        #expect(SpeechConfig.sessionVoiceList().count == 2)
        #expect(SpeechConfig.assignedVoice(for: "alpha") == "kokoro:af_bella")

        // A second run must be a no-op, or a later edit would be undone by a stale key.
        SpeechConfig.setSessionVoiceList([.init(label: "alpha", voice: "kokoro:af_sky")])
        SpeechConfig.migrateLegacySessionVoicesIfNeeded()
        #expect(SpeechConfig.sessionVoiceList().count == 1)
        #expect(SpeechConfig.assignedVoice(for: "alpha") == "kokoro:af_sky")
    }

    @Test("Migration keeps a row you already wrote for the same label")
    func migrationDoesNotClobber() {
        let defaults = isolatedDefaults()
        SpeechConfig.setSessionVoiceList([.init(label: "alpha", voice: "kokoro:af_sky")])
        defaults.set(["alpha": "kokoro:af_bella"], forKey: SpeechConfig.legacySessionVoicesKey)

        SpeechConfig.migrateLegacySessionVoicesIfNeeded()
        #expect(SpeechConfig.sessionVoiceList().count == 1)
        #expect(SpeechConfig.assignedVoice(for: "alpha") == "kokoro:af_sky")
    }
}
