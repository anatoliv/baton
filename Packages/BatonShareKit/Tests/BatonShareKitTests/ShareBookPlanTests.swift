@testable import BatonShareKit
import XCTest

/// A book's chapters onto the links that exist (`specs/book-sharing.md`, Phase 1).
final class ShareBookPlanTests: XCTestCase {
    private func chapters(_ seconds: [Double], bytesPerSecond: Int = 6000) -> [ShareBookPlan.Chapter] {
        seconds.enumerated().map { i, s in
            .init(index: i, title: "Chapter \(i + 1)", durationSeconds: s, bytes: Int(s) * bytesPerSecond)
        }
    }

    func testOneChapterIsASongLinkAndTwoToTwelveAreAMixtape() {
        XCTAssertEqual(try ShareBookPlan.check(chapters([300])).get(), .song)
        XCTAssertEqual(try ShareBookPlan.check(chapters([300, 300])).get(), .mixtape)
        XCTAssertEqual(try ShareBookPlan.check(chapters(Array(repeating: 60, count: 12))).get(), .mixtape)
    }

    func testThirteenChaptersAreRefused() {
        XCTAssertEqual(ShareBookPlan.check(chapters(Array(repeating: 60, count: 13))), .failure(.tooManyChapters(max: 12)))
    }

    func testASelectionThatSkipsAMissingChapterIsRefused() {
        // Chapters 1, 2 and 4 are here; chapter 3 was removed from this device.
        var here = chapters([60, 60, 60, 60])
        here.remove(at: 2)
        XCTAssertEqual(ShareBookPlan.check(here), .failure(.missingChapter(3)))
        XCTAssertEqual(ShareBookPlan.defaultRange(here), 0 ... 1, "the default stops before the gap")
        XCTAssertEqual(try ShareBookPlan.check(Array(here[2...])).get(), .song)
    }

    func testNothingSelectedIsRefused() {
        XCTAssertEqual(ShareBookPlan.check([]), .failure(.nothingSelected))
    }

    func testTheDurationCapIsTheServicesAndRoundsUp() {
        // 1,200 whole seconds fit; a chapter of 1,199.2 s is declared as 1,200, so one more
        // second anywhere does not.
        XCTAssertEqual(try ShareBookPlan.check(chapters([600, 600])).get(), .mixtape)
        XCTAssertEqual(ShareBookPlan.check(chapters([600, 600.2])), .failure(.tooLong(seconds: 1201, maxSeconds: 1200)))
        let tighter = ShareBookPlan.Limits(maxDurationSeconds: 900, maxAudioBytes: 26_214_400, mixtapes: true)
        XCTAssertEqual(ShareBookPlan.check(chapters([600, 600]), limits: tighter), .failure(.tooLong(seconds: 1200, maxSeconds: 900)))
    }

    func testTheByteCapCountsSealedBytes() {
        // Exactly at the cap once sealed is allowed; one more plaintext byte is not.
        let cap = 26_214_400
        var plain = cap - (ShareCrypto.sealedLength(plaintextLength: cap) - cap)
        while ShareCrypto.sealedLength(plaintextLength: plain + 1) <= cap { plain += 1 }
        let fits = [ShareBookPlan.Chapter(index: 0, title: "A", durationSeconds: 60, bytes: plain)]
        XCTAssertEqual(try ShareBookPlan.check(fits).get(), .song)
        let over = [ShareBookPlan.Chapter(index: 0, title: "A", durationSeconds: 60, bytes: plain + 1)]
        guard case .failure(.tooLarge) = ShareBookPlan.check(over) else { return XCTFail("a byte over the cap fits") }
    }

    func testWithoutMixtapesOnlyOneChapterGoes() {
        let songsOnly = ShareBookPlan.Limits(maxDurationSeconds: 1200, maxAudioBytes: 26_214_400, mixtapes: false)
        XCTAssertEqual(try ShareBookPlan.check(chapters([60]), limits: songsOnly).get(), .song)
        XCTAssertEqual(ShareBookPlan.check(chapters([60, 60]), limits: songsOnly), .failure(.tooManyChapters(max: 1)))
        XCTAssertEqual(ShareBookPlan.defaultRange(chapters([60, 60]), limits: songsOnly), 0 ... 0)
    }

    func testTheDefaultIsTheWholeBookWhenItFits() {
        XCTAssertEqual(ShareBookPlan.defaultRange(chapters([200, 300, 400])), 0 ... 2)
    }

    func testTheDefaultIsTheLongestRunFromTheFirstChapter() {
        XCTAssertEqual(ShareBookPlan.defaultRange(chapters([500, 500, 500, 100])), 0 ... 1)
        XCTAssertEqual(ShareBookPlan.defaultRange(chapters(Array(repeating: 30, count: 20))), 0 ... 11)
    }

