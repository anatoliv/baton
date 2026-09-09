import BatonSubsonicModels
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// Clippings: audio Baton made and kept.
///
/// The property that carries the whole design is that a clipping's **id is its file URL**, which
/// `MediaKind` already classifies as `.localFile`. Get that wrong and it stops playing through
/// the ordinary player, which is the entire reason this needs no second playback path — so it is
/// asserted directly rather than assumed from the fact that something plays.
///
/// The rest is about not lying: an entry whose audio has gone must say so, and deleting must take
/// both halves. There is no copy on a server to fall back on, which is what makes a clipping
/// different from a download and is why these are the tests worth having.
@MainActor
final class ClippingStoreTests: XCTestCase {

    private var dir: URL!
    private var store: ClippingStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-clips-\(UUID().uuidString)")
        store = ClippingStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A file staged elsewhere, as the export produces.
    private func staged(_ bytes: Int = 2048, ext: String = "m4a") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).\(ext)")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    // MARK: - It plays like anything else

    /// The id handed to the player must be the file URL, and `MediaKind` must agree it is a local
    /// file. That pairing is what lets a clipping use `StreamingPlaybackController` unchanged —
    /// `resolveStreamURL` returns the URL directly for `.localFile`, with no server involved and
    /// no offline-mode refusal.
    func testAClippingIsHandedToThePlayerAsALocalFile() throws {
        let item = try store.adopt(try staged(), title: "Google Chrome 09.15",
                                   sourceName: "Google Chrome", durationSeconds: 371)

        let song = item.asSong
        XCTAssertEqual(song.id, item.url.absoluteString, "the play id must be the file URL")
        XCTAssertEqual(MediaKind(id: song.id), .localFile,
                       "if this is not .localFile the player will try to stream it from the server")
        XCTAssertEqual(song.title, "Google Chrome 09.15")
        XCTAssertEqual(song.artist, "Google Chrome")
        XCTAssertEqual(song.duration, 371)
    }

    /// It must not look like a library track anywhere, because it is not one and nothing on the
    /// server knows about it.
    func testAClippingCarriesNoServerCoverArt() throws {
        let item = try store.adopt(try staged(), title: "A reading")
        XCTAssertNil(item.asSong.coverArtID, "a server cover-art lookup for a local file is a bogus request")
    }

    /// Two ids, both `String`, and the wrong one compiles.
    ///
    /// A player only ever has `asSong.id`, the file URL. `item(id:)` is keyed on the clipping's
    /// own id. Asking `item(id: song.id)` therefore type-checks, runs, and answers "not a
    /// clipping" for every clipping there has ever been — which is exactly how the player's
    /// "Delete Clipping…" shipped in 1.0.9 as a menu item that could not appear.
    ///
    /// Asserted from both directions on purpose. The positive says the right lookup works; the
    /// negative pins the trap in place, so a later change that quietly merges the two keys has to
    /// come here and say so.
    func testAPlayerIdFindsItsClippingAndTheClippingIdIsADifferentKey() throws {
        let item = try store.adopt(try staged(), title: "Deploy products", sourceName: "Ghostty")
        let song = item.asSong

        XCTAssertEqual(store.item(forSongID: song.id)?.id, item.id,
                       "the id the player carries must find the clipping it is playing")
        XCTAssertNil(store.item(id: song.id),
                     "a file URL is not a clipping id — this is the mistake, pinned")
        XCTAssertEqual(store.item(id: item.id)?.id, item.id, "and the clipping id still works")
    }

    /// The other half of the same mistake, and the more expensive one: had the menu item been
    /// visible while passing the song's id, it would have deleted nothing and looked like it had.
    func testDeletingByThePlayersIdRemovesNothing() throws {
        let item = try store.adopt(try staged(), title: "Deploy products")

        store.remove(id: item.asSong.id)

        XCTAssertEqual(store.items.count, 1, "a file URL is not what remove(id:) is keyed on")
        store.remove(id: item.id)
        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: - Collecting something the other device has already named

    /// Reported: kept on the Mac, renamed straight away, and it arrived on the phone hours later
    /// still under the old name.
    ///
    /// The collecting device does not *choose* the title it holds — it is derived from the
    /// gateway's filename, fixed at upload, and therefore the one value guaranteed to be stale.
    /// Stating it stamped `now` made it the newest word and last-write-wins did the rest.
    func testCollectingSomethingAlreadyRenamedElsewhereKeepsTheNewName() throws {
        let digest = "aa11"
        var ledger = ClippingLedger()
        ledger.setTitle("Ghostty 09.15", for: digest, at: Date(timeIntervalSince1970: 1_000))
        ledger.setTitle("Deploy products", for: digest, at: Date(timeIntervalSince1970: 2_000))
        store.ledger = ledger

        // What collection actually passes: the gateway's filename, which still says the old name.
        let item = try store.adopt(try staged(), title: "Ghostty 09.15",
                                   sourceName: "Ghostty", sha256: digest)

        XCTAssertEqual(item.clipping.title, "Deploy products",
                       "the shared name is newer than anything this device knows")
    }

    /// The half that had not been noticed. A stale statement stamped `now` is newest
    /// *everywhere*, so it travels back and undoes the rename at the other end too.
    func testCollectingDoesNotPushTheStaleNameBackToTheOtherDevice() throws {
        let digest = "bb22"
        let renamedAt = Date(timeIntervalSince1970: 2_000)
        var ledger = ClippingLedger()
        ledger.setTitle("Deploy products", for: digest, at: renamedAt)
        store.ledger = ledger

        try store.adopt(try staged(), title: "Ghostty 09.15", sha256: digest)

        let record = store.ledger.record(for: digest)
        XCTAssertEqual(record?.title, "Deploy products", "the rename must survive being collected")
        XCTAssertEqual(record?.titleAt, renamedAt,
                       "and must not be re-stamped now, which would outrank a later rename elsewhere")
    }

    /// Nothing shared to go on, so the file's name is the best available and is stated normally.
    func testCollectingSomethingNobodyHasNamedUsesTheNameItCameWith() throws {
        let digest = "cc33"

        let item = try store.adopt(try staged(), title: "Ghostty 09.15",
                                   sourceName: "Ghostty", sha256: digest)

        XCTAssertEqual(item.clipping.title, "Ghostty 09.15")
        XCTAssertEqual(store.ledger.record(for: digest)?.title, "Ghostty 09.15",
                       "with no earlier statement, this device's is the one to make")
    }

    /// Keeping the same audio again after deleting it everywhere must still revive it. The fix
    /// stops `adopt` restating a *title*; it must not stop it beating a tombstone.
    func testKeepingTheSameAudioAgainStillRevivesIt() throws {
        let digest = "dd44"
        var ledger = ClippingLedger()
        ledger.setTitle("Deploy products", for: digest, at: Date(timeIntervalSince1970: 1_000))
        ledger.remove(digest, at: Date(timeIntervalSince1970: 2_000))
        store.ledger = ledger

        try store.adopt(try staged(), title: "Ghostty 09.15", sha256: digest,
                        now: Date(timeIntervalSince1970: 3_000))

        XCTAssertEqual(store.ledger.record(for: digest)?.removed, false,
                       "keeping it again is a deliberate act and must beat the tombstone")
    }

    // MARK: - Adopting

    /// Moved, not copied. One copy means the two can never diverge, and a rename within a
    /// filesystem is atomic, so a crash mid-adopt leaves either the file or no file.
    func testAdoptingMovesTheFileRatherThanCopyingIt() throws {
        let source = try staged()
        let item = try store.adopt(source, title: "Moved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "the staged file was copied, so two copies now exist")
        XCTAssertTrue(item.isPresent)
    }

    func testAdoptedClippingsSurviveAReopen() throws {
        try store.adopt(try staged(), title: "First", sourceName: "Ghostty")
        try store.adopt(try staged(), title: "Second", sourceName: "Google Chrome")

        let reopened = ClippingStore(directory: dir)
        reopened.loadIfNeeded()
        XCTAssertEqual(reopened.items.count, 2)
        XCTAssertEqual(Set(reopened.items.map(\.clipping.title)), ["First", "Second"])
    }

    /// Newest first: "what did I just save" is the question this list answers.
    func testNewestFirst() throws {
        let now = Date()
        try store.adopt(try staged(), title: "Older", now: now.addingTimeInterval(-3600))
        try store.adopt(try staged(), title: "Newer", now: now)
        XCTAssertEqual(store.items.map(\.clipping.title), ["Newer", "Older"])
    }

    /// A reading's words travel with it. This is what makes a clipping the only thing in Baton
    /// searchable by what is *said* in it, rather than only by its name.
    func testTheTextIsKeptAndSurvivesAReopen() throws {
        try store.adopt(try staged(), title: "An article",
                        text: "The first sentence. The second sentence.")
        let reopened = ClippingStore(directory: dir)
        reopened.loadIfNeeded()
        XCTAssertEqual(reopened.items.first?.clipping.text,
                       "The first sentence. The second sentence.")
    }

    /// A WAV adopted before the exporter moved to M4A must still resolve. The extension is
    /// discovered from disk rather than assumed, so old clippings keep playing.
    func testAnyAudioExtensionResolves() throws {
        let item = try store.adopt(try staged(ext: "wav"), title: "An old one")
        XCTAssertEqual(item.url.pathExtension, "wav")

        let reopened = ClippingStore(directory: dir)
        reopened.loadIfNeeded()
        XCTAssertTrue(reopened.items.first?.isPresent == true,
                      "a non-m4a clipping was not found again after a reopen")
    }

    // MARK: - Not lying about what is there

    /// The file can be deleted from underneath. The entry must then be visibly broken rather than
    /// failing silently the moment somebody presses play.
    func testAnEntryWhoseAudioHasGoneReportsItself() throws {
        let item = try store.adopt(try staged(), title: "About to vanish")
        XCTAssertTrue(item.isPresent)

        try FileManager.default.removeItem(at: item.url)

        let reopened = ClippingStore(directory: dir)
        reopened.loadIfNeeded()
        XCTAssertEqual(reopened.items.count, 1, "the entry should still be listed")
        XCTAssertFalse(reopened.items[0].isPresent, "it must report that its audio has gone")
    }

    /// Deleting takes both halves. Audio with no sidecar is a file nobody can identify and
    /// nothing will ever clean up.
    func testRemovingTakesTheAudioAndTheRecord() throws {
        let item = try store.adopt(try staged(), title: "Doomed")
        store.remove(id: item.id)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(leftovers.isEmpty, "left behind: \(leftovers)")
    }

    func testRenaming() throws {
        let item = try store.adopt(try staged(), title: "Untitled")
        store.rename(id: item.id, to: "The good article")
        XCTAssertEqual(store.item(id: item.id)?.clipping.title, "The good article")

        let reopened = ClippingStore(directory: dir)
        reopened.loadIfNeeded()
        XCTAssertEqual(reopened.items.first?.clipping.title, "The good article")
    }

    /// Debris in the directory must not take the listing down. This folder lives in Application
    /// Support and will collect things.
    func testStrayFilesDoNotBreakTheListing() throws {
        try store.adopt(try staged(), title: "Real")
        try Data("not json".utf8).write(to: dir.appendingPathComponent("deadbeef.json"))
        try Data("hello".utf8).write(to: dir.appendingPathComponent("README.txt"))

        let reopened = ClippingStore(directory: dir)
        reopened.loadIfNeeded()
        XCTAssertEqual(reopened.items.count, 1)
        XCTAssertEqual(reopened.items.first?.clipping.title, "Real")
    }
}

/// What must never happen to a clipping elsewhere in the app.
///
/// A clipping is not a library track, and every system that assumes "playing = a track from the
/// server" has to be checked rather than trusted. Scrobbling was the one that was wrong.
@MainActor
final class ClippingSideEffectTests: XCTestCase {

    /// A clipping must not reach Last.fm or ListenBrainz. Its "artist" is an app name and its
    /// "title" is a timestamp; a listening history cannot carry that and should not be asked to.
    ///
    /// `ScrobbleService`'s own doc comment claimed only library tracks scrobble, while the code
    /// excluded podcasts alone — true in practice only because nothing else was reachable. This
    /// pins the claim to the behaviour.
    func testAClippingIsNotScrobblable() {
        let clipping = NavidromeSong(
            id: URL(fileURLWithPath: "/tmp/whatever/clip.m4a").absoluteString,
            title: "Google Chrome 2026-08-29 09.15",
            artist: "Google Chrome", album: "Clippings", duration: 371, coverArtID: nil
        )
        XCTAssertEqual(MediaKind(id: clipping.id), .localFile)
        XCTAssertFalse(ScrobbleService.isScrobblableForTesting(clipping),
                       "a clipping was sent to external scrobbling as though it were a library track")
    }

    /// The exclusion must not have swallowed the case scrobbling exists for.
    func testALibraryTrackStillScrobbles() {
        let track = NavidromeSong(id: "abc123", title: "A song", artist: "An artist",
                                  album: "An album", duration: 200, coverArtID: nil)
        XCTAssertEqual(MediaKind(id: track.id), .libraryTrack)
        XCTAssertTrue(ScrobbleService.isScrobblableForTesting(track))
    }

    /// A podcast episode must keep its existing exemption. Moving from "not a podcast" to "is a
    /// library track" changed the shape of the test, and this is the case that shape could drop.
    func testAPodcastEpisodeStillDoesNotScrobble() {
        let episode = NavidromeSong(id: "https://example.com/ep1.mp3", title: "An episode",
                                    artist: "A show", album: nil, duration: 1800, coverArtID: nil)
        XCTAssertEqual(MediaKind(id: episode.id), .podcastEpisode)
        XCTAssertFalse(ScrobbleService.isScrobblableForTesting(episode))
    }

    /// Rows ask `isLocalOnly` to decide whether to show the server-only controls (download,
    /// rating, like, radio, mark-for-removal). If it answered wrongly a clipping would offer a
    /// "Remove Download" that deletes the only copy, and a rating that goes nowhere.
    func testLocalOnlyIsTrueForAClippingAndFalseForALibraryTrack() throws {
        let store = ClippingStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-clips-\(UUID().uuidString)"))
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).m4a")
        try Data(repeating: 0x41, count: 16).write(to: staged)
        let item = try store.adopt(staged, title: "A reading")

        XCTAssertTrue(item.asSong.isLocalOnly)
        XCTAssertFalse(NavidromeSong(id: "abc123", title: "A song", artist: nil, album: nil,
                                     duration: nil, coverArtID: nil).isLocalOnly)
        XCTAssertFalse(NavidromeSong(id: "https://example.com/ep1.mp3", title: "An episode",
                                     artist: nil, album: nil, duration: nil, coverArtID: nil).isLocalOnly,
                       "a podcast episode is remote — it still downloads and rates")
    }
}

