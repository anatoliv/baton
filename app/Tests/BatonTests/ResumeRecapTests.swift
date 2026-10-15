import AVFoundation
import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// "Previously…" on the Mac (M8.4): offered only when the package says a recap is due, written
/// through the router over local sources alone, cleaned for the ear, and never in the way of
/// the book when no model answers.
@MainActor
final class ResumeRecapTests: XCTestCase {

    private var root: URL!
    private var clippings: ClippingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-recap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                  defaults: ThrowawayDefaults.make("recap"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func tone(seconds: Double) throws -> URL {
        let url = root.appendingPathComponent("tone-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(24_000 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
    }

    /// Enough heard text for a recap: two chapters of a few hundred words each.
    private static func chapter(_ n: Int) -> String {
        (1...40).map { "Sentence \($0) of chapter \(n) tells what Vashti and Kuno did next in the hexagonal room." }
            .joined(separator: " ")
    }

    /// A two-chapter book in Clippings with a position inside chapter 2, last played `ago`.
    private func book(lastPlayed ago: TimeInterval, finished: Bool = false) throws -> BookShelf.Book {
        for index in 0..<2 {
            try clippings.adopt(try tone(seconds: 10), title: "Chapter \(index + 1)", durationSeconds: 10,
                                text: Self.chapter(index + 1),
                                chapter: .init(documentID: "doc", documentTitle: "The Machine Stops", author: nil,
                                               chapterIndex: index, chapterTitle: "Chapter \(index + 1)"))
        }
        var ledger = clippings.ledger
        ledger.setPosition(documentID: "doc", chapterIndex: 1, seconds: 5, at: Date(timeIntervalSinceNow: -ago))
        if finished { ledger.setFinished(true, documentID: "doc") }
        clippings.ledger = ledger
        return try XCTUnwrap(BookShelf.entries(items: clippings.items, jobs: [], ledger: clippings.ledger)
            .compactMap { if case let .book(b) = $0 { b } else { nil } }.first)
    }

    private static let local = ModelSource(name: "qwen on this Mac", provider: .ollama, baseURL: "http://127.0.0.1:11434",
                                           model: "qwen3:8b", contextTokens: 8_192)
    private static let cloud = ModelSource(name: "Anthropic", provider: .anthropic, baseURL: "https://api.anthropic.com",
                                           model: "claude", contextTokens: 200_000)

    func testOfferedAfterADayAwayAndNotOtherwise() throws {
        let stale = try book(lastPlayed: 2 * 24 * 3600)
        let prepared = try XCTUnwrap(BookText.fromClippings(stale))
        let lastPlayed = clippings.ledger.document("doc")?.positionAt
        XCTAssertTrue(ResumeRecap.shouldOffer(book: stale, prepared: prepared, lastPlayed: lastPlayed))
        XCTAssertTrue(BookRecapOffer().consider(stale, prepared: prepared, lastPlayed: lastPlayed))
        XCTAssertFalse(ResumeRecap.shouldOffer(book: stale, prepared: prepared, lastPlayed: Date(timeIntervalSinceNow: -3600)),
                       "an hour's break is not a break")
        XCTAssertFalse(ResumeRecap.shouldOffer(book: stale, prepared: prepared, lastPlayed: nil), "never played: nothing to recap")

        var finished = stale
        finished.finished = true
        XCTAssertFalse(ResumeRecap.shouldOffer(book: finished, prepared: prepared, lastPlayed: lastPlayed), "a finished book is not resumed")
        XCTAssertFalse(BookRecapOffer().consider(stale, prepared: nil, lastPlayed: lastPlayed), "no text, no recap")
    }

    func testTheRecapIsWrittenByALocalSourceOnlyAndCleanedForTheEar() async throws {
        let stale = try book(lastPlayed: 2 * 24 * 3600)
        let prepared = try XCTUnwrap(BookText.fromClippings(stale))
        let position = BookText.position(in: prepared, book: stale)
        let asked = Asked()
        let recap = await ResumeRecap.write(prepared: prepared, position: position, sources: [Self.cloud, Self.local]) { source, system, user in
            asked.sources.append(source.name)
            asked.prompt = user
            return "<think>hmm</think>## Recap\n\n**Previously**, Vashti sat in her room and \"Kuno\" called from far away."
        }
        XCTAssertEqual(asked.sources, ["qwen on this Mac"], "the cloud source is never asked")
        XCTAssertEqual(recap?.source, "qwen on this Mac")
        XCTAssertEqual(recap?.text, "Previously, Vashti sat in her room and Kuno called from far away.")
        XCTAssertTrue(asked.prompt.contains("Sentence 1 of chapter 1"), "chapter 1 was heard")
        XCTAssertFalse(asked.prompt.contains("Sentence 40 of chapter 2"), "the end of chapter 2 was not: \(asked.prompt.suffix(200))")

        let none = await ResumeRecap.write(prepared: prepared, position: position, sources: [Self.cloud]) { _, _, _ in "anything" }
        XCTAssertNil(none, "with only a cloud source there is no recap, and no call")
    }

    /// M4.6: the router decides, so a cloud source the person allowed chapters writes the
    /// recap, and one allowed only excerpts is skipped with a line that names it.
    func testACloudSourceWritesTheRecapOnlyWithConsentForChapters() async throws {
        let stale = try book(lastPlayed: 2 * 24 * 3600)
        let prepared = try XCTUnwrap(BookText.fromClippings(stale))
        let position = BookText.position(in: prepared, book: stale)
        var chapters = ModelConsent()
        chapters.grant(Self.cloud, .chapter)
        let asked = Asked()
        let recap = await ResumeRecap.write(prepared: prepared, position: position, sources: [Self.cloud],
                                            consent: chapters) { source, _, _ in
            asked.sources.append(source.name)
            return "Previously, Vashti sat in her room while Kuno called from the other side of the world."
        }
        XCTAssertEqual(asked.sources, ["Anthropic"])
        XCTAssertEqual(recap?.source, "Anthropic")

        var excerpts = ModelConsent()
        excerpts.grant(Self.cloud, .excerpt)
        let none = await ResumeRecap.write(prepared: prepared, position: position, sources: [Self.cloud],
                                           consent: excerpts) { _, _, _ in "anything" }
        XCTAssertNil(none, "excerpts were allowed, chapters were not")
        XCTAssertEqual(ResumeRecap.noRecapLine(sources: [Self.cloud], consent: excerpts),
                       "No model on this Mac or the home server wrote a recap, and sending chapters to Anthropic is not allowed, so the book plays as it is.")
        XCTAssertEqual(ResumeRecap.noRecapLine(sources: [Self.local], consent: ModelConsent()),
                       "No model on this Mac or the home server wrote a recap, so the book plays as it is.")
    }

    func testHearingSpeaksThenPlaysAndASilentModelStillPlays() async throws {
        let stale = try book(lastPlayed: 2 * 24 * 3600)
        let prepared = try XCTUnwrap(BookText.fromClippings(stale))
        let offer = BookRecapOffer()
        XCTAssertTrue(offer.consider(stale, prepared: prepared, lastPlayed: clippings.ledger.document("doc")?.positionAt))
        var order: [String] = []
        await offer.hear(sources: [Self.local], executor: { _, _, _ in "Previously, a great deal happened to Vashti and to Kuno in the room." },
                         speak: { text in order.append("spoke: \(text)"); return true },
                         thenPlay: { order.append("played") })
        XCTAssertEqual(order, ["spoke: Previously, a great deal happened to Vashti and to Kuno in the room.", "played"])
        XCTAssertNil(offer.offer, "done with")

        XCTAssertTrue(offer.consider(stale, prepared: prepared, lastPlayed: clippings.ledger.document("doc")?.positionAt))
        order = []
        await offer.hear(sources: [Self.local], executor: { _, _, _ in throw URLError(.cannotConnectToHost) },
                         speak: { _ in order.append("spoke"); return true },
                         thenPlay: { order.append("played") })
        XCTAssertEqual(order, ["played"], "no recap, no speech, still the book")
        if case .failed = offer.state {} else { XCTFail("says why: \(offer.state)") }
    }

    private final class Asked: @unchecked Sendable {
        var sources: [String] = []
        var prompt = ""
    }
}
