import Foundation
import XCTest
@testable import BatonDocuments

/// The All voices list: readable names from Kokoro's ids, groups, search, and the
/// voice remembered per language.
final class VoiceDirectoryTests: XCTestCase {
    /// The 68 voices the Kokoro on the Baton server listed on 2026-10-16 (`/v1/audio/voices`).
    static let kokoroServerVoices: [String] = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jadzia", "af_jessica", "af_kore", "af_nicole",
        "af_nova", "af_river", "af_sarah", "af_sky", "af_v0", "af_v0bella", "af_v0irulan", "af_v0nicole",
        "af_v0sarah", "af_v0sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael",
        "am_onyx", "am_puck", "am_santa", "am_v0adam", "am_v0gurney", "am_v0michael", "bf_alice", "bf_emma",
        "bf_isabella", "bf_lily", "bf_v0emma", "bf_v0isabella", "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
        "bm_v0george", "bm_v0lewis", "ef_dora", "em_alex", "em_santa", "ff_siwis", "hf_alpha", "hf_beta",
        "hm_omega", "hm_psi", "if_sara", "im_nicola", "jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro",
        "jm_kumo", "pf_dora", "pm_alex", "pm_santa", "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi",
        "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang",
    ].map { "kokoro:\($0)" }

    func testEveryVoiceTheServerListsIsReadableAndGrouped() {
        let groups = VoiceDirectory.groups(Self.kokoroServerVoices)
        XCTAssertEqual(groups.flatMap(\.voices).count, 68)
        XCTAssertFalse(groups.contains { $0.title == VoiceDirectory.otherGroupTitle })
        XCTAssertEqual(groups.map(\.title), [
            "American English, female", "American English, male", "British English, female", "British English, male",
            "Spanish, female", "Spanish, male", "French, female", "Hindi, female", "Hindi, male", "Italian, female",
            "Italian, male", "Japanese, female", "Japanese, male", "Brazilian Portuguese, female",
            "Brazilian Portuguese, male", "Mandarin Chinese, female", "Mandarin Chinese, male",
        ])
        XCTAssertEqual(groups.first?.voices.count, 18)
        XCTAssertEqual(VoiceDirectory.entry("kokoro:af_v0bella").label, "Bella (v0), American, female")
        XCTAssertEqual(VoiceDirectory.entry("kokoro:af_v0").label, "V0, American, female")
    }

    func testKokoroIdsReadAsNameAccentAndGender() {
        XCTAssertEqual(VoiceDirectory.entry("kokoro:af_heart").label, "Heart, American, female")
        XCTAssertEqual(VoiceDirectory.entry("kokoro:bm_george").label, "George, British, male")
        XCTAssertEqual(VoiceDirectory.entry("kokoro:ef_dora").label, "Dora, Spanish, female")
        XCTAssertEqual(VoiceDirectory.entry("kokoro:ff_siwis").label, "Siwis, French, female")
        XCTAssertEqual(VoiceDirectory.entry("kokoro:hm_omega").label, "Omega, Hindi, male")
        XCTAssertEqual(VoiceDirectory.entry("kokoro:im_nicola").label, "Nicola, Italian, male")
        XCTAssertEqual(VoiceDirectory.entry("kokoro:jf_alpha").label, "Alpha, Japanese, female")
        XCTAssertEqual(VoiceDirectory.entry("kokoro:pm_alex").label, "Alex, Brazilian Portuguese, male")
        XCTAssertEqual(VoiceDirectory.entry("kokoro:zf_xiaobei").label, "Xiaobei, Mandarin Chinese, female")
        XCTAssertEqual(VoiceDirectory.entry("kokoro:zf_xiaobei").language, "zh")
        // A bare id is a Kokoro one.
        XCTAssertEqual(VoiceDirectory.entry("af_bella").spec, "kokoro:af_bella")
        XCTAssertEqual(VoiceDirectory.entry("kokoro:am_santa_claus").name, "Santa Claus")
    }

    func testAnIdThatCannotBeReadShowsAsItIs() {
        for spec in ["chatterbox:Emily.wav", "kokoro:af_heart+bf_emma", "kokoro:xf_new", "kokoro:ax_odd", "kokoro:af", "kokoro:abc_def"] {
            let entry = VoiceDirectory.entry(spec)
            let raw = String(spec.split(separator: ":", maxSplits: 1)[1])
            XCTAssertFalse(entry.isReadable, spec)
            XCTAssertEqual(entry.label, raw, spec)
            // Another engine's voice is listed under its engine; an unreadable
            // Kokoro id under Other voices.
            XCTAssertEqual(entry.groupTitle, spec.hasPrefix("chatterbox:") ? "Chatterbox" : VoiceDirectory.otherGroupTitle, spec)
        }
    }

    func testGroupsGoByAccentOrLanguageThenGenderWithTheUnreadableLast() {
        let specs = ["kokoro:zm_yunxi", "chatterbox:Emily.wav", "kokoro:bm_george", "kokoro:af_sky", "kokoro:am_adam",
                     "kokoro:bf_emma", "kokoro:af_heart", "kokoro:ef_dora", "kokoro:af_heart"]
        let groups = VoiceDirectory.groups(specs)
        XCTAssertEqual(groups.map(\.title), ["American English, female", "American English, male",
                                             "British English, female", "British English, male",
                                             "Spanish, female", "Mandarin Chinese, male", "Chatterbox"])
        // By name inside a group, and each voice once.
        XCTAssertEqual(groups[0].voices.map(\.name), ["Heart", "Sky"])
        XCTAssertEqual(groups.flatMap(\.voices).count, 8)
    }

    func testSearchMatchesTheStartOfWordsSoMaleIsNotFemale() {
        let specs = ["kokoro:af_heart", "kokoro:bf_emma", "kokoro:bm_george", "kokoro:bm_lewis", "kokoro:ef_dora", "chatterbox:Emily.wav"]
        func found(_ query: String) -> [String] { VoiceDirectory.groups(specs, matching: query).flatMap(\.voices).map(\.rawID) }
        XCTAssertEqual(found("british male"), ["bm_george", "bm_lewis"])
        XCTAssertEqual(found("male"), ["bm_george", "bm_lewis"])
        XCTAssertEqual(found("fem"), ["af_heart", "bf_emma", "ef_dora"])
        XCTAssertEqual(found("HEART"), ["af_heart"])
        XCTAssertEqual(found("bf_"), ["bf_emma"])
        XCTAssertEqual(found("spanish"), ["ef_dora"])
        XCTAssertEqual(found("english"), ["af_heart", "bf_emma", "bm_george", "bm_lewis"])
        XCTAssertEqual(found("emily"), ["Emily.wav"])
        XCTAssertEqual(found("  ").count, specs.count)
        XCTAssertTrue(found("nobody").isEmpty)
    }

    func testARememberedVoiceLeadsTheSuggestionOnlyWhenTheRendererHasIt() {
        let suggestion = ["kokoro:af_heart", "kokoro:af_bella", "kokoro:am_michael"]
        XCTAssertEqual(VoiceDirectory.suggested(suggestion, remembered: "kokoro:bf_emma", available: ["kokoro:bf_emma", "kokoro:af_heart"]),
                       ["kokoro:bf_emma", "kokoro:af_heart", "kokoro:af_bella", "kokoro:am_michael"])
        // Already suggested: listed once, first.
        XCTAssertEqual(VoiceDirectory.suggested(suggestion, remembered: "kokoro:af_bella", available: suggestion),
                       ["kokoro:af_bella", "kokoro:af_heart", "kokoro:am_michael"])
        // This renderer does not have it, or did not say what it has.
        XCTAssertEqual(VoiceDirectory.suggested(suggestion, remembered: "kokoro:bf_emma", available: suggestion), suggestion)
        XCTAssertEqual(VoiceDirectory.suggested(suggestion, remembered: "kokoro:bf_emma", available: nil), suggestion)
    }

    func testTheLastChosenVoiceIsRememberedPerLanguage() throws {
        // One fixed name, cleared before and after: this package does not link ThrowawayDefaults,
        // and the repo's rule (ThrowawayDefaultsTests) forbids minting a UUID suite per run.
        let suite = "io.tonebox.tests.baton.voicedirectory.memory"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = VoiceChoiceMemory(defaults: defaults)
        XCTAssertNil(memory.last(language: "en"))
        memory.remember("kokoro:bf_emma", language: "en-GB")
        memory.remember("kokoro:ef_dora", language: "es")
        XCTAssertEqual(memory.last(language: "en"), "kokoro:bf_emma")
        XCTAssertEqual(memory.last(language: nil), "kokoro:bf_emma", "no declared language is English")
        XCTAssertEqual(memory.last(language: "ES"), "kokoro:ef_dora")
        memory.remember("kokoro:af_heart", language: nil)
        XCTAssertEqual(VoiceChoiceMemory(defaults: defaults).last(language: "en-US"), "kokoro:af_heart")
        XCTAssertNil(memory.last(language: "fr"))
    }

    func testWhyAllVoicesIsMissing() {
        XCTAssertEqual(VoiceDirectory.unavailableLine(GatewayBookError.http(status: 404, message: "not found")),
                       "Only the suggested voices are here, because your Baton server is older than the voice list.")
        XCTAssertEqual(VoiceDirectory.unavailableLine(GatewayBookError.http(status: 401, message: "")),
                       "Only the suggested voices are here, because the Baton server didn't accept Baton's token.")
        XCTAssertEqual(VoiceDirectory.unavailableLine(URLError(.timedOut)),
                       "Only the suggested voices are here, because the Baton server isn't answering.")
    }
}
