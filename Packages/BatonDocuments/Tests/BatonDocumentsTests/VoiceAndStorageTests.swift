import Foundation
import XCTest
@testable import BatonDocuments

final class VoiceCatalogueTests: XCTestCase {
    func testKokoroIdsDescribeThemselves() {
        let emma = VoiceCatalogue.describe("kokoro:bf_emma")
        XCTAssertEqual(emma, VoiceDescriptor(spec: "kokoro:bf_emma", language: "en", accent: "british",
                                             gender: "female", grade: "B-",
                                             tags: ["clear", "bright", "crisp", "lively", "youthful", "good for narration and dialogue"]))
        XCTAssertEqual(VoiceCatalogue.describe("am_michael").spec, "kokoro:am_michael")
        XCTAssertEqual(VoiceCatalogue.describe("kokoro:ef_dora").language, "es")
        // A voice the table has never heard of still gets what its id says.
        let unknown = VoiceCatalogue.describe("kokoro:bm_newvoice")
        XCTAssertEqual(unknown.accent, "british")
        XCTAssertNil(unknown.grade)
        // Chatterbox references carry no scheme to read.
        XCTAssertNil(VoiceCatalogue.describe("chatterbox:Emily.wav").gender)
    }

    func testGradesRankAndCandidatesAreTheServersOwnBestFirst() {
        XCTAssertGreaterThan(VoiceCatalogue.describe("af_heart").gradeRank, VoiceCatalogue.describe("af_bella").gradeRank)
        XCTAssertGreaterThan(VoiceCatalogue.describe("bm_lewis").gradeRank, VoiceCatalogue.describe("bm_daniel").gradeRank)
        XCTAssertGreaterThan(VoiceCatalogue.describe("bf_emma").gradeRank, VoiceCatalogue.describe("am_michael").gradeRank,
                             "B- outranks C+")
        let available = ["kokoro:bm_george", "kokoro:af_heart", "kokoro:bf_emma", "kokoro:ef_dora",
                         "kokoro:bm_newvoice", "chatterbox:Emily.wav"]
        let english = VoiceCatalogue.candidates(language: "en", available: available).map(\.spec)
        XCTAssertEqual(english, ["kokoro:af_heart", "kokoro:bf_emma", "kokoro:bm_george"])
        XCTAssertEqual(VoiceCatalogue.candidates(language: "es", available: available).map(\.spec), [])  // ungraded
    }

    /// TBX-10916: the voices heard as good for narration lead, then narration-and-dialogue, then
    /// the dialogue-only ones, best grade first within each.
    func testNarrationVoicesLeadTheCandidates() {
        let available = ["kokoro:af_bella", "kokoro:am_santa", "kokoro:bm_george", "kokoro:am_adam", "kokoro:bf_emma",
                         "kokoro:af_heart", "kokoro:bm_lewis"]
        XCTAssertEqual(VoiceCatalogue.candidates(language: "en", available: available).map(\.spec),
                       ["kokoro:af_heart", "kokoro:am_adam", "kokoro:bf_emma", "kokoro:bm_george",
                        "kokoro:af_bella", "kokoro:am_santa"])
    }

    /// TBX-10916: Heart for American or unspecified English, Emma for British, only when the
    /// engine offers it; nothing for other languages, so the configured default stands.
    func testTheEnglishNarratorDefault() {
        let both = ["kokoro:af_heart", "kokoro:bf_emma", "kokoro:bm_george"]
        XCTAssertEqual(VoiceCatalogue.narratorDefault(language: "en", region: nil, available: both), "kokoro:af_heart")
        XCTAssertEqual(VoiceCatalogue.narratorDefault(language: nil, region: nil, available: both), "kokoro:af_heart")
        XCTAssertEqual(VoiceCatalogue.narratorDefault(language: "en", region: "us", available: both), "kokoro:af_heart")
        XCTAssertEqual(VoiceCatalogue.narratorDefault(language: "en", region: "GB", available: both), "kokoro:bf_emma")
        XCTAssertNil(VoiceCatalogue.narratorDefault(language: "en", region: "gb", available: ["kokoro:af_heart"]),
                     "no Emma on this engine: not Heart either, the configured default")
        XCTAssertNil(VoiceCatalogue.narratorDefault(language: "en", region: nil, available: ["kokoro:bf_emma"]))
        XCTAssertNil(VoiceCatalogue.narratorDefault(language: "en", region: "au", available: both))
        XCTAssertNil(VoiceCatalogue.narratorDefault(language: "es", region: nil, available: both + ["kokoro:ef_dora"]))
    }

