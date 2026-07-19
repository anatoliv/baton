import XCTest
@testable import Baton

/// Coverage for the collection (album/artist) download-badge decision — the full/partial/hidden
/// logic behind the standardized indicator.
@MainActor
final class DownloadStatusBadgeTests: XCTestCase {
    func testCollectionStatus() {
        // No downloads → hidden.
        XCTAssertEqual(DownloadStatusBadge.collectionStatus(cached: 0, total: 10), .hidden)
        XCTAssertEqual(DownloadStatusBadge.collectionStatus(cached: 0, total: nil), .hidden)
        // Some but not all → partial.
        XCTAssertEqual(DownloadStatusBadge.collectionStatus(cached: 3, total: 10), .partial)
        // All cached → complete.
        XCTAssertEqual(DownloadStatusBadge.collectionStatus(cached: 10, total: 10), .complete)
        // More cached than the reported total (stale count) still reads complete.
        XCTAssertEqual(DownloadStatusBadge.collectionStatus(cached: 11, total: 10), .complete)
        // Unknown total but has downloads → partial (can't claim "complete" without a total).
        XCTAssertEqual(DownloadStatusBadge.collectionStatus(cached: 5, total: nil), .partial)
        // total 0 is treated as unknown (no complete claim).
        XCTAssertEqual(DownloadStatusBadge.collectionStatus(cached: 2, total: 0), .partial)
    }
}