/// A delete has to stay deleted.
///
/// On a device that collects from the gateway, removing a clipping without recording that fact
/// is futile: the fetch decides what to download by comparing the remote listing against the
/// digests it holds *locally*, so a delete takes the digest out of that set and the next refresh
/// downloads it straight back. A union of "what is there" and "what I have" converges for adding
/// and cannot express a removal.
///
/// This repo already paid for that lesson once with podcast subscriptions, where
/// unsubscribing on one device was handed back by the other. These pin the same rule here.
@MainActor
final class ClippingDismissalTests: XCTestCase {

    private var dir: URL!
    private var store: ClippingStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-dismiss-\(UUID().uuidString)")
        store = ClippingStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func staged() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).m4a")
        try Data(repeating: 0x41, count: 512).write(to: url)
        return url
    }

    /// Deleting records the digest, so a collector knows not to fetch it again.
    func testRemovingLeavesATombstone() throws {
        let item = try store.adopt(try staged(), title: "Doomed", sha256: "abc123")
        XCTAssertFalse(store.dismissedDigests.contains("abc123"))

        store.remove(id: item.id)

        XCTAssertTrue(store.dismissedDigests.contains("abc123"),
                      "deleting left no tombstone — the next refresh would download it again")
        XCTAssertTrue(store.items.isEmpty)
    }

    /// The tombstone must survive a relaunch, or the delete undoes itself the next morning.
    func testATombstoneSurvivesAReopen() throws {
        let item = try store.adopt(try staged(), title: "Doomed", sha256: "abc123")
        store.remove(id: item.id)

        let reopened = ClippingStore(directory: dir)
        XCTAssertTrue(reopened.dismissedDigests.contains("abc123"))
    }

    /// "Delete everywhere" removes the shared copy, so nothing can come back and a tombstone
    /// would only suppress a future clipping that happened to hash the same.
    func testDeletingEverywhereLeavesNoTombstone() throws {
        let item = try store.adopt(try staged(), title: "Doomed", sha256: "abc123")
        store.remove(id: item.id, dismissing: false)

        XCTAssertFalse(store.dismissedDigests.contains("abc123"))
        XCTAssertTrue(store.items.isEmpty)
    }

    /// A clipping that never reached the gateway has no digest, and must not crash or record an
    /// empty tombstone that would suppress everything else without one.
    func testRemovingAnUnuploadedClippingRecordsNothing() throws {
        let item = try store.adopt(try staged(), title: "Never sent")
        store.remove(id: item.id)
        XCTAssertTrue(store.dismissedDigests.isEmpty)
    }

    /// Deliberately keeping the same audio again should work, so a dismissal can be lifted.
    func testUndismissingAllowsItBack() throws {
        let item = try store.adopt(try staged(), title: "Doomed", sha256: "abc123")
        store.remove(id: item.id)
        XCTAssertTrue(store.dismissedDigests.contains("abc123"))

        store.undismiss(sha256: "abc123")
        XCTAssertFalse(store.dismissedDigests.contains("abc123"))
    }

    /// Tombstones expire. Thirty days outlives the gateway's own fourteen-day file retention, so
    /// the file is long gone before its tombstone is; keeping them forever would grow this list
    /// for the life of the install.
    func testTombstonesExpire() throws {
        store.dismiss(sha256: "old", now: Date().addingTimeInterval(-ClippingStore.dismissedRetention - 60))
        store.dismiss(sha256: "fresh")

        XCTAssertFalse(store.dismissedDigests.contains("old"), "an expired tombstone still suppresses")
        XCTAssertTrue(store.dismissedDigests.contains("fresh"))
    }

    /// The tombstone file lives in the same directory as the sidecars and must not be mistaken
    /// for one, or it would show up as a phantom clipping.
    func testTheTombstoneFileIsNotListedAsAClipping() throws {
        let item = try store.adopt(try staged(), title: "Real", sha256: "abc123")
        store.remove(id: item.id)
        try store.adopt(try staged(), title: "Another")

        let reopened = ClippingStore(directory: dir)
        reopened.loadIfNeeded()
        XCTAssertEqual(reopened.items.count, 1)
        XCTAssertEqual(reopened.items.first?.clipping.title, "Another")
    }
}

