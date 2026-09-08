import XCTest
@testable import BatonSubsonicModels

/// Two devices that each learned something must both keep it.
///
/// That is the assertion whole-document last-write-wins fails, and it fails it *silently* —
/// the friend simply knows less on one device than it did, with nothing reporting an error.
/// So it is the first test here, and the one the mutation check targets.
final class FriendLedgerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func memory(_ text: String, removed: Bool = false, at when: TimeInterval) -> FriendLedger.Memory {
        FriendLedger.Memory(
            key: FriendLedger.key(for: text), text: text, kind: "preference",
            quote: "they said \(text)", created: at(when),
            removed: removed, removedAt: removed ? at(when) : nil, statedAt: at(when))
    }

    private func correction(_ request: String, note: String? = nil,
                            removed: Bool = false, at when: TimeInterval) -> FriendLedger.Correction {
        FriendLedger.Correction(
            key: FriendLedger.key(for: request), request: request, note: note,
            fault: "wrongThing", resolution: "played the live version", date: at(when),
            removed: removed, removedAt: removed ? at(when) : nil, statedAt: at(when))
    }

    // MARK: - The assertion this whole card exists for

    func testTwoDevicesThatEachLearnedSomethingBothKeepIt() {
        let phone = FriendLedger(memories: [memory("no live albums", at: 10)])
        let mac = FriendLedger(memories: [memory("skip the intros", at: 20)])

        let merged = FriendLedger.merged(phone, mac, now: at(30))

        XCTAssertEqual(Set(merged.memories.map(\.text)), ["no live albums", "skip the intros"],
                       "last-write-wins over the whole document would keep only one of these")
    }

    func testTwoDevicesThatEachRecordedACorrectionBothKeepIt() {
        let phone = FriendLedger(corrections: [correction("play something upbeat", at: 10)])
        let mac = FriendLedger(corrections: [correction("play the new one", at: 20)])

        let merged = FriendLedger.merged(phone, mac, now: at(30))

        XCTAssertEqual(merged.corrections.count, 2)
    }

    // MARK: - Identity

    /// The numeric memory id is minted `max(id) + 1` per device, so both ends independently
    /// produce 1, 2, 3 for unrelated memories. Matching on text is not a shortcut — it is the
    /// only key the two devices actually share, and the stores already dedupe on it.
    func testTheSameMemorySaidOnBothDevicesIsOneRecord() {
        let phone = FriendLedger(memories: [memory("No Live Albums", at: 10)])
        let mac = FriendLedger(memories: [memory("no live albums", at: 20)])

        let merged = FriendLedger.merged(phone, mac, now: at(30))

        XCTAssertEqual(merged.memories.count, 1, "differing case must not fork a memory")
        XCTAssertEqual(merged.memories.first?.statedAt, at(20),
                       "and the newer statement is the one kept")
    }

    /// The key is tested directly rather than through the merge, because it is the part that
    /// decides identity and the merge would hide a wrong answer behind a right-looking count.
    func testTheMatchingKeyIgnoresCaseAndCollapsesWhitespace() {
        let canonical = FriendLedger.key(for: "no live albums")
        XCTAssertEqual(FriendLedger.key(for: "No Live Albums"), canonical)
        XCTAssertEqual(FriendLedger.key(for: "  no   live  albums  "), canonical,
                       "dictated and typed versions of one sentence differ by spacing far more "
                       + "often than by meaning")
        XCTAssertNotEqual(FriendLedger.key(for: "no live tracks"), canonical)
    }

    func testDifferentTextsAreDifferentMemories() {
        let merged = FriendLedger.merged(
            FriendLedger(memories: [memory("no live albums", at: 10)]),
            FriendLedger(memories: [memory("no live tracks", at: 10)]), now: at(20))
        XCTAssertEqual(merged.memories.count, 2)
    }

    // MARK: - Deletion has to cross, and has to be revivable

    /// Approving an answer deletes the correction locally. Without a tombstone the other
    /// device pushes it straight back, and the friend goes on being told it was wrong about
    /// something it has since got right.
    func testARetirementOnOneDeviceSurvivesContactWithADeviceThatStillHasIt() {
        let mac = FriendLedger(corrections: [correction("play something upbeat", removed: true, at: 20)])
        let phone = FriendLedger(corrections: [correction("play something upbeat", at: 10)])

        let merged = FriendLedger.merged(mac, phone, now: at(30))

        XCTAssertEqual(merged.corrections.count, 1)
        XCTAssertTrue(merged.corrections[0].removed, "the newer retirement wins")
    }

    /// And the reverse: being told the same thing again after forgetting it must stick, or
    /// the tombstone becomes permanent and the friend can never re-learn.
    func testSayingItAgainAfterForgettingItBringsItBack() {
        let old = FriendLedger(memories: [memory("no live albums", removed: true, at: 10)])
        let new = FriendLedger(memories: [memory("no live albums", at: 20)])

        let merged = FriendLedger.merged(old, new, now: at(30))

        XCTAssertEqual(merged.memories.count, 1)
        XCTAssertFalse(merged.memories[0].removed)
    }

    /// A dead heat goes to the removal — two devices with skewed clocks can land on the same
    /// instant, and losing something you deleted is silent where keeping it is visible.
    func testAnExactTieGoesToTheRemoval() {
        let kept = FriendLedger(memories: [memory("no live albums", at: 10)])
        let gone = FriendLedger(memories: [memory("no live albums", removed: true, at: 10)])

        XCTAssertTrue(FriendLedger.merged(kept, gone, now: at(20)).memories[0].removed)
        XCTAssertTrue(FriendLedger.merged(gone, kept, now: at(20)).memories[0].removed,
                      "and it must not depend on argument order")
    }

    // MARK: - Housekeeping

    func testAnExpiredTombstoneStopsSuppressing() {
        let ancient = FriendLedger(memories: [memory("no live albums", removed: true, at: 0)])
        let merged = FriendLedger.merged(ancient, FriendLedger(),
                                         now: t0.addingTimeInterval(FriendLedger.tombstoneRetention + 60))
        XCTAssertTrue(merged.memories.isEmpty, "a tombstone past retention is dropped, not kept forever")
    }

    func testMergingIsOrderIndependentAndIdempotent() {
        let a = FriendLedger(memories: [memory("one", at: 10), memory("two", removed: true, at: 40)],
                             corrections: [correction("q", at: 15)])
        let b = FriendLedger(memories: [memory("two", at: 20), memory("three", at: 30)],
                             corrections: [correction("q", note: "newer", at: 25)])

        let ab = FriendLedger.merged(a, b, now: at(50))
        let ba = FriendLedger.merged(b, a, now: at(50))
        XCTAssertEqual(ab, ba, "sync order must not decide the answer")
        XCTAssertEqual(FriendLedger.merged(ab, ab, now: at(50)), ab,
                       "re-merging must not change it, or two devices ping-pong pushes forever")
    }

    func testTheCapDropsTombstonesBeforeLiveRecords() {
        var ledger = FriendLedger()
        for i in 0 ..< FriendLedger.maximumMemories {
            ledger.memories.append(memory("live \(i)", at: TimeInterval(100 + i)))
        }
        ledger.memories.append(memory("dead", removed: true, at: 999))

        let merged = FriendLedger.merged(ledger, FriendLedger(), now: at(2000))

        XCTAssertEqual(merged.memories.count, FriendLedger.maximumMemories)
        XCTAssertFalse(merged.memories.contains { $0.removed },
                       "the tombstone goes first — a live record still says something the friend uses")
    }

    func testAnEmptyMergeIsEmptyRatherThanNil() {
        XCTAssertEqual(FriendLedger.merged(FriendLedger(), FriendLedger(), now: t0), FriendLedger())
    }

    func testItSurvivesAnEncodeDecodeRoundTrip() throws {
        let ledger = FriendLedger(memories: [memory("no live albums", at: 10)],
                                  corrections: [correction("play upbeat", note: "too slow", at: 20)])
        let data = try XCTUnwrap(ledger.encoded())
        XCTAssertEqual(FriendLedger.decode(data), ledger)
    }
}
