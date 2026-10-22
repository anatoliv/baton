import XCTest
@testable import BatonPlaybackKit

/// A merged key whose value this build cannot read was merged as empty:
/// an unreadable local value was replaced by the remote one, and an unreadable remote value was
/// written over with ours. Neither side is touched now.
@MainActor
final class PreferenceSyncUnreadableMergeTests: XCTestCase {
    private let garbage = Data("written by a newer build".utf8)

    func testAnUnreadableLocalLedgerIsNotReplaced() throws {
        var remote = ClippingLedger()
        remote.setTitle("Shared", for: String(repeating: "a", count: 64))
        XCTAssertNil(PreferenceSync.mergedValue(key: ClippingLedger.storageKey, local: garbage, remote: remote.encoded()),
                     "the unreadable local ledger was replaced")
    }

    func testAnUnreadableRemoteLedgerIsNotWrittenOver() throws {
        var local = ClippingLedger()
        local.setTitle("Mine", for: String(repeating: "b", count: 64))
        XCTAssertNil(PreferenceSync.mergedValue(key: ClippingLedger.storageKey, local: local.encoded(), remote: garbage),
                     "the unreadable remote ledger would be written over")
    }

    func testAListKeyHoldingSomethingElseIsLeftAlone() {
        let key = FilterHistory.storageKey(FilterHistory.allKeys[0])
        XCTAssertNil(PreferenceSync.mergedValue(key: key, local: 42, remote: ["a"]))
        let merged = PreferenceSync.mergedValue(key: key, local: ["b"], remote: ["a"]) as? [String]
        XCTAssertEqual(merged.map(Set.init), Set(["a", "b"]), "readable lists still merge")
    }
}
