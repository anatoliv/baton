import BatonSubsonicKit
import BatonSubsonicModels
import XCTest
@testable import BatonAgentKit

/// A friend store whose file cannot be read (S-F2), and one that arrived over its cap (S-F18).
///
/// The old shape compounded three defects into one loss. Both `try?`s in `load` swallowed, so
/// `contents` stayed empty; the next `remember` or `forget` atomically replaced the good file with
/// an empty one; and because the publish inferred a deletion from an absence, that empty state was
/// then broadcast as the owner having deleted every memory, with a 180-day tombstone the other
/// device honours. One unreadable file on the Mac permanently deleted the music friend's memories
/// on the phone. `save()` returned `Void` and could not fail, so the router said "Noted" through
/// all of it.
@MainActor
final class FriendStoreCorruptionTests: XCTestCase {
    private var directory: URL!
    private var suiteNames: [String] = []

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("friend-corrupt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func suite() -> UserDefaults {
        let name = "io.tonebox.tests.friendcorrupt.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private var memoryURL: URL { directory.appendingPathComponent("remote-memory.json") }
    private var learnedURL: URL { directory.appendingPathComponent("music-friend-learned.json") }

    // MARK: - The file the store cannot read

    /// The case ported from `VersionedStoreTests`: write `{`, construct, mutate, and the original
    /// must still exist rather than having been replaced by an empty file.
    func testAnUnreadableMemoryFileIsPreservedRatherThanReplaced() throws {
        try Data("{ this is not json".utf8).write(to: memoryURL)
        let defaults = suite()

        let store = RemoteMemoryStore(url: memoryURL, defaults: defaults)
        XCTAssertFalse(store.lastLoadSucceeded, "the store must know its own file did not load")
        _ = store.remember(kind: "preference", text: "no live albums", quote: "never live ones")

        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("remote-memory.json.corrupt") }
        XCTAssertEqual(aside.count, 1, """
            The unreadable file was replaced by the next mutation instead of being preserved. \
            Those sentences are things the owner said, and nothing can re-derive them.
            """)
    }

    /// The half that reached the other device, and the one that could not be undone: a failed
    /// load must not publish a single tombstone. The peer honours a removal for 180 days.
    func testAFailedLoadPublishesNoTombstones() throws {
        let defaults = suite()

        // A ledger the other device has already filled in.
        var ledger = FriendLedger()
        ledger.memories = [
            FriendLedger.Memory(key: FriendLedger.key(for: "no live albums"),
                                text: "no live albums", kind: "preference", quote: "a",
                                created: Date(), statedAt: Date()),
            FriendLedger.Memory(key: FriendLedger.key(for: "the gothic playlists are my partner's"),
                                text: "the gothic playlists are my partner's", kind: "fact",
                                quote: "b", created: Date(), statedAt: Date()),
        ]
        defaults.set(ledger.encoded(), forKey: FriendLedger.storageKey)

        try Data("{ truncated".utf8).write(to: memoryURL)
        let store = RemoteMemoryStore(url: memoryURL, defaults: defaults)
        // Any mutation at all: this is the moment the empty state used to be published.
        _ = store.remember(kind: "preference", text: "something new", quote: "c")

        let after = FriendLedger.decode(defaults.data(forKey: FriendLedger.storageKey)) ?? .init()
        XCTAssertEqual(after.memories.filter(\.removed).count, 0, """
            An unreadable file on this device told the other device the owner had deleted their \
            memories, and the tombstone suppresses them for 180 days.
            """)
    }

    /// The same shape in `FriendLearningStore`, which the review found had it identically.
    func testAFailedCorrectionLoadPublishesNoTombstones() throws {
        let defaults = suite()
        var ledger = FriendLedger()
        ledger.corrections = [
            FriendLedger.Correction(key: FriendLedger.key(for: "play something upbeat"),
                                    request: "play something upbeat", note: nil,
                                    fault: "wrongTrack", resolution: "played a dirge",
                                    date: Date(), statedAt: Date()),
        ]
        defaults.set(ledger.encoded(), forKey: FriendLedger.storageKey)

        try Data("not an array".utf8).write(to: learnedURL)
        let store = FriendLearningStore(url: learnedURL, defaults: defaults)
        XCTAssertFalse(store.lastLoadSucceeded)
        _ = store.learn(from: FriendExchange(surface: .phone, request: "play jazz",
                                             reply: "here is metal", rating: .down,
                                             fault: .wrongTrack, note: nil))

        let after = FriendLedger.decode(defaults.data(forKey: FriendLedger.storageKey)) ?? .init()
        XCTAssertEqual(after.corrections.filter(\.removed).count, 0)
    }

