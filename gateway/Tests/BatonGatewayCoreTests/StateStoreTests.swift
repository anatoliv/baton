import Foundation
import XCTest
@testable import BatonGatewayCore

/// The revision that orders writes to the shared preference document (S-F17).
///
/// The defect this closes is a lost update, and it is invisible from either device. `PUT
/// /v1/state` is a whole-file replace, so a device that read the document, merged its own
/// settings into it and pushed had no way to notice that the other device had written in the
/// meantime. The second push simply replaced the first, both devices reported a successful sync,
/// and the setting that vanished had no error attached to it anywhere.
final class StateStoreTests: XCTestCase {
    private var directory: URL!
    private var store: StateStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-statestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = StateStore(fileURL: directory.appendingPathComponent("baton-state.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A gateway nobody has synced to is the first device's normal case, not an error.
    func testAnUnwrittenStoreReadsAsAnEmptyDocumentAtRevisionZero() {
        let state = store.read()
        XCTAssertEqual(state.body, "{}")
        XCTAssertEqual(state.revision, 0)
    }

    func testEveryWriteMovesTheRevisionForward() {
        XCTAssertEqual(store.write(Data(#"{"a":1}"#.utf8), ifRevision: 0), .written(revision: 1))
        XCTAssertEqual(store.write(Data(#"{"a":2}"#.utf8), ifRevision: 1), .written(revision: 2))
        XCTAssertEqual(store.read().body, #"{"a":2}"#)
        XCTAssertEqual(store.read().revision, 2)
    }

    /// The finding itself: the second device pushes over a document that moved under it, and
    /// nothing anywhere says so. It must be refused, and refused in a way the client can tell
    /// apart from a token problem or a dead gateway, because the answer to this one is to read
    /// the document again rather than to give up.
    func testAWriteAgainstARevisionThatHasMovedIsRefused() {
        _ = store.write(Data(#"{"phone":1}"#.utf8), ifRevision: 0)

        // The Mac read revision 0 before the phone wrote, and is now pushing its merge.
        let outcome = store.write(Data(#"{"mac":1}"#.utf8), ifRevision: 0)

        XCTAssertEqual(outcome, .stale(current: 1))
        XCTAssertEqual(store.read().body, #"{"phone":1}"#,
                       "the stale push replaced a document it had never read")
    }

    /// And the same device, having re-read, gets through.
    func testRereadingAndPushingAgainSucceeds() {
        _ = store.write(Data(#"{"phone":1}"#.utf8), ifRevision: 0)
        XCTAssertEqual(store.write(Data(#"{"mac":1}"#.utf8), ifRevision: 0), .stale(current: 1))

        let current = store.read().revision
        XCTAssertEqual(store.write(Data(#"{"both":1}"#.utf8), ifRevision: current),
                       .written(revision: 2))
    }

    /// An older client sends no revision at all. Refusing it would break sync for every device
    /// that had not been updated yet, which is worse than the race the revision closes.
    func testAWriteThatNamesNoRevisionIsStillAccepted() {
        _ = store.write(Data(#"{"a":1}"#.utf8), ifRevision: nil)
        XCTAssertEqual(store.write(Data(#"{"a":2}"#.utf8), ifRevision: nil), .written(revision: 2),
                       "an unversioned write still moves the revision, so a versioned peer notices")
    }

    /// The revision lives beside the document, so a restart or a redeploy does not hand two
    /// devices a number that has gone backwards.
    func testTheRevisionSurvivesANewStoreOverTheSameFile() {
        _ = store.write(Data(#"{"a":1}"#.utf8), ifRevision: 0)
        let reopened = StateStore(fileURL: directory.appendingPathComponent("baton-state.json"))
        XCTAssertEqual(reopened.read().revision, 1)
    }

    /// Existing deployments have a document and no sidecar. They must keep working, starting the
    /// count from zero rather than refusing every write.
    func testADocumentWithNoRevisionFileStartsAtZero() throws {
        try Data(#"{"existing":true}"#.utf8)
            .write(to: directory.appendingPathComponent("baton-state.json"))
        XCTAssertEqual(store.read().revision, 0)
        XCTAssertEqual(store.write(Data("{}".utf8), ifRevision: 0), .written(revision: 1))
    }

    func testTheResponseHeadersCarryTheRevisionAndTheGatewaysClock() {
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        let headers = StateStore.responseHeaders(revision: 7, now: now)

        XCTAssertEqual(headers[StateStore.revisionHeader], "7")
        XCTAssertEqual(headers[StateStore.serverTimeHeader], "1757000000.000")
    }
}
