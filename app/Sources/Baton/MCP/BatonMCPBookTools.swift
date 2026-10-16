import BatonDocuments
import BatonPlaybackKit
import Foundation

/// `document_context` (M8.5, "Ask the book"): the passages of a book the listener has already
/// heard, never anything past their position, so an agent can answer "who is Kuno again?"
/// without giving the story away. The lookup and the spoiler boundary are `BookContext` in
/// BatonDocuments; this is the Mac's wiring: which book, where the listener is, and the JSON.
///
/// Listed beside `import_document`, only while `baton.documents.enabled` is on.
@MainActor
enum BatonMCPBookTools {
    static let name = "document_context"
    /// The most an agent may ask for in one call, in characters.
    static let maximumBudget = 20_000

    /// What the player says about the chapter playing now, for the position.
    struct Playing: Equatable {
        var songID: String
        var time: Double
        var duration: Double
    }

    static func definition() -> [String: Any] {
        [
            "name": name,
            "description": BookContext.toolDescription + """
             Defaults to the book playing now, else the book last played; pass `book` (its title \
            or document id) for another. Pass `question` so the most relevant passages are chosen; \
            without one, the most recent passages come back. Pass `budget` to bound the text \
            returned (characters, default \(BookContext.defaultBudget), at most \(maximumBudget)).
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "book": ["type": "string", "description": "The book's title (or part of it) or its document id. Omit for the book playing, else the last played."],
                    "question": ["type": "string", "description": "What is being asked, so the passages that answer it are chosen."],
                    "budget": ["type": "integer", "description": "Characters of passages to return. Default \(BookContext.defaultBudget), at most \(maximumBudget)."],
                ],
                "required": [] as [String],
            ],
        ]
    }

    static func run(_ args: [String: Any], library: DocumentLibrary?, clippings: ClippingStore,
                    playing: Playing?) throws -> String {
        let books = BookShelf.entries(items: clippings.items, jobs: library?.jobs ?? [], ledger: clippings.ledger,
                                      changes: library?.voiceChanges.all ?? [])
            .compactMap { if case let .book(book) = $0 { book } else { nil } }
        guard !books.isEmpty else {
            throw BatonMCPToolError(message: "There are no books in Clippings.")
        }

        let playingItem = playing.flatMap { clippings.item(forSongID: $0.songID) }
        let book = try resolveBook(args, books: books, playingDocumentID: playingItem?.clipping.documentID, ledger: clippings.ledger)
        guard let prepared = BookText.preparedBook(for: book, library: library) else {
            throw BatonMCPToolError(message: "\"\(book.title)\" has no text on this Mac yet.")
        }

        var nowPlaying: (chapterIndex: Int, time: Double, duration: Double)?
        if let playing, let item = playingItem, item.clipping.documentID == book.documentID,
           let chapter = item.clipping.chapterIndex {
            nowPlaying = (chapter, playing.time, playing.duration)
        }
        let position = BookText.position(in: prepared, book: book, playing: nowPlaying)

        let requested = (args["budget"] as? Int) ?? (args["budget"] as? NSNumber)?.intValue ?? (args["budget"] as? String).flatMap(Int.init)
        let budget = min(maximumBudget, max(200, requested ?? BookContext.defaultBudget))
        let question = (args["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let heard = HeardText(prepared, upTo: position)
        let result: BookContext.Result
        if question.isEmpty {
            result = BookContext.Result(passages: heard.tail(budget), position: BookContext.describe(position, in: prepared))
        } else {
            result = BookContext.lookUp(question, in: prepared, at: position, budget: budget)
        }

        var out: [String: Any] = [
            "document_id": book.documentID,
            "title": book.title,
            "author": book.author ?? "",
            "position": result.position,
            "heard_characters": heard.characterCount,
            "passage_count": result.passages.count,
            "passages": result.passages.map { passage in
                ["chapter": passage.chapter + 1, "chapter_title": passage.chapterTitle, "text": passage.text] as [String: Any]
            },
        ]
        out["note"] = result.passages.isEmpty
            ? "The listener has not heard any of the book yet, so there is nothing to answer from."
            : "Only text up to the listener's position is included. Answer from these passages alone; if they do not hold the answer, say the book has not said yet."
        return BatonMCPToolCatalog.jsonText(out)
    }

    /// `book` names one (its id, or part of its title); otherwise the book playing, else the one
    /// whose position was noted most recently, else the newest.
    static func resolveBook(_ args: [String: Any], books: [BookShelf.Book], playingDocumentID: String?,
                            ledger: ClippingLedger) throws -> BookShelf.Book {
        let wanted = (args["book"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !wanted.isEmpty {
            if let byID = books.first(where: { $0.documentID == wanted }) { return byID }
            let query = wanted.lowercased()
            if let byTitle = books.first(where: { $0.title.lowercased() == query })
                ?? books.first(where: { $0.title.lowercased().contains(query) }) {
                return byTitle
            }
            throw BatonMCPToolError(message: "No book in Clippings matches \"\(wanted)\". Books: \(books.map(\.title).joined(separator: "; ")).")
        }
        if let playingDocumentID, let playing = books.first(where: { $0.documentID == playingDocumentID }) {
            return playing
        }
        let lastPlayed = books.compactMap { book -> (BookShelf.Book, Date)? in
            guard let at = ledger.document(book.documentID)?.positionAt else { return nil }
            return (book, at)
        }.max { $0.1 < $1.1 }?.0
        return lastPlayed ?? books.sorted { $0.createdAt > $1.createdAt }[0]
    }
}
