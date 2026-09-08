import XCTest
import BatonSubsonicModels
@testable import BatonAgentKit

/// Two devices, driven through the real stores rather than through the ledger type.
///
/// `FriendLedgerTests` proves the merge rule. This proves the half that actually breaks: that
/// the stores put their state *into* the ledger and take the merged answer back *out* of it.
/// A correct merge over a document nobody publishes to, or nobody adopts from, is the exact
/// defect shape this repo hit four times on 2026-09-07 — TBX-5114's settings that arrived and
/// were never read, and the keys written under one name and read under another.
@MainActor
final class FriendSyncTests: XCTestCase {
    private var phoneDefaults: UserDefaults!
    private var macDefaults: UserDefaults!
    private var names: [String] = []
    private var directory: URL!

    // async so the whole thing runs on the MainActor the stores are isolated to; the
    // synchronous overrides are nonisolated and cannot touch them under Swift 6.
    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("friend-sync-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        phoneDefaults = suite("phone")
        macDefaults = suite("mac")
    }

    override func tearDown() async throws {
        for name in names { UserDefaults().removePersistentDomain(forName: name) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func suite(_ label: String) -> UserDefaults {
        let name = "io.tonebox.tests.friendsync.\(label).\(UUID().uuidString)"
        names.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func memoryStore(_ label: String, _ defaults: UserDefaults) -> RemoteMemoryStore {
        RemoteMemoryStore(url: directory.appendingPathComponent("\(label)-memory.json"),
                          defaults: defaults)
    }

    private func learningStore(_ label: String, _ defaults: UserDefaults) -> FriendLearningStore {
        FriendLearningStore(url: directory.appendingPathComponent("\(label)-learned.json"),
                            defaults: defaults)
    }

    /// What the gateway does to the two devices' ledgers, using the same merge
    /// `PreferenceSync.mergedValue` dispatches to. Both sides adopt the result, which is what
    /// a sync leaves behind.
    private func syncLedgers() {
        let phone = FriendLedger.decode(phoneDefaults.data(forKey: FriendLedger.storageKey)) ?? .init()
        let mac = FriendLedger.decode(macDefaults.data(forKey: FriendLedger.storageKey)) ?? .init()
        let merged = FriendLedger.merged(phone, mac)
        phoneDefaults.set(merged.encoded(), forKey: FriendLedger.storageKey)
        macDefaults.set(merged.encoded(), forKey: FriendLedger.storageKey)
    }

    // MARK: - Memory

    func testSomethingToldToThePhoneReachesTheMac() {
        let phone = memoryStore("phone", phoneDefaults)
        let mac = memoryStore("mac", macDefaults)
        _ = phone.remember(kind: "preference", text: "no live albums", quote: "never live versions")

        syncLedgers()
        XCTAssertTrue(mac.adoptLedger())

        XCTAssertEqual(mac.entries.map(\.text), ["no live albums"])
    }

    /// The assertion the card was written around, driven through the stores.
    func testBothDevicesKeepWhatEachOfThemLearned() {
        let phone = memoryStore("phone", phoneDefaults)
        let mac = memoryStore("mac", macDefaults)
        _ = phone.remember(kind: "preference", text: "no live albums", quote: "a")
        _ = mac.remember(kind: "preference", text: "skip the intros", quote: "b")

        syncLedgers()
        phone.adoptLedger()
        mac.adoptLedger()

        XCTAssertEqual(Set(phone.entries.map(\.text)), ["no live albums", "skip the intros"])
        XCTAssertEqual(Set(mac.entries.map(\.text)), ["no live albums", "skip the intros"])
    }

    func testForgettingOnOneDeviceRemovesItOnTheOther() {
        let phone = memoryStore("phone", phoneDefaults)
        let mac = memoryStore("mac", macDefaults)
        let entry = phone.remember(kind: "preference", text: "no live albums", quote: "a")!
        syncLedgers(); mac.adoptLedger()
        XCTAssertEqual(mac.entries.count, 1)

        phone.forget(id: entry.id)
        syncLedgers()
        XCTAssertTrue(mac.adoptLedger())

        XCTAssertTrue(mac.entries.isEmpty, "a forget with no tombstone would be pushed straight back")
    }

    /// The id is minted locally on each device and must never travel: both ends number from
    /// their own sequence, so the same number means different things on each.
    func testAnArrivingMemoryGetsALocalIDThatDoesNotCollide() {
        let phone = memoryStore("phone", phoneDefaults)
        let mac = memoryStore("mac", macDefaults)
        _ = mac.remember(kind: "preference", text: "mac's own", quote: "m")
        _ = phone.remember(kind: "preference", text: "from the phone", quote: "p")

        syncLedgers()
        mac.adoptLedger()

        XCTAssertEqual(mac.entries.count, 2)
        XCTAssertEqual(Set(mac.entries.map(\.id)).count, 2, "two memories must not share an id")
    }

    // MARK: - Corrections, and retirement

    func testACorrectionMadeOnTheMacReachesThePhone() {
        let mac = learningStore("mac", macDefaults)
        let phone = learningStore("phone", phoneDefaults)
        let exchange = FriendExchange(surface: .phone, request: "play something upbeat", reply: "played a dirge",
                                      rating: .down, fault: .wrongTrack, note: "far too slow")
        _ = mac.learn(from: exchange)

        syncLedgers()
        XCTAssertTrue(phone.adoptLedger())

        XCTAssertEqual(phone.corrections.map(\.request), ["play something upbeat"])
    }

    /// A retirement is a fact about the friend, not about the device that saw it: the friend
    /// demonstrably got that request right, so the complaint should stop applying everywhere.
    func testARetirementOnOneDeviceStopsTheOtherCorrectingTheFriend() {
        let mac = learningStore("mac", macDefaults)
        let phone = learningStore("phone", phoneDefaults)
        let bad = FriendExchange(surface: .phone, request: "play something upbeat", reply: "a dirge",
                                 rating: .down, fault: .wrongTrack, note: "too slow")
        _ = mac.learn(from: bad)
        syncLedgers(); phone.adoptLedger()
        XCTAssertEqual(phone.corrections.count, 1)

        let good = FriendExchange(surface: .phone, request: "play something upbeat", reply: "something upbeat",
                                  rating: .up, fault: nil, note: nil)
        mac.retireIfApproved(good)

        syncLedgers()
        XCTAssertTrue(phone.adoptLedger())
        XCTAssertTrue(phone.corrections.isEmpty,
                      "without a tombstone the phone would push the retired complaint back")
    }

    // MARK: - It must not chatter

    /// Adopting what was just published must change nothing, or the two devices restate their
    /// whole state at each other on every sync forever.
    func testAdoptingAnUnchangedLedgerIsANoOp() {
        let phone = memoryStore("phone", phoneDefaults)
        _ = phone.remember(kind: "preference", text: "no live albums", quote: "a")
        syncLedgers()

        XCTAssertFalse(phone.adoptLedger(), "nothing changed, so nothing should be written")
    }

    func testAnEmptyLedgerDoesNotWipeAStoreThatHasContent() {
        let phone = memoryStore("phone", phoneDefaults)
        _ = phone.remember(kind: "preference", text: "no live albums", quote: "a")
        phoneDefaults.removeObject(forKey: FriendLedger.storageKey)

        XCTAssertFalse(phone.adoptLedger())
        XCTAssertEqual(phone.entries.count, 1,
                       "a device that has never synced must not be emptied by the absence of a ledger")
    }

    // MARK: - Forgetting the lot

    /// A bulk forget has to publish tombstones, not an empty ledger.
    ///
    /// `publishToLedger` is written to turn vanished entries into tombstones, and
    /// `forgetEverything` makes *every* entry vanish at once — the one case where "publish
    /// what is live" and "publish nothing" produce the same document unless the tombstone
    /// pass runs. Pinned here because a session purge is about to depend on it: the
    /// difference between the two is the difference between forgetting and forgetting until
    /// the next sync.
    func testForgettingEverythingLeavesTombstonesRatherThanAnEmptyLedger() {
        let phone = memoryStore("phone", phoneDefaults)
        _ = phone.remember(kind: "preference", text: "no live albums", quote: "a")
        _ = phone.remember(kind: "fact", text: "the gothic playlists are my partner's", quote: "b")

        phone.forgetEverything()

        let published = FriendLedger.decode(phoneDefaults.data(forKey: FriendLedger.storageKey)) ?? .init()
        XCTAssertEqual(published.memories.count, 2,
                       "an empty publish loses the record that these were deleted rather than never known")
        XCTAssertTrue(published.memories.allSatisfy(\.removed))
    }

    func testForgettingEverythingIsNotUndoneByTheNextSync() {
        let phone = memoryStore("phone", phoneDefaults)
        let mac = memoryStore("mac", macDefaults)
        _ = phone.remember(kind: "preference", text: "no live albums", quote: "a")
        _ = phone.remember(kind: "fact", text: "the gothic playlists are my partner's", quote: "b")
        syncLedgers(); mac.adoptLedger()
        XCTAssertEqual(mac.entries.count, 2)

        phone.forgetEverything()
        syncLedgers()
        mac.adoptLedger()
        phone.adoptLedger()

        XCTAssertTrue(phone.entries.isEmpty, "the mac pushed the memories back")
        XCTAssertTrue(mac.entries.isEmpty, "a forget on one device has to reach the other")
    }

    func testClearingEveryCorrectionIsNotUndoneByTheNextSync() {
        let mac = learningStore("mac", macDefaults)
        let phone = learningStore("phone", phoneDefaults)
        let bad = FriendExchange(surface: .phone, request: "play something upbeat", reply: "a dirge",
                                 rating: .down, fault: .wrongTrack, note: nil)
        _ = mac.learn(from: bad)
        syncLedgers(); phone.adoptLedger()
        XCTAssertEqual(phone.corrections.count, 1)

        mac.forgetAll()

        let published = FriendLedger.decode(macDefaults.data(forKey: FriendLedger.storageKey)) ?? .init()
        XCTAssertTrue(published.corrections.allSatisfy(\.removed), "cleared corrections must leave tombstones")

        syncLedgers()
        phone.adoptLedger()
        XCTAssertTrue(phone.corrections.isEmpty)
    }

    /// Deleting `baton.friend.ledger` is **not** a way to forget, and this is what happens
    /// if a purge tries it.
    ///
    /// The obvious way to add the friend's stores to a session purge is to delete the files
    /// and remove the defaults key alongside the twenty others. It reads as thorough and it
    /// is the one shape that cannot work: the tombstones live in that key, so removing it
    /// removes the only evidence the deletion happened, and the other device — which still
    /// holds the memory — pushes it straight back at the next sync. The person watched their
    /// memories disappear and they came back.
    ///
    /// Asserted as the trap rather than as a fix, because it is a property of the ledger
    /// (absence is not deletion) rather than a defect: the supported bulk clear is
    /// `forgetEverything()`, proved two tests up.
    func testWipingTheLedgerKeyIsNotAForgetAndTheNextSyncSaysSo() {
        let phone = memoryStore("phone", phoneDefaults)
        let mac = memoryStore("mac", macDefaults)
        _ = phone.remember(kind: "preference", text: "no live albums", quote: "a")
        syncLedgers(); mac.adoptLedger()

        // What a purge that treats the ledger as one more defaults key would do.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("phone-memory.json"))
        phoneDefaults.removeObject(forKey: FriendLedger.storageKey)
        let afterPurge = memoryStore("phone", phoneDefaults)
        XCTAssertTrue(afterPurge.entries.isEmpty, "the local wipe itself works — that is the trap")

        syncLedgers()
        afterPurge.adoptLedger()

        XCTAssertEqual(afterPurge.entries.map(\.text), ["no live albums"],
                       "removing the key removes the tombstones, so the other device restores the memory")
    }
}
