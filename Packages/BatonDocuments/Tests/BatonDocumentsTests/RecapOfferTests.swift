import Foundation
import XCTest
@testable import BatonDocuments

/// "Previously…" as both apps decide it: the offer rule from a synced position, the
/// spoiler bound when the app has only chapter texts, the one router call, and the voice the
/// recap is said in. The Mac and the iPhone call these, so neither keeps its own copy.
final class RecapOfferTests: XCTestCase {
    /// Chapter 1 is long enough to recap on its own; chapter 2 names the glass key only in its
    /// second half; chapter 3 is all unheard.
    private static let chapters: [Recap.ChapterText] = [
        .init(index: 0, title: "The House",
              text: (1...30).map { "Ada wound the great clock in the hall for the \($0) time that winter." }.joined(separator: " "),
              durationSeconds: 120),
        .init(index: 1, title: "The Letter",
              text: (1...10).map { "A letter came that was not from Tobias, number \($0)." }.joined(separator: " ")
                  + " " + (1...10).map { "Inside the case she found the little glass key, turn \($0)." }.joined(separator: " "),
              durationSeconds: 60),
        .init(index: 2, title: "The Return", text: "Tobias came home and would not say who sent the letter.", durationSeconds: 30),
    ]

    private func book() throws -> PreparedBook {
        try XCTUnwrap(Recap.book(documentID: "doc", title: "The Clock", author: nil, chapters: Self.chapters))
    }

    func testTheBookIsMadeFromChapterTextsInOrder() throws {
        let shuffled = Recap.book(documentID: "doc", title: "The Clock", author: nil, chapters: Self.chapters.reversed())
        XCTAssertEqual(shuffled?.chapters.map(\.title), ["The House", "The Letter", "The Return"])
        XCTAssertEqual(shuffled?.chapters[0].segments.count, 30, "one segment a sentence")
        XCTAssertEqual(shuffled?.chapters[0].segments[4].paragraph, 1, "four sentences to a passage")
        XCTAssertNil(Recap.book(documentID: "d", title: "t", author: nil,
                                chapters: [.init(index: 0, title: "Empty", text: "  ")]), "no words, no book")
    }

    func testOfferedOnlyAfterADayWithEnoughHeard() throws {
        let b = try book()
        let now = Date()
        let midway: (chapterIndex: Int, seconds: Double) = (1, 30)
        XCTAssertTrue(Recap.shouldOffer(book: b, synced: midway, chapterDuration: 60, finished: false,
                                        lastPlayed: now.addingTimeInterval(-25 * 3600), now: now))
        XCTAssertFalse(Recap.shouldOffer(book: b, synced: midway, chapterDuration: 60, finished: false,
                                         lastPlayed: now.addingTimeInterval(-23 * 3600), now: now), "under a day is not a break")
        XCTAssertFalse(Recap.shouldOffer(book: b, synced: midway, chapterDuration: 60, finished: false,
                                         lastPlayed: nil, now: now), "never played")
        XCTAssertFalse(Recap.shouldOffer(book: b, synced: midway, chapterDuration: 60, finished: true,
                                         lastPlayed: now.addingTimeInterval(-3 * 86_400), now: now), "a finished book is not resumed")
        XCTAssertFalse(Recap.shouldOffer(book: b, synced: nil, chapterDuration: nil, finished: false,
                                         lastPlayed: now.addingTimeInterval(-3 * 86_400), now: now), "no position, nothing heard")
        XCTAssertFalse(Recap.shouldOffer(book: b, synced: (0, 10), chapterDuration: 120, finished: false,
                                         lastPlayed: now.addingTimeInterval(-3 * 86_400), now: now),
                       "a few sentences in is too little to recap")
    }

