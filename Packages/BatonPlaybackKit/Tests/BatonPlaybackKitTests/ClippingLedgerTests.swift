import Foundation
import XCTest
@testable import BatonPlaybackKit

/// The shared ledger that makes a rename or a delete travel between devices.
///
/// These are the tests worth having because the failures they guard are **silent**. A merge that
/// drops a rename shows nothing; a merge that resurrects a deleted clipping looks like the
/// feature working. Neither is visible on a screen the way this week's other clipping defects
/// were, so the assertions have to carry the whole weight.
final class ClippingLedgerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func t(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    // MARK: - Per-field merging, which is the whole design

    /// The case a single timestamp gets wrong. Deleted on the phone, renamed on the Mac a moment
    /// later: with one clock per record the rename is "newer" and wins the *whole* record, and
    /// the clipping comes back from the dead wearing its new name.
    func testARenameDoesNotResurrectSomethingDeletedEarlier() {
        var phone = ClippingLedger()
        phone.remove("abc", at: t(120))

        var mac = ClippingLedger()
        mac.setTitle("A better name", for: "abc", at: t(60))   // stated BEFORE the deletion

        let merged = ClippingLedger.merged(phone, mac, now: t(200))
        let record = merged.record(for: "abc")
        XCTAssertEqual(record?.removed, true, "an older rename resurrected a deleted clipping")
        XCTAssertEqual(record?.title, "A better name", "the title itself should still be carried")
    }

    /// And the converse: a rename made *after* a deletion is a statement that the thing exists,
    /// so it revives it. Anything else would leave a live title on a tombstoned record and the
    /// two devices disagreeing about whether the clipping is there at all.
    func testARenameAfterADeletionRevivesIt() {
        var ledger = ClippingLedger()
        ledger.remove("abc", at: t(60))
        ledger.setTitle("Back again", for: "abc", at: t(120))

        XCTAssertEqual(ledger.record(for: "abc")?.removed, false)
        XCTAssertEqual(ledger.record(for: "abc")?.title, "Back again")
    }

    /// Two devices each changing a *different* field must both be right afterwards. This is the
    /// case a whole-record last-write-wins loses, and the reason the podcast ledger's shape was
    /// not simply copied.
    func testTwoDevicesChangingDifferentFieldsBothSurvive() {
        var mac = ClippingLedger()
        mac.setTitle("Renamed on the Mac", for: "abc", at: t(100))

        var phone = ClippingLedger()
        phone.setSource("Ghostty", for: "abc", at: t(50))

        let merged = ClippingLedger.merged(mac, phone, now: t(200))
        XCTAssertEqual(merged.record(for: "abc")?.title, "Renamed on the Mac")
        XCTAssertEqual(merged.record(for: "abc")?.source, "Ghostty",
                       "the other device's source edit was thrown away")
    }

    /// Renamed on both before either synced: the later statement wins, in either merge order.
    func testTheLaterRenameWinsRegardlessOfMergeOrder() {
        var mac = ClippingLedger(); mac.setTitle("Mac name", for: "abc", at: t(100))
        var phone = ClippingLedger(); phone.setTitle("Phone name", for: "abc", at: t(200))

        XCTAssertEqual(ClippingLedger.merged(mac, phone, now: t(300)).record(for: "abc")?.title,
                       "Phone name")
        XCTAssertEqual(ClippingLedger.merged(phone, mac, now: t(300)).record(for: "abc")?.title,
                       "Phone name", "merge is not order-independent")
    }

    /// A device that has never said anything about a clipping must not out-vote one that has.
    func testNeverStatedLosesToAnyStatement() {
        let silent = ClippingLedger(records: [.init(sha256: "abc")])
        var spoken = ClippingLedger(); spoken.setTitle("Named", for: "abc", at: t(10))

        XCTAssertEqual(ClippingLedger.merged(silent, spoken, now: t(20)).record(for: "abc")?.title,
                       "Named")
        XCTAssertEqual(ClippingLedger.merged(spoken, silent, now: t(20)).record(for: "abc")?.title,
                       "Named")
    }

    // MARK: - Deletion

    /// The point of the whole exercise: a deletion survives contact with a device that still had
    /// the clipping and does not know anything happened.
    func testADeletionSurvivesADeviceThatStillHasIt() {
        var phone = ClippingLedger()
        phone.remove("abc", at: t(100))

        var mac = ClippingLedger()          // never heard about it; still holds the file
        mac.setTitle("Still here", for: "abc", at: t(10))

        let merged = ClippingLedger.merged(phone, mac, now: t(200))
        XCTAssertEqual(merged.record(for: "abc")?.removed, true)
        XCTAssertTrue(merged.removedDigests.contains("abc"))
    }

    /// Keeping the same audio again after deleting it must work — the digest is identical, so
    /// without a later statement the next reconcile would delete it straight back.
    func testKeepingItAgainBeatsAnOlderTombstone() {
        var ledger = ClippingLedger()
        ledger.remove("abc", at: t(100))
        ledger.restore("abc", at: t(200))

        XCTAssertEqual(ledger.record(for: "abc")?.removed, false)
        XCTAssertFalse(ledger.removedDigests.contains("abc"))
    }

    /// Clocks on two devices can land on the same instant. Losing something you deleted is
    /// silent; keeping something you meant to delete is visible and can be repeated.
    func testAnExactTieGoesToTheRemoval() {
        var a = ClippingLedger(); a.remove("abc", at: t(100))
        var b = ClippingLedger(); b.restore("abc", at: t(100))

        XCTAssertEqual(ClippingLedger.merged(a, b, now: t(200)).record(for: "abc")?.removed, true)
        XCTAssertEqual(ClippingLedger.merged(b, a, now: t(200)).record(for: "abc")?.removed, true)
    }

    // MARK: - Retention

    /// A tombstone cannot be dropped as soon as it is applied: any device still holding the file
    /// and not yet synced would re-upload it and undo the deletion. Six months outlives the
    /// gateway's own fourteen-day blob retention many times over.
    func testTombstonesExpireButLiveRecordsDoNot() {
        var ledger = ClippingLedger()
        ledger.remove("old", at: t(0))
        ledger.setTitle("Ancient but alive", for: "live", at: t(0))

        let long = t(ClippingLedger.tombstoneRetention + 60)
        let merged = ClippingLedger.merged(ledger, .init(), now: long)

        XCTAssertNil(merged.record(for: "old"), "an expired tombstone was kept")
        XCTAssertNotNil(merged.record(for: "live"), "a live record was expired by age")
    }

    /// The cap must drop tombstones before live records: a live record may still describe a file
    /// a device is holding, while a lost tombstone merely stops suppressing something that is
    /// almost certainly gone from the gateway anyway.
    func testTheCapSheddsTombstonesFirst() {
        var ledger = ClippingLedger()
        for i in 0 ..< (ClippingLedger.maximumRecords) {
            ledger.setTitle("live \(i)", for: "live-\(i)", at: t(Double(i)))
        }
        for i in 0 ..< 50 {
            ledger.remove("dead-\(i)", at: t(Double(10_000 + i)))
        }

        let merged = ClippingLedger.merged(ledger, .init(), now: t(20_000))
        XCTAssertEqual(merged.records.count, ClippingLedger.maximumRecords)
        XCTAssertEqual(merged.records.filter(\.removed).count, 0,
                       "tombstones survived while live records were dropped")
    }

    // MARK: - Encoding

    func testItSurvivesAnEncodeDecodeRoundTrip() throws {
        var ledger = ClippingLedger()
        ledger.setTitle("A reading", for: "abc", at: t(10))
        ledger.setSource("Ghostty", for: "abc", at: t(10))
        ledger.remove("def", at: t(20))

        let decoded = try XCTUnwrap(ClippingLedger.decode(ledger.encoded()))
        XCTAssertEqual(decoded, ledger)
    }

}