/// Applying the shared ledger to what is actually on disk.
///
/// The ledger tests prove the merge is right; these prove the store acts on it. Both halves are
/// needed and neither implies the other: a correct merge nobody applies changes nothing, and an
/// eager apply on a wrong merge deletes files.
@MainActor
final class ClippingReconcileTests: XCTestCase {

    private var dir: URL!
    private var suite: UserDefaults!
    private var store: ClippingStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-recon-\(UUID().uuidString)")
        let name = "baton.reconcile.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: name)!
        store = ClippingStore(directory: dir, defaults: suite)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func staged() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).m4a")
        try Data(repeating: 0x41, count: 256).write(to: url)
        return url
    }

    /// A rename made on the other device lands here.
    func testALedgerRenameIsAppliedLocally() throws {
        let item = try store.adopt(try staged(), title: "Old name", sha256: "abc")

        var ledger = store.ledger
        ledger.setTitle("New name", for: "abc", at: Date())
        store.ledger = ledger

        let changed = store.reconcileWithLedger()
        XCTAssertEqual(changed.renamed, 1)
        XCTAssertEqual(store.item(id: item.id)?.clipping.title, "New name")
    }

    /// And it survives a reopen, or the rename would come back on next launch.
    func testAnAppliedRenameIsPersisted() throws {
        try store.adopt(try staged(), title: "Old name", sha256: "abc")
        var ledger = store.ledger
        ledger.setTitle("New name", for: "abc", at: Date())
        store.ledger = ledger
        store.reconcileWithLedger()

        let reopened = ClippingStore(directory: dir, defaults: suite)
        reopened.loadIfNeeded()
        XCTAssertEqual(reopened.items.first?.clipping.title, "New name")
    }

    /// A deletion made on the other device removes the file here, audio and sidecar both.
    func testALedgerDeletionRemovesTheLocalCopy() throws {
        let item = try store.adopt(try staged(), title: "Doomed", sha256: "abc")
        XCTAssertTrue(item.isPresent)

        var ledger = store.ledger
        ledger.remove("abc", at: Date())
        store.ledger = ledger

        let changed = store.reconcileWithLedger()
        // The playable id, not a count: the caller has to take it out of the play queue, and
        // once the file is gone there is no way to work out what it was.
        XCTAssertEqual(changed.deleted, [item.asSong.id])
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0 != ClippingStore.dismissedFileName }
        XCTAssertTrue(leftovers.isEmpty, "left behind: \(leftovers)")
    }

    /// A clipping that never reached the gateway has no digest and nothing shared to say about
    /// it. Reconciling must leave it entirely alone rather than treat "absent from the ledger"
    /// as "deleted elsewhere" — that would silently destroy every local-only clipping.
    func testAClippingWithNoDigestIsUntouched() throws {
        let item = try store.adopt(try staged(), title: "Local only")

        var ledger = store.ledger
        ledger.remove("something-else", at: Date())
        store.ledger = ledger

        let changed = store.reconcileWithLedger()
        XCTAssertTrue(changed.deleted.isEmpty)
        XCTAssertEqual(store.item(id: item.id)?.clipping.title, "Local only")
    }

    /// Renaming here states it in the ledger, which is the only reason it travels.
    func testRenamingWritesToTheLedger() throws {
        let item = try store.adopt(try staged(), title: "Before", sha256: "abc")
        store.rename(id: item.id, to: "After")
        XCTAssertEqual(store.ledger.record(for: "abc")?.title, "After")
    }

    /// "Delete everywhere" states it; "remove from this device" deliberately does not, or one
    /// device tidying up would destroy the other's copy.
    func testOnlyDeleteEverywhereWritesATombstone() throws {
        let a = try store.adopt(try staged(), title: "Local delete", sha256: "aaa")
        let b = try store.adopt(try staged(), title: "Shared delete", sha256: "bbb")

        store.remove(id: a.id)                          // this device only
        store.remove(id: b.id, everywhere: true)        // everywhere

        // A live record exists (adopt states it), and the point is that it is not a tombstone.
        XCTAssertEqual(store.ledger.record(for: "aaa")?.removed, false,
                       "a local removal leaked into the shared ledger and would delete the other device's copy")
        XCTAssertEqual(store.ledger.record(for: "bbb")?.removed, true)
        XCTAssertTrue(store.dismissedDigests.contains("aaa"))
        XCTAssertFalse(store.dismissedDigests.contains("bbb"),
                       "delete-everywhere also wrote a local tombstone, saying the same thing twice")
    }

    /// Keeping the same audio again after deleting it everywhere must revive it, or the next
    /// reconcile deletes it straight back and it can never be kept again.
    func testKeepingItAgainRevivesItInTheLedger() throws {
        let first = try store.adopt(try staged(), title: "Round one", sha256: "abc")
        store.remove(id: first.id, everywhere: true)
        XCTAssertEqual(store.ledger.record(for: "abc")?.removed, true)

        try store.adopt(try staged(), title: "Round two", sha256: "abc")
        XCTAssertEqual(store.ledger.record(for: "abc")?.removed, false)

        store.reconcileWithLedger()
        XCTAssertEqual(store.items.count, 1, "the revived clipping was deleted by reconcile")
    }

    /// Seeding backdates to each clipping's own creation. Stamping "now" would let a device that
    /// had been off for a week arrive claiming its stale titles were the latest word.
    func testSeedingBackdatesToTheClippingsOwnDate() throws {
        let long_ago = Date(timeIntervalSince1970: 1_000_000)
        try store.adopt(try staged(), title: "Old", sha256: "abc", now: long_ago)

        store.seedLedgerIfNeeded()
        XCTAssertEqual(store.ledger.record(for: "abc")?.titleAt, long_ago)
    }

    /// A rename from elsewhere must beat the seed, which is the whole reason for backdating.
    func testARemoteRenameBeatsTheSeed() throws {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let item = try store.adopt(try staged(), title: "Seeded name", sha256: "abc", now: old)
        store.seedLedgerIfNeeded()

        var incoming = ClippingLedger()
        incoming.setTitle("Renamed elsewhere", for: "abc", at: old.addingTimeInterval(3600))
        store.ledger = ClippingLedger.merged(store.ledger, incoming)

        store.reconcileWithLedger()
        XCTAssertEqual(store.item(id: item.id)?.clipping.title, "Renamed elsewhere")
    }
}


