@testable import BatonShareKit
import Foundation
import XCTest

/// The books-file decoder of the released apps that know books (0.20.12 and 0.20.13, copied from
/// `v0.20.13`): `Kind` knows song, mixtape and book, and `BookSummary` has no `kind`. An album or
/// playlist record must decode there exactly as a book does, or one record would cost that app
/// every book link on the device.
private struct ReleasedBooksFile: Decodable {
    enum Kind: String, Codable { case song, mixtape, book }
    struct BookSummary: Decodable {
        var share: ShareSummary
        var chapterCount: Int
        var hasText: Bool
        var reviewDeadline: String?
        var pausedLifetimeSeconds: Int64?
    }
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
        var bookSummary: BookSummary?
    }
    var version: Int
    var records: [Record]
}

/// What a released app writes back to the books file: its own Record and BookSummary shapes.
private struct ReleasedWrite: Encodable {
    struct BookSummary: Encodable { var share: ShareSummary; var chapterCount: Int; var hasText: Bool }
    struct Record: Encodable {
        var id: String, link: String, songID: String, title: String, artist: String, isPrivate: Bool
        var createdAt: Date, expiresAt: Date, summary: ShareSummary?, kind: String?, bookSummary: BookSummary?
    }
    var version = 1
    var records: [Record]
}

final class ShareLedgerCollectionTests: XCTestCase {
    private var root: URL!
    private var url: URL { root.appendingPathComponent("SongShares.json") }
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-collections-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func summary(_ id: String) -> ShareSummary {
        ShareSummary(id: id, status: .ready, createdAt: ShareDate.string(start), expiresAt: ShareDate.string(start + 604_800),
                     playCap: 10, preview: nil, stats: ShareStats(), reactions: [])
    }

    private func record(_ id: String, collection: ShareCollectionKind?, minute: Double) -> ShareLedger.Record {
        ShareLedger.Record(id: id, link: "https://batonmusic.app/b/\(id)#key", songID: "", title: "Title \(id)", artist: "Artist",
                           isPrivate: false, createdAt: start + minute * 60, expiresAt: start + 604_800, summary: summary(id),
                           kind: .book, bookSummary: BookSummary(share: summary(id), chapterCount: 14, hasText: false, kind: collection),
                           collection: collection)
    }

    private func ledger() -> ShareLedger {
        var ledger = ShareLedger()
        ledger.add(ShareLedger.Record(id: "s1", link: "https://batonmusic.app/s/s1#key", songID: "x", title: "S", artist: "A",
                                      isPrivate: false, createdAt: start, expiresAt: start + 604_800))
        ledger.add(record("a-book", collection: nil, minute: 1))
        ledger.add(record("an-album", collection: .album, minute: 2))
        ledger.add(record("a-playlist", collection: .playlist, minute: 3))
        return ledger
    }

    func testCollectionsKeepTheirKindThroughSaveAndLoad() throws {
        try ledger().save(to: url)
        let loaded = ShareLedger.load(from: url)
        XCTAssertEqual(loaded, ledger())
        XCTAssertEqual(loaded.records.map(\.collectionKind), [.playlist, .album, nil, nil])
        XCTAssertEqual(loaded.records.map(\.containerKind), [.book, .book, .book, .song], "a collection is a /b/ link")
    }

    func testTheReleasedBookAwareDecoderReadsEveryRecordOfTheBooksFile() throws {
        try ledger().save(to: url)
        let data = try Data(contentsOf: ShareLedger.booksURL(beside: url))
        let released = try JSONDecoder().decode(ReleasedBooksFile.self, from: data)
        XCTAssertEqual(released.records.map(\.id), ["a-playlist", "an-album", "a-book"])
        XCTAssertEqual(released.records.map(\.kind), [.book, .book, .book])
        XCTAssertEqual(released.records.map { $0.bookSummary?.chapterCount }, [14, 14, 14])
        // The ledger file itself, which every released app reads, still holds no `/b/` record.
        let main = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(main.contains("/b/") || main.contains("album") || main.contains("playlist"))
    }

    func testAReleasedAppRewritingTheBooksFileLosesTheKindOnlyUntilTheNextRefresh() throws {
        try ledger().save(to: url)
        let released = try JSONDecoder().decode(ReleasedBooksFile.self, from: Data(contentsOf: ShareLedger.booksURL(beside: url)))
        let rewritten = ReleasedWrite(records: released.records.map {
            .init(id: $0.id, link: $0.link, songID: $0.songID, title: $0.title, artist: $0.artist, isPrivate: $0.isPrivate,
                  createdAt: $0.createdAt, expiresAt: $0.expiresAt, summary: $0.summary, kind: $0.kind?.rawValue,
                  bookSummary: $0.bookSummary.map { .init(share: $0.share, chapterCount: $0.chapterCount, hasText: $0.hasText) })
        })
        let encoder = JSONEncoder()
        try encoder.encode(rewritten).write(to: ShareLedger.booksURL(beside: url))
        var loaded = ShareLedger.load(from: url)
        XCTAssertEqual(loaded.records.map(\.id), ["a-playlist", "an-album", "a-book", "s1"], "every record still reads")
        XCTAssertEqual(loaded.records.map(\.collectionKind), [nil, nil, nil, nil], "shown as book links meanwhile")
        loaded.mergeBooks([BookSummary(share: summary("an-album"), chapterCount: 14, hasText: false, kind: .album),
                           BookSummary(share: summary("a-playlist"), chapterCount: 14, hasText: false, kind: .playlist),
                           BookSummary(share: summary("a-book"), chapterCount: 14, hasText: false)])
        XCTAssertEqual(loaded.records.map(\.collectionKind), [.playlist, .album, nil, nil], "the service's list brings it back")
    }

    func testMergingKeepsTheRecordedKindWhenTheServiceSaysNothing() {
        var ledger = ledger()
        ledger.mergeBooks([BookSummary(share: summary("an-album"), chapterCount: 14, hasText: false)])
        XCTAssertEqual(ledger.records.first { $0.id == "an-album" }?.collectionKind, .album)
        XCTAssertNil(ShareLedger.Record(id: "s", link: "", songID: "", title: "", artist: "", isPrivate: false, createdAt: start,
                                        expiresAt: start, kind: .song, collection: .album).collectionKind,
                     "only a /b/ record is a collection")
    }
}
