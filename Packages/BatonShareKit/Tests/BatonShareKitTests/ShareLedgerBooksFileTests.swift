@testable import BatonShareKit
import Foundation
import XCTest

/// The ledger decoder of the released apps, copied from `origin/main` (ShareLedger.swift and
/// ShareInvitation.swift as released): its `Kind` knows only songs and mixtapes, so one record it
/// cannot read would cost the person their whole Shared Links list. The ledger file must stay
/// exactly this readable after a new app has saved book links.
private struct ReleasedLedger: Decodable {
    enum Kind: String, Codable { case song, mixtape }
    struct Record: Decodable {
        var id: String
        var link: String
        var songID: String
        var title: String
        var artist: String
        var isPrivate: Bool
        var createdAt: Date
        var expiresAt: Date
        var summary: ShareSummary?
        var kind: Kind?
        var songIDs: [String]?
        var mixtapeSummary: MixtapeSummary?
    }
    var records: [Record]
    var pendingFailures: [ShareFailureReport]
}

final class ShareLedgerBooksFileTests: XCTestCase {
    private var root: URL!
    private var url: URL { root.appendingPathComponent("SongShares.json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-books-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func summary(_ id: String) -> ShareSummary {
        ShareSummary(id: id, status: .ready, createdAt: ShareDate.string(start), expiresAt: ShareDate.string(start + 604_800),
                     playCap: 10, preview: nil, stats: ShareStats(), reactions: [])
    }

    private func record(_ id: String, _ kind: ShareInvitation.Kind?, minute: Double) -> ShareLedger.Record {
        let letter = kind == .book ? "b" : kind == .mixtape ? "m" : "s"
        return ShareLedger.Record(
            id: id, link: "https://batonmusic.app/\(letter)/\(id)#key", songID: kind == nil ? "song-\(id)" : "",
            title: "Title \(id)", artist: "Artist", isPrivate: kind == .book, createdAt: start + minute * 60,
            expiresAt: start + 604_800, summary: summary(id), kind: kind,
            songIDs: kind == .mixtape ? ["a", "b"] : nil,
            mixtapeSummary: kind == .mixtape ? MixtapeSummary(share: summary(id), trackCount: 2) : nil,
            bookSummary: kind == .book ? BookSummary(share: summary(id), chapterCount: 30, hasText: true) : nil)
    }

    /// Oldest first, as a person would have made them; the ledger keeps them newest first.
    private func ledger() -> ShareLedger {
        var ledger = ShareLedger()
        ledger.add(record("old-song", nil, minute: 0))
        ledger.add(record("first-book", .book, minute: 1))
        ledger.add(record("a-mixtape", .mixtape, minute: 2))
        ledger.add(record("a-song", .song, minute: 3))
        ledger.add(record("new-book", .book, minute: 4))
        ledger.noteFailure("network")
        return ledger
    }

    func testTheReleasedDecoderReadsEverySongAndMixtapeAfterBooksAreSaved() throws {
        let ledger = ledger()
        for write in ["ShareLedger.save", "ShareUploadStore.saveLedger"] {
            if write == "ShareLedger.save" { try ledger.save(to: url) } else {
                try ShareUploadStore.saveLedger(ledger, to: url)
                try ledger.saveBooks(beside: url)
            }
            let data = try Data(contentsOf: url)
            let released = try JSONDecoder().decode(ReleasedLedger.self, from: data)
            XCTAssertEqual(released.records.map(\.id), ["a-song", "a-mixtape", "old-song"], write)
            XCTAssertEqual(released.records.map(\.kind), [.song, .mixtape, nil], write)
            XCTAssertEqual(released.records.map(\.link), ["https://batonmusic.app/s/a-song#key", "https://batonmusic.app/m/a-mixtape#key",
                                                          "https://batonmusic.app/s/old-song#key"])
            XCTAssertEqual(released.records[1].mixtapeSummary?.trackCount, 2)
            XCTAssertEqual(released.records[0].summary, summary("a-song"))
            XCTAssertEqual(released.pendingFailures, [ShareFailureReport(reason: "network")])
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("\"book\"") || text.contains("bookSummary") || text.contains("/b/"), write)
        }
    }

    func testBooksRoundTripThroughTheirOwnFileInTheirPlace() throws {
        let ledger = ledger()
        try ledger.save(to: url)
        let books = ShareLedger.booksURL(beside: url)
        XCTAssertEqual(books.lastPathComponent, "SongShares.books.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: books.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "the books file holds link keys")
        let loaded = ShareLedger.load(from: url)
        XCTAssertEqual(loaded, ledger, "the same records in the same order, failures included")
        XCTAssertEqual(loaded.records.map(\.identity),
                       ["book:new-book", "song:a-song", "mixtape:a-mixtape", "book:first-book", "song:old-song"])
        XCTAssertEqual(loaded.records.first?.bookSummary?.chapterCount, 30)
    }

    func testAReleasedAppRewritingTheLedgerLeavesTheBooksAlone() throws {
        try ledger().save(to: url)
        // What a released app writes back: songs and mixtapes only, and it never opens the books file.
        var released = ShareLedger()
        released.add(record("old-song", nil, minute: 0))
        released.add(record("from-old-app", .song, minute: 5))
        try ShareUploadStore.saveLedger(released, to: url)
        let loaded = ShareLedger.load(from: url)
        XCTAssertEqual(loaded.records.map(\.identity), ["song:from-old-app", "book:new-book", "book:first-book", "song:old-song"])
    }

    func testABookRecordFoundInTheLedgerFileMovesToTheBooksFile() throws {
        // A ledger file that somehow holds a book record (an unreleased build): read, kept, moved.
        let legacy = """
        {"pendingFailures":[],"records":[{"artist":"A","createdAt":800000600,"expiresAt":800604800,"id":"legacy","isPrivate":true,\
        "kind":"book","link":"https://batonmusic.app/b/legacy#key","songID":"","title":"Legacy"},\
        {"artist":"A","createdAt":800000000,"expiresAt":800604800,"id":"s1","isPrivate":false,"kind":"song",\
        "link":"https://batonmusic.app/s/s1#key","songID":"x","title":"S"}]}
        """
        try Data(legacy.utf8).write(to: url)
        var loaded = ShareLedger.load(from: url)
        XCTAssertEqual(loaded.records.map(\.identity), ["book:legacy", "song:s1"])
        loaded.add(record("new-book", .book, minute: 30))
        try loaded.save(to: url)
        XCTAssertEqual(try JSONDecoder().decode(ReleasedLedger.self, from: Data(contentsOf: url)).records.map(\.id), ["s1"])
        XCTAssertEqual(ShareLedger.load(from: url).records.map(\.identity), ["book:new-book", "book:legacy", "song:s1"])
    }

    func testALedgerWithoutBooksWritesNoBooksFile() throws {
        var ledger = ShareLedger()
        ledger.add(record("a-song", .song, minute: 0))
        try ledger.save(to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ShareLedger.booksURL(beside: url).path))
        XCTAssertEqual(ShareLedger.load(from: url), ledger)
    }
}