    /// A deliberate forget must still tombstone, or the fix above would have bought safety by
    /// breaking the feature the ledger exists for.
    func testADeliberateForgetStillTombstones() {
        let defaults = suite()
        let store = RemoteMemoryStore(url: memoryURL, defaults: defaults)
        let entry = store.remember(kind: "preference", text: "no live albums", quote: "a")

        _ = store.forget(id: try! XCTUnwrap(entry).id)

        let after = FriendLedger.decode(defaults.data(forKey: FriendLedger.storageKey)) ?? .init()
        XCTAssertEqual(after.memories.filter(\.removed).count, 1,
                       "a forget with no tombstone is undone by the other device's next push")
    }

    // MARK: - The write result reaches the caller

    /// `save()` returned `Void`. The router said "Noted, remembered" regardless, so a store that
    /// could not write told the owner it had.
    func testAStoreThatCannotWriteSaysSo() {
        let unwritable = URL(fileURLWithPath: "/dev/null/nope/remote-memory.json")
        let store = RemoteMemoryStore(url: unwritable, defaults: suite())

        _ = store.remember(kind: "preference", text: "no live albums", quote: "a")

        XCTAssertFalse(store.lastWriteSucceeded, """
            The write failed and the store reports success, so the router confirms a memory that \
            will not survive the next launch.
            """)
    }

    // MARK: - The cap is an invariant, not a write-path courtesy (S-F18)

    /// `SettingsTransfer` ships `music-friend-learned.json` between devices wholesale, so a file
    /// carrying a hundred corrections went straight into the system prompt. The type's own doc
    /// promises the prompt is bounded; trimming lived in `learn()` alone.
    func testAnOverCapCorrectionFileIsTrimmedOnLoad() throws {
        let many = (0..<100).map { index in
            FriendCorrection(request: "request \(index)", note: nil, fault: .wrongTrack,
                             date: Date(timeIntervalSince1970: Double(index)),
                             exchangeID: UUID(), resolution: "did the wrong thing")
        }
        try JSONEncoder().encode(many).write(to: learnedURL)

        let store = FriendLearningStore(url: learnedURL, defaults: suite())

        XCTAssertEqual(store.corrections.count, FriendLearningStore.maxCorrections)
        // Counted on the rendered block, not on the array: `promptBlock` renders whatever is
        // loaded with no `prefix` of its own, so the array is where the invariant has to hold.
        let block = try XCTUnwrap(store.promptBlock)
        XCTAssertEqual(block.components(separatedBy: "\n- ").count - 1,
                       FriendLearningStore.maxCorrections,
                       "the prompt block renders whatever is loaded, so the cap has to be in load")
    }

    /// And the write it used to cause: the ledger cap was 60 against a local 12, so every prompt
    /// build adopted 60, trimmed to 12, and wrote the file again. On the main actor. Every turn.
    func testTwoConsecutivePromptBuildsPerformNoSecondWrite() throws {
        let defaults = suite()
        var ledger = FriendLedger()
        ledger.corrections = (0..<40).map { index in
            FriendLedger.Correction(key: FriendLedger.key(for: "request \(index)"),
                                    request: "request \(index)", note: nil, fault: "wrongTrack",
                                    resolution: "did the wrong thing",
                                    date: Date(timeIntervalSince1970: Double(index)),
                                    statedAt: Date(timeIntervalSince1970: Double(index)))
        }
        // Through `merged`, because that is what actually reaches a device: the cap is applied
        // there, and asserting against a hand-built over-cap ledger would test a state the sync
        // cannot produce.
        let capped = FriendLedger.merged(ledger, .init())
        defaults.set(capped.encoded(), forKey: FriendLedger.storageKey)

        let store = FriendLearningStore(url: learnedURL, defaults: defaults)
        _ = store.promptBlock

        // Delete the file, then ask again. A second write recreates it, and a store that has
        // nothing new to say does not. Deterministic on purpose: comparing modification dates
        // rests on the filesystem's sub-second resolution, which is exactly the kind of test
        // that passes on this machine and flakes on the next.
        try FileManager.default.removeItem(at: learnedURL)

        _ = store.promptBlock

        XCTAssertFalse(FileManager.default.fileExists(atPath: learnedURL.path), """
            The second prompt build wrote the file again. That is a synchronous disk write on the \
            main actor on every conversational turn, and it is what the cap mismatch caused.
            """)
    }

    /// The ledger's caps must equal the stores' own, which is the thing that stops the loop
    /// above from coming back the next time either number is edited.
    func testTheLedgerCapsMatchTheStores() {
        XCTAssertEqual(FriendLedger.maximumCorrections, FriendLearningStore.maxCorrections)
        XCTAssertEqual(FriendLedger.maximumMemories, RemoteMemoryStore.entryLimit)
    }
}
