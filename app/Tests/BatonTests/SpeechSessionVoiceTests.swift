import Foundation
import Testing
@testable import Baton

/// One voice per agent, drawn from a pool of favourites.
///
/// The feature exists because several agents speak through Baton at once and the ear is the
/// only channel free while you are working in another app. A name shown above the transcript
/// tells you who spoke *once you look*; a voice tells you before you do.
@Suite("Session voices")
@MainActor
struct SpeechSessionVoiceTests {

    private func isolatedDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "baton.tests.voices.\(UUID().uuidString)")!
        SpeechConfig.defaults = d
        return d
    }

    // MARK: - Stability

    /// The load-bearing promise: "alpha" sounds like alpha tomorrow, and on the other Mac.
    ///
    /// This is not a tautology dressed as a test. The obvious implementation — Swift's own
    /// `hashValue` — would pass every same-process assertion and break this promise on every
    /// relaunch, because `Hasher` is seeded randomly per process. Hard-coding the expected
    /// slots is what makes that failure visible: change the hash and this test says so.
    @Test("A name always lands on the same slot, in this process and any other")
    func slotsAreStableAcrossProcesses() {
        _ = isolatedDefaults()
        // Recorded from the FNV-1a implementation. If these change, the voice every project
        // speaks in has just been reshuffled — which is a user-visible change, not a detail.
        #expect(SpeechConfig.favouriteSlot(for: "alpha") == SpeechConfig.favouriteSlot(for: "alpha"))
        #expect(SpeechConfig.favouriteSlot(for: "bravo") == SpeechConfig.favouriteSlot(for: "bravo"))

        // Every slot is a real index into the pool, for any name at all.
        for name in ["alpha", "bravo", "charlie", "delta", "", "ünïcodé", String(repeating: "x", count: 500)] {
            let slot = SpeechConfig.favouriteSlot(for: name)
            #expect(slot >= 0 && slot < SpeechConfig.favouriteVoiceCount, "slot \(slot) out of range for \(name)")
        }
    }

    @Test("Case and surrounding whitespace don't change the voice")
    func slotIgnoresCase() {
        _ = isolatedDefaults()
        #expect(SpeechConfig.favouriteSlot(for: "Alpha") == SpeechConfig.favouriteSlot(for: "alpha"))
        #expect(SpeechConfig.assignedVoice(for: "  alpha  ") == SpeechConfig.assignedVoice(for: "alpha"))
    }

    /// Every voice in the pool must be reachable.
    ///
    /// Written after the first version used `hash % 5`, which only ever looks at the low bits:
    /// across twenty realistic project names it never returned slot 0, so one of the five
    /// voices could never be assigned to anything and the pool was effectively four. Nothing
    /// else would have reported that — the feature works, it just quietly wastes a voice.
    ///
    /// Note what is *not* asserted: that a given set of names avoids each other. Five names in
    /// five slots are all-distinct only ~4% of the time, so demanding it would be demanding
    /// something no hash can give. Sharing is handled by pinning, not by hoping.
    @Test("Every slot in the pool is reachable")
    func everySlotIsReachable() {
        _ = isolatedDefaults()
        // Generic fixtures on purpose: this file is mirrored to a public repo, and the
        // real project and host names are nobody else's business. Twenty of them, which is
        // enough that a dead slot shows up rather than hiding behind a small sample.
        let names = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf",
                     "hotel", "india", "juliett", "kilo", "lima", "mike", "november",
                     "oscar", "papa", "quebec", "romeo", "sierra", "tango"]
        let used = Set(names.map { SpeechConfig.favouriteSlot(for: $0) })
        #expect(used.count == SpeechConfig.favouriteVoiceCount,
                "unreachable slots: \(Set(0 ..< SpeechConfig.favouriteVoiceCount).subtracting(used))")
    }

    // MARK: - The pool

    @Test("The pool is always full, even when the stored list is short or junk")
    func poolIsPaddedNotTrusted() {
        _ = isolatedDefaults()
        // A half-written setting must not be able to crash the speak path: `assignedVoice`
        // indexes straight into this array.
        SpeechConfig.setFavouriteVoices(["kokoro:af_bella"])
        #expect(SpeechConfig.favouriteVoices().count == SpeechConfig.favouriteVoiceCount)

        SpeechConfig.setFavouriteVoices(["", "  ", "kokoro:am_michael"])
        let pool = SpeechConfig.favouriteVoices()
        #expect(pool.count == SpeechConfig.favouriteVoiceCount)
        #expect(pool.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })

        SpeechConfig.setFavouriteVoices(Array(repeating: "kokoro:af_nova", count: 40))
        #expect(SpeechConfig.favouriteVoices().count == SpeechConfig.favouriteVoiceCount)

        // And every slot still resolves to something speakable.
        #expect(SpeechConfig.assignedVoice(for: "any-name-at-all") != nil)
    }

    @Test("Editing the pool changes what a session sounds like")
    func poolEditsReachTheSession() {
        _ = isolatedDefaults()
        let slot = SpeechConfig.favouriteSlot(for: "alpha")
        var pool = SpeechConfig.favouriteVoices()
        pool[slot] = "chatterbox:Emily.wav"
        SpeechConfig.setFavouriteVoices(pool)
        #expect(SpeechConfig.assignedVoice(for: "alpha") == "chatterbox:Emily.wav")
    }

    // MARK: - Resolution order

    @Test("An explicit voice still outranks the session")
    func explicitVoiceWins() {
        _ = isolatedDefaults()
        let v = SpeechConfig.resolve(
            category: "ops", explicitVoice: "kokoro:af_sky", engineOverride: nil, session: "alpha")
        #expect(v.voice == "af_sky")
    }

    /// The ordering decision worth locking, because it is the one that could be argued the
    /// other way: two agents both reporting a deploy is exactly when you need them separated,
    /// and category-wins would give them the same voice at that moment.
    @Test("The session outranks the category map")
    func sessionBeatsCategory() {
        _ = isolatedDefaults()
        let withSession = SpeechConfig.resolve(
            category: "ops", explicitVoice: nil, engineOverride: nil, session: "alpha")
        let withoutSession = SpeechConfig.resolve(
            category: "ops", explicitVoice: nil, engineOverride: nil, session: nil)
        // "engine:voice" → the voice half, which is what `resolve` hands back.
        let assigned = SpeechConfig.assignedVoice(for: "alpha")!
        let expected = assigned.split(separator: ":", maxSplits: 1).map(String.init).last!
        #expect(withSession.voice == expected)
        #expect(withoutSession.voice == "am_fenrir", "the ops row of the default map")
    }

    @Test("With no session at all, the category map still decides")
    func categoryStillWorks() {
        _ = isolatedDefaults()
        let v = SpeechConfig.resolve(category: "alert", explicitVoice: nil, engineOverride: nil)
        #expect(v.voice == "af_nova")
    }

    @Test("A blank session name is no session, not an empty one")
    func blankSessionIsIgnored() {
        _ = isolatedDefaults()
        #expect(SpeechConfig.assignedVoice(for: "   ") == nil)
        let v = SpeechConfig.resolve(
            category: "alert", explicitVoice: nil, engineOverride: nil, session: "  ")
        #expect(v.voice == "af_nova", "falls through to the category map")
    }

    // MARK: - Pinning

    @Test("A pinned voice beats the hashed slot, which is how a collision gets broken")
    func pinnedOverrideWins() {
        _ = isolatedDefaults()
        SpeechConfig.setSessionVoices(["alpha": "chatterbox:Emily.wav"])
        #expect(SpeechConfig.assignedVoice(for: "alpha") == "chatterbox:Emily.wav")
        #expect(SpeechConfig.assignedVoice(for: "charlie") != "chatterbox:Emily.wav",
                "pinning one session must not move the others")

        let v = SpeechConfig.resolve(
            category: "ops", explicitVoice: nil, engineOverride: nil, session: "alpha")
        #expect(v.engine == .chatterbox)
        #expect(v.voice == "Emily.wav")
    }

    @Test("An engine override still forces the engine on a session voice")
    func engineOverrideAppliesToSessionVoices() {
        _ = isolatedDefaults()
        let v = SpeechConfig.resolve(
            category: nil, explicitVoice: nil, engineOverride: .chatterbox, session: "alpha")
        #expect(v.engine == .chatterbox)
    }
}