    /// Halfway through chapter 2: chapter 1 and the letter are heard; the glass key, in the second
    /// half, and chapter 3 never reach the model.
    func testTheRecapPromptStopsAtThePosition() async throws {
        let b = try book()
        let position = Recap.position(in: b, synced: (1, 30), chapterDuration: 60, finished: false)
        XCTAssertEqual(position, BookPosition(chapter: 1, segment: 10))
        let sent = SentPrompt()
        let local = ModelSource(name: "qwen on the LAN", provider: .openAICompatible, baseURL: "http://192.168.1.20:11434/v1",
                                model: "qwen3:8b", contextTokens: 8_192)
        let recap = await Recap.write(book: b, position: position, sources: [local]) { source, _, user in
            await sent.set(user, source.name)
            return "Previously, Ada wound the clock all winter, and a letter came that was not from Tobias."
        }
        XCTAssertEqual(recap?.source, "qwen on the LAN")
        let user = await sent.user
        XCTAssertTrue(user.contains("Ada wound the great clock"))
        XCTAssertTrue(user.contains("number 10."), "the heard half of chapter 2")
        XCTAssertFalse(user.contains("glass key"), "the unheard half of chapter 2 is a spoiler")
        XCTAssertFalse(user.contains("Tobias came home"), "chapter 3 is a spoiler")
    }

    func testACloudModelIsNotSentChaptersWithoutConsent() async throws {
        let b = try book()
        let position = Recap.position(in: b, synced: (1, 30), chapterDuration: 60, finished: false)
        let cloud = ModelSource(name: "Anthropic", provider: .anthropic, baseURL: "https://api.anthropic.com",
                                model: "claude", contextTokens: 200_000)
        let called = SentPrompt()
        let none = await Recap.write(book: b, position: position, sources: [cloud]) { source, _, user in
            await called.set(user, source.name)
            return "Previously, something."
        }
        XCTAssertNil(none)
        let user = await called.user
        XCTAssertTrue(user.isEmpty, "the cloud source was asked without consent")

        let allowed = ModelConsent().granting(cloud, .chapter)
        let made = await Recap.write(book: b, position: position, sources: [cloud], consent: allowed) { _, _, _ in
            "Previously, Ada wound the clock all winter and a letter came."
        }
        XCTAssertEqual(made?.source, "Anthropic")
    }

    func testTheRecapVoiceIsNeverTheNarrators() {
        for narrator in ["kokoro:af_heart", "kokoro:am_michael", "kokoro:bf_emma", "kokoro:bm_george", "kokoro:af_bella",
                         "kokoro:ff_siwis", "chatterbox:default", "af_heart", "", "system:Samantha"] {
            let voice = Recap.voice(otherThan: narrator)
            XCTAssertNotEqual(voice.lowercased(), narrator.lowercased(), narrator)
            XCTAssertNotEqual(voice.split(separator: ":").last.map(String.init), narrator.split(separator: ":").last.map(String.init),
                              "same voice under another engine name: \(narrator)")
            XCTAssertTrue(voice.hasPrefix("kokoro:"), voice)
        }
        XCTAssertEqual(Recap.voice(otherThan: "kokoro:bf_emma"), "kokoro:bm_george", "British stays British")
        XCTAssertEqual(Recap.voice(otherThan: "kokoro:am_michael"), "kokoro:af_heart")
    }

    func testARecapFitsTheSpeechRouteAtASentenceEnd() {
        let short = "Previously, Ada wound the clock."
        XCTAssertEqual(Recap.fitting(short, characters: 600), short)
        let long = (1...20).map { "Sentence \($0) says what Ada did in the hall that day." }.joined(separator: " ")
        let fitted = Recap.fitting(long, characters: 200)
        XCTAssertLessThanOrEqual(fitted.count, 200)
        XCTAssertTrue(fitted.hasSuffix("day."), fitted)
        XCTAssertEqual(Recap.offerText(title: "The Clock"),
                       "It has been a while since you heard The Clock. Hear a short recap of what you have heard, then carry on?")
    }
}

private actor SentPrompt {
    var user = ""
    var source = ""
    func set(_ user: String, _ source: String) { self.user = user; self.source = source }
}
