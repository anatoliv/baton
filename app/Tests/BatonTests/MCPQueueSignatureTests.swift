import XCTest
@testable import Baton

/// W-40 / MCP-06: the queue-change signature must be order-sensitive. The old signature sampled
/// only count/first/last, so a middle-of-queue reorder produced an identical value and agent UIs
/// went stale. `queueDigest` folds every id in order, so any reorder changes it.
@MainActor
final class MCPQueueSignatureTests: XCTestCase {
    func testIdenticalOrderHasIdenticalDigest() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(BatonMCPServer.queueDigest(ids: ids), BatonMCPServer.queueDigest(ids: ids))
    }

    /// The regression the fix targets: same count, same first and last, only the middle swapped.
    func testMiddleReorderChangesDigest() {
        let before = BatonMCPServer.queueDigest(ids: ["a", "b", "c", "d"])
        let after = BatonMCPServer.queueDigest(ids: ["a", "c", "b", "d"])
        XCTAssertNotEqual(before, after, "a middle-of-queue reorder must change the signature")
    }

    func testDifferentCountChangesDigest() {
        XCTAssertNotEqual(
            BatonMCPServer.queueDigest(ids: ["a", "b"]),
            BatonMCPServer.queueDigest(ids: ["a", "b", "c"])
        )
    }

    /// The separator byte means concatenation boundaries matter: ["ab","c"] ≠ ["a","bc"].
    func testBoundaryIsNotAmbiguous() {
        XCTAssertNotEqual(
            BatonMCPServer.queueDigest(ids: ["ab", "c"]),
            BatonMCPServer.queueDigest(ids: ["a", "bc"])
        )
    }

    func testEmptyQueueIsStable() {
        XCTAssertEqual(BatonMCPServer.queueDigest(ids: []), BatonMCPServer.queueDigest(ids: []))
    }
}