    func testNoDefaultWhenTheFirstChapterIsTooLong() {
        // A novel's 45-minute chapter does not fit a link today.
        XCTAssertNil(ShareBookPlan.defaultRange(chapters([2700, 60])))
        XCTAssertNil(ShareBookPlan.defaultRange([]))
    }

    func testTitlesSayWhichChaptersWhenNotAllOfThem() {
        let all = chapters([60, 60, 60, 60, 60, 60])
        XCTAssertEqual(ShareBookPlan.title(book: "Middlemarch", selected: all, chapterCount: 6), "Middlemarch")
        XCTAssertEqual(ShareBookPlan.title(book: "Middlemarch", selected: Array(all[2 ... 5]), chapterCount: 6),
                       "Middlemarch, chapters 3 to 6")
        XCTAssertEqual(ShareBookPlan.title(book: "Middlemarch", selected: [all[1]], chapterCount: 6), "Middlemarch, chapter 2")
        XCTAssertEqual(ShareBookPlan.title(book: "  ", selected: all, chapterCount: 6), "A book")
    }

    func testTitlesFitTheWireAndLoseControlCharacters() throws {
        let long = String(repeating: "é", count: 300)
        let title = ShareBookPlan.title(book: long, selected: [chapters([60, 60])[1]], chapterCount: 2)
        XCTAssertLessThanOrEqual(title.unicodeScalars.count, ShareLimits.maxTitleLength)
        XCTAssertTrue(title.hasSuffix("…, chapter 2"))
        XCTAssertEqual(try ShareText.clean(title, field: "title", max: ShareLimits.maxTitleLength), title)

        let heading = ShareBookPlan.Chapter(index: 1, title: "Part One\n\tThe Beginning", durationSeconds: 60, bytes: 1)
        let chapterTitle = ShareBookPlan.chapterTitle(heading, book: "Book", chapterCount: 3)
        XCTAssertEqual(chapterTitle, "Part One  The Beginning")
        XCTAssertNoThrow(try ShareText.clean(chapterTitle, field: "title", max: ShareLimits.maxTitleLength))
    }

    func testAOneChapterBookIsNamedForTheBook() {
        let only = ShareBookPlan.Chapter(index: 0, title: "Chapter 1", durationSeconds: 60, bytes: 1)
        XCTAssertEqual(ShareBookPlan.chapterTitle(only, book: "An Essay", chapterCount: 1), "An Essay")
        let untitled = ShareBookPlan.Chapter(index: 3, title: " ", durationSeconds: 60, bytes: 1)
        XCTAssertEqual(ShareBookPlan.chapterTitle(untitled, book: "An Essay", chapterCount: 9), "An Essay, chapter 4")
    }

    func testCreditsAreTheAuthorAndTheBook() {
        let credits = ShareBookPlan.credits(book: "Middlemarch", author: "George Eliot")
        XCTAssertEqual(credits.artist, "George Eliot")
        XCTAssertEqual(credits.album, "Middlemarch")
        XCTAssertEqual(ShareBookPlan.credits(book: "B", author: nil).artist, "")
    }

    func testRefusalsReadAsSentences() {
        XCTAssertEqual(ShareBookPlan.Refusal.tooLong(seconds: 2700, maxSeconds: 1200).message,
                       "These chapters last 45 minutes; one link holds up to 20 minutes.")
        XCTAssertEqual(ShareBookPlan.Refusal.tooManyChapters(max: 12).message, "One link holds up to 12 chapters.")
    }

    /// A planned selection is accepted by the mixtape the kit actually builds.
    func testAPlannedMixtapeIsOneTheKitBuilds() throws {
        let picked = chapters([120, 180, 90], bytesPerSecond: 10)
        guard case .success(.mixtape) = ShareBookPlan.check(picked) else { return XCTFail("did not plan a mixtape") }
        let credits = ShareBookPlan.credits(book: "Book", author: "Author")
        let inputs = picked.map { chapter in
            PreparedMixtape.Input(audio: Data(repeating: 1, count: chapter.bytes), metadata: ShareMetadata(
                title: ShareBookPlan.chapterTitle(chapter, book: "Book", chapterCount: 3), artist: credits.artist,
                album: credits.album, durationSeconds: chapter.wireSeconds))
        }
        let prepared = try PreparedMixtape.make(
            tracks: inputs, title: ShareBookPlan.title(book: "Book", selected: picked, chapterCount: 3), preview: nil,
            expiresInSeconds: 604_800, playCap: 100, client: .init(platform: "macos", appVersion: "test"))
        XCTAssertEqual(prepared.manifest.tracks.map(\.metadata.title), ["Chapter 1", "Chapter 2", "Chapter 3"])
        XCTAssertEqual(prepared.manifest.title, "Book")
        XCTAssertEqual(prepared.request.totalDurationSeconds, 390)
    }
}