/// The clipping files moving onto `VersionedStore` (S-F14 / TBX-5354).
///
/// A sidecar is the only record of what a clipping is, and a tombstone list that reads as
/// empty brings back every clipping this device deleted. Neither can be re-derived from
/// anything, which is what puts them in this batch.
@MainActor
final class ClippingPersistenceTests: XCTestCase {

    private var dir: URL!
    private var suite: UserDefaults!
    private var store: ClippingStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-clip-store-\(UUID().uuidString)")
        suite = UserDefaults(suiteName: "baton.clipstore.\(UUID().uuidString)")!
        store = ClippingStore(directory: dir, defaults: suite)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func staged() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).m4a")
        try Data(repeating: 0x41, count: 2048).write(to: url)
        return url
    }

    private func reopened() -> ClippingStore {
        let store = ClippingStore(directory: dir, defaults: suite)
        store.loadIfNeeded()
        return store
    }

    // MARK: - The move onto VersionedStore (S-F14 / TBX-5354)

    /// Exactly what the pre-`VersionedStore` code wrote for both files: raw JSON, no envelope.
    ///
    ///     try JSONEncoder().encode(clipping).write(to: sidecarURL(id), options: .atomic)
    ///     try JSONEncoder().encode(entries).write(to: dismissedURL, options: .atomic)
    private func writeLegacySidecar(_ clipping: ClippingStore.Clipping) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(clipping)
            .write(to: dir.appendingPathComponent("\(clipping.id).json"), options: .atomic)
    }

    private func writeLegacyDismissed(_ entries: [String: Date]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries)
            .write(to: dir.appendingPathComponent("dismissed.json"), options: .atomic)
    }

    func testReadsSidecarsAndTombstonesWrittenByTheOldCodeUnchanged() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = ClippingStore.Clipping(id: "0c1d2e3f", title: "Google Chrome 09.15",
                                            source: "Google Chrome", durationSeconds: 371,
                                            createdAt: created, text: "the words that were read",
                                            sha256: "abc123")
        try writeLegacySidecar(legacy)
        let audio = dir.appendingPathComponent("0c1d2e3f.m4a")
        try Data(repeating: 0x41, count: 2048).write(to: audio)
        // Inside the 30-day retention window, or the tombstone is expired rather than lost.
        let dismissedAt = Date().addingTimeInterval(-3600)
        try writeLegacyDismissed(["deadbeef": dismissedAt])

        let reopened = reopened()
        XCTAssertEqual(reopened.item(id: "0c1d2e3f")?.clipping, legacy,
                       "an upgrade must read the clipping the old build kept")
        XCTAssertEqual(reopened.item(id: "0c1d2e3f")?.url, audio,
                       "the audio file must still be found next to the sidecar")
        XCTAssertEqual(reopened.dismissedDigests, ["deadbeef"],
                       "an upgrade must read the tombstones, or every deleted clipping returns")

        // And the write that follows keeps both.
        reopened.rename(id: "0c1d2e3f", to: "Renamed")
        XCTAssertTrue(reopened.dismiss(sha256: "cafebabe"))
        let third = self.reopened()
        XCTAssertEqual(third.item(id: "0c1d2e3f")?.clipping.title, "Renamed")
        XCTAssertEqual(third.item(id: "0c1d2e3f")?.clipping.text, "the words that were read")
        XCTAssertEqual(third.dismissedDigests, ["deadbeef", "cafebabe"])
    }

    /// An unreadable sidecar leaves the clipping out of the list either way. What changes is
    /// that the bytes survive, so the title and transcript can be recovered by hand instead of
    /// being replaced by the next rename.
    func testACorruptSidecarIsQuarantinedRatherThanOverwritten() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let damaged = Data(#"{"id":"0c1d2e3f","title":"Google Chr"#.utf8)
        try damaged.write(to: dir.appendingPathComponent("0c1d2e3f.json"))
        try Data(repeating: 0x41, count: 2048).write(to: dir.appendingPathComponent("0c1d2e3f.m4a"))

        let reopened = reopened()
        XCTAssertNil(reopened.item(id: "0c1d2e3f"), "an unreadable sidecar is not a clipping")

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let aside = try XCTUnwrap(names.first { $0.hasPrefix("0c1d2e3f.json.corrupt-") },
                                  "the damaged bytes were not kept: \(names)")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(aside)), damaged,
                       "the quarantined copy must be the original bytes, byte for byte")
    }

    /// A quarantined sidecar sits next to the clipping under a name that starts with its id and
    /// does not end in `.json`, which is exactly the shape the audio lookup used to accept.
    ///
    /// Written with the audio file absent on purpose, so the answer cannot depend on which
    /// name the directory enumeration happens to return first: the quarantine file is the only
    /// candidate the old rule would have matched. The right answer with no audio present is the
    /// default `<id>.m4a` path, which the view then reports as a missing file. The wrong one is
    /// a JSON fragment handed to the player as audio.
    func testAQuarantinedSidecarIsNotMistakenForTheAudioFile() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try writeLegacySidecar(.init(id: "0c1d2e3f", title: "Kept", source: "Chrome",
                                     durationSeconds: 90, createdAt: created))
        try Data(#"{"id":"0c1d2e3f","tit"#.utf8)
            .write(to: dir.appendingPathComponent("0c1d2e3f.json.corrupt-2026-09-09T00-00-00Z"))

        let reopened = reopened()
        XCTAssertEqual(reopened.item(id: "0c1d2e3f")?.url.lastPathComponent, "0c1d2e3f.m4a",
                       "the quarantine file was handed back as the clipping's audio")
    }

    /// A tombstone list that reads as empty is not a blank slate: every clipping this device
    /// deleted comes back on the next reconcile.
    func testACorruptTombstoneFileIsQuarantinedRatherThanOverwritten() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let damaged = Data(#"{"deadbeef":75300000"#.utf8)
        try damaged.write(to: dir.appendingPathComponent("dismissed.json"))

        let reopened = reopened()
        XCTAssertTrue(reopened.dismissedDigests.isEmpty)
        XCTAssertTrue(reopened.dismiss(sha256: "cafebabe")) // used to destroy the old list

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let aside = try XCTUnwrap(names.first { $0.hasPrefix("dismissed.json.corrupt-") },
                                  "the damaged tombstones were not kept: \(names)")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(aside)), damaged)
    }
}
