import XCTest
@testable import BatonAgentKit
import BatonPlaybackKit
import BatonSubsonicKit
import BatonSubsonicModels

/// The store exists to hold the few things a music server cannot answer — and,
/// just as importantly, to be unable to hold anything else.
@MainActor
final class RemoteMemoryStoreTests: XCTestCase {
    private func store() -> RemoteMemoryStore { RemoteMemoryStore(url: nil) }

    /// The rule the whole design rests on: every stored sentence traces to
    /// something the person actually said. There is no field for an inference,
    /// which is what makes "seems to like sad music on Sundays" impossible
    /// rather than merely discouraged.
    func testAMemoryWithoutTheOwnersWordsIsRefused() {
        let memory = store()
        XCTAssertNil(memory.remember(kind: "preference", text: "Likes sad music on Sundays", quote: ""))
        XCTAssertNil(memory.remember(kind: "preference", text: "", quote: "i said something"))
        XCTAssertTrue(memory.entries.isEmpty)
    }

    func testRememberingKeepsTheQuoteAndNumbersTheEntry() throws {
        let memory = store()
        let entry = try XCTUnwrap(memory.remember(
            kind: "preference", text: "No vocals while working",
            quote: "no vocals when i'm working please"))

        XCTAssertEqual(entry.id, 1)
        XCTAssertEqual(entry.quote, "no vocals when i'm working please")
        XCTAssertTrue(memory.listing().contains("no vocals when i'm working please"),
                      "the listing must show what was actually said, not just Baton's gloss")
    }

    /// Saying the same thing again is a correction, not a second memory —
    /// otherwise the store fills with near-duplicates and the rendered block
    /// argues with itself.
    func testRepeatingAMemoryReplacesItRatherThanStacking() {
        let memory = store()
        memory.remember(kind: "preference", text: "No vocals while working", quote: "no vocals")
        memory.remember(kind: "preference", text: "no vocals while working", quote: "seriously, no vocals")
        XCTAssertEqual(memory.entries.count, 1)
        XCTAssertEqual(memory.entries.first?.quote, "seriously, no vocals")
    }

    func testForgettingByNumberAndForgettingEverything() {
        let memory = store()
        memory.remember(kind: "fact", text: "Gothic playlists are my partner's", quote: "those are my partner's")
        memory.remember(kind: "preference", text: "No vocals while working", quote: "no vocals")

        XCTAssertNotNil(memory.forget(id: 1))
        XCTAssertNil(memory.forget(id: 1), "already gone")
        XCTAssertEqual(memory.entries.count, 1)

        memory.forgetEverything()
        XCTAssertTrue(memory.entries.isEmpty)
        XCTAssertNil(memory.rendered())
    }

    /// A friend mentions the play count once. Software that mentions it on
    /// plays 34, 35 and 36 is a scold — so the cap lives in code, where the
    /// model can't forget it.
    func testAFactIsMentionedOnceADayNotEveryTime() {
        let memory = store()
        let monday = Date(timeIntervalSince1970: 1_770_000_000)

        XCTAssertTrue(memory.mayMention("play_count", now: monday))
        memory.recordMention("play_count", now: monday)

        XCTAssertFalse(memory.mayMention("play_count", now: monday.addingTimeInterval(3600)))
        XCTAssertFalse(memory.mayMention("play_count", now: monday.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(memory.mayMention("play_count", now: monday.addingTimeInterval(25 * 3600)))
        // Different kinds of remark don't share a budget.
        XCTAssertTrue(memory.mayMention("repeat", now: monday))
    }

    func testRecentPicksAreNewestFirstAndBounded() {
        let memory = store()
        for index in 1 ... 12 {
            memory.recordPick("Pick \(index)", key: "telegram:c1")
        }
        let picks = memory.recentPicks(key: "telegram:c1")
        XCTAssertEqual(picks.first?.what, "Pick 12")
        XCTAssertLessThanOrEqual(picks.count, RemoteMemoryStore.pickLimit)
        XCTAssertTrue(memory.recentPicks(key: "telegram:other").isEmpty, "picks are per chat")
    }

    /// The file is meant to be opened and read by the person it describes.
    func testItRoundTripsThroughAReadableFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-memory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = RemoteMemoryStore(url: url)
        first.remember(kind: "vocabulary", text: "“My trance” means the Classic Trance playlists",
                       quote: "when i say my trance i mean the classic trance ones")
        first.recordPick("Chillout mix", key: "telegram:c1")

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("classic trance"), "stored verbatim and legible")
        XCTAssertTrue(text.contains("\n"), "pretty-printed, not a single line")

        let second = RemoteMemoryStore(url: url)
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.recentPicks(key: "telegram:c1").first?.what, "Chillout mix")
    }
}

// MARK: - Notes Baton attaches to results

@MainActor
final class RemoteAgentAnnotationTests: XCTestCase {
    private let playing = #"{"playing":{"title":"Absolutely","artist":"DIDO","play_count":34},"queued":12}"#