    func testLanguageTagsSplitIntoLanguageAndRegion() {
        XCTAssertTrue(LanguageTag.split("en-GB") == ("en", "gb"))
        XCTAssertTrue(LanguageTag.split("en_us") == ("en", "us"))
        XCTAssertTrue(LanguageTag.split("en") == ("en", nil))
        XCTAssertTrue(LanguageTag.split("zh-Hant-TW") == ("zh", "tw"))
        XCTAssertTrue(LanguageTag.split("es-419") == ("es", "419"))
        XCTAssertTrue(LanguageTag.split(" ") == (nil, nil))
    }

    /// The region a file declares reaches the document; the language stays the two-letter code
    /// everything else keys on.
    func testADeclaredBritishLanguageReachesTheDocument() throws {
        let page = "<html lang=\"en-GB\"><head><title>Colour</title></head><body><h1>Colour</h1><p>The colour of the sky was grey.</p></body></html>"
        let british = try DocumentImporter.importHTML(data: Data(page.utf8), contentType: "text/html", digest: "d",
                                                      kind: .html, fileName: nil, fallbackTitle: "x")
        XCTAssertEqual(british.language, "en")
        XCTAssertEqual(british.languageRegion, "gb")
        let plain = try DocumentImporter.importHTML(data: Data(page.replacingOccurrences(of: "en-GB", with: "en").utf8),
                                                    contentType: "text/html", digest: "d", kind: .html, fileName: nil, fallbackTitle: "x")
        XCTAssertEqual(plain.language, "en")
        XCTAssertNil(plain.languageRegion)
    }
}

final class VoiceTagsTests: XCTestCase {
    /// The listening pass (M4.7, 2026-10-15): every graded English Kokoro voice was heard and
    /// described; the two the owner ruled out are never suggested, though they stay describable.
    func testHeardTagsDescribeTheVoicesAndAvoidedOnesAreNeverOffered() {
        XCTAssertEqual(VoiceCatalogue.describe("kokoro:af_heart").tags, ["warm", "bright", "soft", "lively", "good for narration"])
        XCTAssertTrue(VoiceCatalogue.describe("kokoro:bm_george").tags.contains("good for narration and dialogue"))
        XCTAssertEqual(VoiceCatalogue.curatedTags.count, 26)
        let available = ["kokoro:af_aoede", "kokoro:bm_lewis", "kokoro:af_heart", "kokoro:bm_george"]
        let offered = VoiceCatalogue.candidates(language: "en", available: available).map(\.spec)
        XCTAssertEqual(Set(offered), ["kokoro:af_heart", "kokoro:bm_george"])
        XCTAssertFalse(offered.contains("kokoro:bm_lewis"), "graded B-, but heard as robotic")
    }
}

final class VoiceCasterTests: XCTestCase {
    private let available = ["kokoro:af_heart", "kokoro:af_bella", "kokoro:bf_emma", "kokoro:bm_george",
                             "kokoro:bm_fable", "kokoro:am_michael"]

    private func book() -> ImportedDocument {
        let body = (1...80).map { "Paragraph \($0) of a grave Edwardian story about a room under the earth." }
        return ImportedDocument(sourceSHA256: "x", sourceKind: .pdf, title: "The Machine Stops", author: "E. M. Forster",
                                language: "en", chapters: [DocumentChapter(index: 0, title: "One", paragraphs: body)],
                                frontMatter: ["First published in the Oxford and Cambridge Review, November 1909"])
    }

    func testThePromptCarriesAnExcerptAndOnlyTheOfferedVoices() {
        let candidates = VoiceCatalogue.candidates(language: "en", available: available)
        let prompt = VoiceCaster.prompt(for: book(), candidates: candidates)
        XCTAssertTrue(prompt.contains("TITLE: The Machine Stops"))
        XCTAssertTrue(prompt.contains("AUTHOR: E. M. Forster"))
        XCTAssertTrue(prompt.contains("November 1909"))
        XCTAssertTrue(prompt.contains("[...]"), "an excerpt from the middle as well as the opening")
        XCTAssertTrue(prompt.contains("- kokoro:bf_emma: british English, female, quality B-, clear, bright, crisp, lively, youthful, good for narration and dialogue"))
        XCTAssertFalse(prompt.contains("bm_daniel"))
        XCTAssertLessThan(prompt.count, 5_000)
    }

    func testAGoodReplyIsValidatedAndToppedUp() async {
        let reply = """
        <think>British, 1909, grave.</think>
        ```json
        {"genre": "dystopian novella", "era": "1909", "tone": "grave", "primary_voice": "bf_emma",
         "alternates": ["kokoro:bm_george", "kokoro:xx_invented"], "speed": 0.7,
         "rationale": "An Edwardian English story wants a measured British narrator."}
        ```
        """
        let s = await VoiceCaster.suggest(for: book(), available: available, languageDefault: "kokoro:af_heart",
                                          complete: { _, _ in (reply, "qwen3.5 on this Mac") })
        XCTAssertEqual(s.primary, "kokoro:bf_emma")
        XCTAssertEqual(s.alternates.first, "kokoro:bm_george")
        XCTAssertEqual(s.alternates.count, 2, "the invented id is dropped and the list topped up")
        XCTAssertFalse(s.alternates.contains("kokoro:xx_invented"))
        XCTAssertEqual(s.speed, 0.85, "speed is clamped")
        XCTAssertEqual(s.source, "qwen3.5 on this Mac")
        XCTAssertFalse(s.isFallback)
    }

