import XCTest
@testable import Baton
@testable import BatonShareKit

/// A Shared Links row keeps describing what was shared after the link ends.
///
/// The row's "9 songs" is the share service's count of the audio it holds. Revoking a link, or
/// its expiry, deletes that audio, so the next summary says 0; the ledger took the summary
/// whole and the row read "Album · 0 songs". The link is over, but what it held has not changed.
@MainActor
final class SharedLinksRowTests: XCTestCase {
    func testARevokedAlbumKeepsItsSongCount() {
        var ledger = ShareLedger()
        ledger.add(album(count: 9, status: .ready))
        ledger.mergeBooks([BookSummary(share: summary(.revoked), chapterCount: 0, hasText: false, kind: .album)])

        let record = ledger.records[0]
        XCTAssertEqual(record.status, .revoked)
        XCTAssertEqual(SharedLinksView.bookLine(record, record.summary!), "Album · 9 songs · 0 of 10 listeners")
    }

    func testAnExpiredPlaylistKeepsItsSongCount() {
        var ledger = ShareLedger()
        ledger.add(album(count: 9, status: .ready, kind: .playlist))
        ledger.updateBook(BookSummary(share: summary(.expired), chapterCount: 0, hasText: false, kind: .playlist))

        let record = ledger.records[0]
        XCTAssertEqual(SharedLinksView.bookLine(record, record.summary!), "Playlist · 9 songs · 0 of 10 listeners")
    }

    /// A book link's chapters and read-along text are described the same way once it has ended.
    func testARevokedBookKeepsItsChaptersAndText() {
        var ledger = ShareLedger()
        ledger.add(album(count: 30, status: .ready, kind: nil, hasText: true))
        ledger.mergeBooks([BookSummary(share: summary(.revoked), chapterCount: 0, hasText: false)])

        let record = ledger.records[0]
        XCTAssertEqual(SharedLinksView.bookLine(record, record.summary!), "30 chapters · 0 of 10 listeners · Read-along text")
    }

    /// While the link is live the service's count is the truth, including a lower one.
    func testALiveLinkTakesTheServicesCount() {
        var ledger = ShareLedger()
        ledger.add(album(count: 9, status: .pending))
        ledger.mergeBooks([BookSummary(share: summary(.ready), chapterCount: 8, hasText: false, kind: .album)])

        let record = ledger.records[0]
        XCTAssertEqual(SharedLinksView.bookLine(record, record.summary!), "Album · 8 songs · 0 of 10 listeners")
    }

    // MARK: - Fixtures

    private func summary(_ status: ShareStatus) -> ShareSummary {
        ShareSummary(id: "an-album", status: status, createdAt: "2026-10-21T10:00:00Z",
                     expiresAt: "2026-10-28T10:00:00Z", playCap: 10, preview: nil, stats: ShareStats(), reactions: [])
    }

    private func album(count: Int, status: ShareStatus, kind: ShareCollectionKind? = .album,
                       hasText: Bool = false) -> ShareLedger.Record {
        ShareLedger.Record(id: "an-album", link: "https://batonmusic.app/b/an-album#key", songID: "",
                           title: "An Album", artist: "Someone", isPrivate: false,
                           createdAt: Date(timeIntervalSince1970: 1_792_576_800),
                           expiresAt: Date().addingTimeInterval(7 * 86_400), summary: summary(status), kind: .book,
                           bookSummary: BookSummary(share: summary(status), chapterCount: count, hasText: hasText, kind: kind),
                           collection: kind)
    }
}
