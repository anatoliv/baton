import BatonPlaybackKit
import Foundation
import XCTest
@testable import Baton

/// The Mac's Clippings filter goes through the shared search index (M8.9) with the
/// fields the list always searched: a clipping's title, its source and its words, but not the
/// book title on a chapter (that one is the iPhone's). Accents and case are now ignored.
@MainActor
final class ClippingsSearchWiringTests: XCTestCase {

    private var dir: URL!
    private var store: ClippingStore!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-mac-search-\(UUID().uuidString)")
        store = ClippingStore(directory: dir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func adopt(_ title: String, source: String? = nil, text: String,
                       book: String? = nil) throws -> ClippingStore.Item {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).m4a")
        try Data(repeating: 0x41, count: 64).write(to: url)
        let chapter = book.map {
            ClippingStore.BookChapter(documentID: "doc-\($0)", documentTitle: $0, author: nil,
                                      chapterIndex: 0, chapterTitle: title)
        }
        return try store.adopt(url, title: title, sourceName: source, durationSeconds: 1, text: text, chapter: chapter)
    }

    private func answer(_ search: ClippingSearch, _ query: String) async -> Set<String> {
        search.setQuery(query)
        await search.settle()
        return Set(search.filter(store.items).map(\.id))
    }

    func testTheMacSearchesTitleSourceAndWordsButNotTheBookTitle() async throws {
        let reading = try adopt("Google Chrome 09.15", source: "Google Chrome",
                                text: "The bit about notarization and the café.")
        let chapter = try adopt("Chapter 1", source: "Kokoro", text: "A small room, hexagonal in shape.",
                                book: "The Machine Stops")
        let search = ClippingSearch(fields: MusicModel.clippingSearchFields, debounce: .milliseconds(10))
        search.follow(store)

        let title = await answer(search, "09.15")
        XCTAssertEqual(title, [reading.id])
        let source = await answer(search, "kokoro")
        XCTAssertEqual(source, [chapter.id])
        let words = await answer(search, "HEXAGONAL")
        XCTAssertEqual(words, [chapter.id])
        let accent = await answer(search, "cafe")
        XCTAssertEqual(accent, [reading.id], "new in M8.9: accents are ignored")
        let bookTitle = await answer(search, "machine stops")
        XCTAssertEqual(bookTitle, [], "the Mac's list never searched a chapter's book title")
        XCTAssertTrue(search.matches(title: "The Machine Stops"), "the book's own row is matched by its title")
    }
}