    func testAnInventedPrimaryFallsBackAndSaysWhy() async {
        let s = await VoiceCaster.suggest(for: book(), available: available, languageDefault: "kokoro:af_heart",
                                          complete: { _, _ in (#"{"primary_voice": "bf_nobody"}"#, "the home server") })
        XCTAssertEqual(s.primary, "kokoro:af_heart")
        XCTAssertEqual(s.alternates, ["kokoro:bf_emma", "kokoro:am_michael"],
                       "narration-and-dialogue voices before Bella, who was heard as a dialogue voice")
        XCTAssertEqual(s.fallbackReason, "the home server answered, but not with a voice from the list")
    }

    func testNoModelOrAFailingOneStillGivesThreeRealVoices() async {
        struct Down: Error {}
        let none = await VoiceCaster.suggest(for: book(), available: available, languageDefault: "kokoro:bm_george",
                                             complete: nil)
        XCTAssertEqual(none.primary, "kokoro:af_heart", "an English book without a suggestion is read by Heart")
        XCTAssertEqual(none.fallbackReason, "no model is set up")
        let down = await VoiceCaster.suggest(for: book(), available: available, languageDefault: "kokoro:bm_george",
                                             complete: { _, _ in throw Down() })
        XCTAssertTrue(down.fallbackReason?.hasPrefix("no model answered") == true)
        XCTAssertTrue(([down.primary] + down.alternates).allSatisfy(available.contains))
    }

    /// TBX-10916: with no model, Emma for a book that declared British English, Heart for any
    /// other English, each only when offered; otherwise, and for other languages, the configured
    /// default as before.
    func testTheNarratorDefaultWhenNoModelSuggestsOne() async {
        var british = book()
        british.languageRegion = "gb"
        let emma = await VoiceCaster.suggest(for: british, available: available, languageDefault: "kokoro:bm_george", complete: nil)
        XCTAssertEqual(emma.primary, "kokoro:bf_emma")
        XCTAssertFalse(emma.alternates.contains("kokoro:bf_emma"))

        let noEmma = available.filter { $0 != "kokoro:bf_emma" }
        let configured = await VoiceCaster.suggest(for: british, available: noEmma, languageDefault: "kokoro:bm_george", complete: nil)
        XCTAssertEqual(configured.primary, "kokoro:bm_george", "Emma is not on this engine, so the configured default")

        let noHeart = available.filter { $0 != "kokoro:af_heart" }
        let american = await VoiceCaster.suggest(for: book(), available: noHeart, languageDefault: "kokoro:bm_fable", complete: nil)
        XCTAssertEqual(american.primary, "kokoro:bm_fable")

        var spanish = book()
        spanish.language = "es"
        let dora = await VoiceCaster.suggest(for: spanish, available: available + ["kokoro:ef_dora"],
                                             languageDefault: "kokoro:ef_dora", complete: nil)
        XCTAssertEqual(dora.primary, "kokoro:ef_dora", "a book in another language is unchanged")

        // A model's own choice of an offered voice stands.
        let chosen = await VoiceCaster.suggest(for: british, available: available, languageDefault: "kokoro:af_heart",
                                               complete: { _, _ in (#"{"primary_voice": "bm_fable"}"#, "m") })
        XCTAssertEqual(chosen.primary, "kokoro:bm_fable")
    }

    func testSecretsInTheBookNeverReachTheModel() async {
        let key = "sk-" + "abcdefghijklmnopqrstuvwxyz012345"
        var doc = book()
        doc.chapters[0].paragraphs[0] = "The code was \(key), written on the wall."
        let seen = PromptBox()
        _ = await VoiceCaster.suggest(for: doc, available: available, languageDefault: "kokoro:af_heart",
                                      complete: { _, user in seen.set(user); return ("{}", "m") })
        XCTAssertFalse(seen.value.contains(key))
        XCTAssertTrue(seen.value.contains("a redacted token"))
    }
}

final class PromptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""
    func set(_ v: String) { lock.lock(); _value = v; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return _value }
}

final class StoragePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * StoragePolicy.day) }

    private func items() -> [StoragePolicy.Item] {
        [
            .init(id: "reading", title: "An article", bytes: 2_000_000, isBook: false, addedAt: daysAgo(200)),
            .init(id: "finished-old", title: "Old book", bytes: 30_000_000, isBook: true, addedAt: daysAgo(60),
                  lastPlayedAt: daysAgo(40), finishedAt: daysAgo(40)),
            .init(id: "finished-new", title: "New book", bytes: 20_000_000, isBook: true, addedAt: daysAgo(10),
                  lastPlayedAt: daysAgo(2), finishedAt: daysAgo(2)),
            .init(id: "listening", title: "Current book", bytes: 40_000_000, isBook: true, addedAt: daysAgo(300),
                  lastPlayedAt: daysAgo(300), inProgress: true),
            .init(id: "kept", title: "Favourite", bytes: 25_000_000, isBook: true, addedAt: daysAgo(400),
                  lastPlayedAt: daysAgo(400), finishedAt: daysAgo(400), keep: true),
            .init(id: "offloaded", title: "Gone already", bytes: 10_000_000, isBook: true, addedAt: daysAgo(90),
                  finishedAt: daysAgo(90), downloaded: false),
        ]
    }

    func testWithNoRulesNothingIsRemoved() {
        XCTAssertEqual(StoragePolicy.removals(items(), rules: .none, now: now), [])
    }

    func testAfterFinishedRemovesOnlyFinishedDownloadsPastTheDelay() {
        let r = StoragePolicy.removals(items(), rules: .defaults, now: now)
        XCTAssertEqual(r, [StoragePolicy.Removal(id: "finished-old", bytes: 30_000_000, reason: .finished(daysAgo: 40))])
        let rightAway = StoragePolicy.removals(items(), rules: .init(afterFinished: 0), now: now).map(\.id)
        XCTAssertEqual(rightAway, ["finished-old", "finished-new"])
    }

    func testUnplayedNeverTakesTheBookInProgressOrAKeep() {
        let r = StoragePolicy.removals(items(), rules: .init(unplayedFor: 30 * StoragePolicy.day), now: now).map(\.id)
        XCTAssertEqual(r, ["reading", "finished-old"])
        XCTAssertFalse(r.contains("listening"), "300 days unplayed, but in progress")
        XCTAssertFalse(r.contains("kept"))
    }

    func testSpaceLimitRemovesFinishedFirstLeastRecentlyPlayedFirst() {
        // Downloaded: 2 + 30 + 20 + 40 + 25 = 117 MB. Limit 70 MB: finished-old (30) then
        // finished-new (20) brings it to 67. The reading, the current book and the Keep stay.
        let r = StoragePolicy.removals(items(), rules: .init(spaceLimit: 70_000_000), now: now)
        XCTAssertEqual(r.map(\.id), ["finished-old", "finished-new"])
        XCTAssertTrue(r.allSatisfy { $0.reason == .overSpaceLimit })
        // An impossible limit still never touches the protected two.
        let all = StoragePolicy.removals(items(), rules: .init(spaceLimit: 1), now: now).map(\.id)
        XCTAssertEqual(Set(all), ["finished-old", "finished-new", "reading"])
    }

    func testSuggestionsTeachTheRuleAtMostWeekly() {
        let s = StoragePolicy.suggestions(items(), rules: .none, now: now, freeBytes: 50_000_000_000, lastSuggestedAt: nil)
        XCTAssertEqual(s, [StoragePolicy.Suggestion(kind: .finishedItem(daysAgo: 40), ids: ["finished-old"], bytes: 30_000_000)])
        XCTAssertEqual(StoragePolicy.suggestions(items(), rules: .none, now: now, freeBytes: nil,
                                                 lastSuggestedAt: daysAgo(3)), [])
        // With the rule set, the finished book is the rule's job, not a suggestion's.
        XCTAssertEqual(StoragePolicy.suggestions(items(), rules: .defaults, now: now, freeBytes: nil, lastSuggestedAt: nil), [])
    }

    func testLowSpaceOffersTheLargestFinishedItems() {
        let s = StoragePolicy.suggestions(items(), rules: .none, now: now, freeBytes: 900_000_000, lastSuggestedAt: nil)
        XCTAssertEqual(s.first, StoragePolicy.Suggestion(kind: .lowDeviceSpace(freeBytes: 900_000_000),
                                                         ids: ["finished-old", "finished-new"], bytes: 50_000_000))
        XCTAssertEqual(s.count, 1, "the finished-item suggestion is already covered by the low-space one")
    }

    func testChoiceLabelsAreUserCopyWithoutDashes() {
        let labels = StoragePolicy.Rules.afterFinishedChoices.map(\.0) + StoragePolicy.Rules.unplayedChoices.map(\.0)
            + StoragePolicy.Rules.spaceChoices.map(\.0)
        XCTAssertFalse(labels.contains { $0.contains("\u{2014}") || $0.contains("\u{2013}") })
    }
}