    /// Prose could not buy this: told to "push back sometimes", the model
    /// either never did or invented opinions. Told the number in the result it
    /// is already reading, it can say something true.
    func testARemarkablePlayCountIsAttachedOnce() {
        let memory = RemoteMemoryStore(url: nil)
        let first = RemoteAgentResults.annotate(playing, tool: "music_play", memory: memory)
        XCTAssertTrue(first.contains("34 plays"), first)
        XCTAssertTrue(first.contains("baton_note"), "must arrive as data, not prose")

        // Second play, same day: silence.
        let second = RemoteAgentResults.annotate(playing, tool: "music_play", memory: memory)
        XCTAssertFalse(second.contains("baton_note"), "a friend mentions it once")
    }

    func testAnOrdinaryPlayCountSaysNothing() {
        let quiet = #"{"playing":{"title":"White Flag","artist":"Dido","play_count":2}}"#
        let out = RemoteAgentResults.annotate(quiet, tool: "music_play", memory: RemoteMemoryStore(url: nil))
        XCTAssertFalse(out.contains("baton_note"))
    }

    /// The structural answer to ask_choice firing 0–3 times in 109 messages:
    /// the model is bad at noticing its own about-to-be-written sentence and
    /// reliable at reacting to a notice in a tool result.
    func testTwoArtistsWithTheSameNameSeedAChoice() {
        let search = #"""
        {"songs":[],"albums":[],"artists":[{"id":"a1","name":"DIDO"},{"id":"a2","name":"Dido"}]}
        """#
        let out = RemoteAgentResults.annotate(search, tool: "music_search", memory: RemoteMemoryStore(url: nil))
        XCTAssertTrue(out.contains("ask_choice"), out)
        XCTAssertTrue(out.contains("Dido"), out)
    }

    func testOneArtistNeedsNoChoice() {
        let search = #"{"songs":[],"albums":[],"artists":[{"id":"a1","name":"Armin van Buuren"}]}"#
        let out = RemoteAgentResults.annotate(search, tool: "music_search", memory: RemoteMemoryStore(url: nil))
        XCTAssertFalse(out.contains("baton_note"))
    }

    /// Playing the same thing twice earns a light remark — never a refusal.
    func testARepeatIsNoticedButNeverBlocks() {
        let memory = RemoteMemoryStore(url: nil)
        let picks = [RemoteMemoryStore.Pick(what: "▶︎ Absolutely — DIDO", when: Date())]
        let out = RemoteAgentResults.annotate(
            playing, tool: "music_play", memory: memory, recentPicks: picks)
        XCTAssertTrue(out.contains("second time"), out)
        XCTAssertTrue(out.contains("play what was asked"), "pushback must never become refusal")
    }
}

// MARK: - The taste digest

@MainActor
final class RemoteTasteDigestTests: XCTestCase {
    private func summary() -> RemoteTasteDigest.Summary {
        var summary = RemoteTasteDigest.Summary()
        summary.genres = [("Trance", 107), ("Electronic", 105), ("Gothic", 68)]
        summary.mostPlayed = [("Absolutely", "DIDO", 34), ("Mainstage", "Markus Schulz", 21)]
        summary.likedSongs = 65
        summary.likedArtists = ["Cerf, Mitiska & Jaren"]
        summary.recentlyAdded = ["Lost in Love — Unknown"]
        summary.playlistCount = 62
        summary.playlistNames = ["02 - Classic Trance (Pt 1)"]
        return summary
    }

    func testTheDigestIsCountsAndNamesRatherThanCharacterisation() throws {
        let rendered = try XCTUnwrap(RemoteTasteDigest.render(summary()))
        XCTAssertTrue(rendered.contains("Trance (107)"))
        XCTAssertTrue(rendered.contains("34 plays"))
        XCTAssertTrue(rendered.contains("65 songs"))
        XCTAssertTrue(rendered.contains("62"))
        XCTAssertTrue(rendered.contains("facts, not guesses"))
        XCTAssertLessThan(rendered.count, 900, "it rides on every request")
    }

    func testAnEmptyLibrarySaysNothingRatherThanSayingNothingAtLength() {
        XCTAssertNil(RemoteTasteDigest.render(RemoteTasteDigest.Summary()))
    }

    /// A digest is grounding, not a dependency: a server that won't answer must
    /// cost the model some context, never cost the person their reply.
    func testAFailedLoadIsSurvivable() async {
        let digest = RemoteTasteDigest()
        digest.loadSummary = { throw NavidromeError.notConfigured }
        let value = await digest.current()
        XCTAssertNil(value)
    }

    func testItIsBuiltOnceADayNotOncePerMessage() async {
        let digest = RemoteTasteDigest()
        var loads = 0
        digest.loadSummary = { loads += 1; return self.summary() }

        let monday = Date(timeIntervalSince1970: 1_770_000_000)
        _ = await digest.current(now: monday)
        _ = await digest.current(now: monday.addingTimeInterval(60))
        _ = await digest.current(now: monday.addingTimeInterval(3600))
        XCTAssertEqual(loads, 1, "a library changes slowly")

        _ = await digest.current(now: monday.addingTimeInterval(25 * 3600))
        XCTAssertEqual(loads, 2)
    }
}
