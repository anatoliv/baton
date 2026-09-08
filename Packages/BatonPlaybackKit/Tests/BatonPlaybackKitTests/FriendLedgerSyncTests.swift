import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// The friend's ledger is actually wired into `PreferenceSync`.
///
/// Separate from `FriendLedgerTests`, which proves the merge rule, and from `FriendSyncTests`,
/// which proves the stores publish and adopt. This proves the join: a perfect merge that no
/// sync ever calls is the "guard nobody invokes" shape this repo has now hit several times —
/// `test-signing-patch` sat unrun, `test-release-guard` sat unrun, and both read as coverage.
@MainActor
final class FriendLedgerSyncTests: XCTestCase {

    func testTheLedgerIsCarriedBySync() {
        XCTAssertTrue(PreferenceSync.syncedKeys.contains(FriendLedger.storageKey),
                      "the ledger has to be in syncedKeys or it never leaves the device")
    }

    /// And specifically as a *merged* key. In `syncedKeys` alone it would be last-write-wins
    /// over the whole document, which is exactly the defect this card exists to fix — one
    /// device's memories silently replacing the other's.
    func testTheLedgerMergesRatherThanOverwrites() {
        XCTAssertTrue(PreferenceSync.mergedKeys.contains(FriendLedger.storageKey))
    }

    /// The dispatch in `mergedValue` actually reaches `FriendLedger.merged`. Without this the
    /// key would fall through to the generic `[String]` branch, which cannot decode a ledger
    /// and would quietly return an empty merge — deleting both devices' memories.
    func testMergedValueMergesPerEntryRatherThanFallingThrough() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        func ledger(_ text: String, at when: TimeInterval) -> Data {
            FriendLedger(memories: [
                .init(key: FriendLedger.key(for: text), text: text, kind: "preference",
                      quote: "q", created: t.addingTimeInterval(when), statedAt: t.addingTimeInterval(when))
            ]).encoded()!
        }

        let merged = PreferenceSync.mergedValue(
            key: FriendLedger.storageKey,
            local: ledger("no live albums", at: 10),
            remote: ledger("skip the intros", at: 20))

        let decoded = try XCTUnwrap(FriendLedger.decode(merged as? Data))
        XCTAssertEqual(Set(decoded.memories.map(\.text)), ["no live albums", "skip the intros"],
                       "both devices' memories must survive the merge the sync actually performs")
    }

    /// An empty result must be nil, not an empty document: `mergedValue` returning a value
    /// makes the sync push it, and pushing an empty ledger over a populated one would wipe
    /// the other device.
    func testAnEmptyMergeReturnsNilSoNothingIsPushed() {
        XCTAssertNil(PreferenceSync.mergedValue(key: FriendLedger.storageKey, local: nil, remote: nil))
    }

    /// It rides under `baton.`, so `SettingsTransfer` carries it too — a phone set up from a
    /// Mac starts sync already agreeing rather than re-deriving everything on first contact.
    func testTheLedgerKeyIsAlsoCarriedByTheSetupTransfer() {
        XCTAssertTrue(SettingsTransfer.isExportablePreference(FriendLedger.storageKey))
    }
}