/// The two assertions that touch `PreferenceSync`, which is main-actor isolated. Split out so the
/// pure merge tests above stay free of actor hopping they do not need.
@MainActor
final class ClippingLedgerSyncWiringTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func t(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    /// It rides in `PreferenceSync`, so it has to be listed as a merged key or it would be
    /// carried as an opaque blob and one device's whole ledger would replace the other's.
    func testItIsRegisteredAsAMergedKey() {
        XCTAssertTrue(PreferenceSync.mergedKeys.contains(ClippingLedger.storageKey))
        XCTAssertTrue(PreferenceSync.syncedKeys.contains(ClippingLedger.storageKey),
                      "a merged key that is not synced never travels at all")
    }

    /// And the merge PreferenceSync actually invokes must be the per-field one, not a fallback.
    func testPreferenceSyncMergesItPerField() throws {
        var mac = ClippingLedger(); mac.setTitle("Mac", for: "abc", at: t(100))
        var phone = ClippingLedger(); phone.setSource("Ghostty", for: "abc", at: t(50))

        let merged = PreferenceSync.mergedValue(key: ClippingLedger.storageKey,
                                                local: mac.encoded(), remote: phone.encoded())
        let decoded = try XCTUnwrap(ClippingLedger.decode(merged as? Data))
        XCTAssertEqual(decoded.record(for: "abc")?.title, "Mac")
        XCTAssertEqual(decoded.record(for: "abc")?.source, "Ghostty")
    }
}
