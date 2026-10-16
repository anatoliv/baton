import AVFoundation
import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import Observation
import OSLog

private let clippingLog = Logger(subsystem: "io.tonebox.baton", category: "Clippings")

/// Audio Baton made and kept: a reading saved to listen to later, and in time anything else
/// worth clipping out of what is playing.
///
/// **A clipping plays through the ordinary player, with no new machinery.** Its id *is* its file
/// URL, which `MediaKind` already classifies as `.localFile` and `resolveStreamURL` already
/// resolves — that is how the bundled demo library plays with no server behind it. So a clipping
/// gets the transport, the now-playing bar, the queue and the scrubber for free, and needs no
/// second player path. The alternative, a bespoke surface with its own playback, was the design
/// first considered for the phone and is worse for exactly that reason.
///
/// **Deliberately not `MusicDownloadStore`.** That store is keyed by server song id and exists to
/// make *server* content available offline: its operations are "download this again" and "remove
/// the local copy, the original is safe on the server". Neither is true here. A clipping has no
/// original anywhere — it is the only copy — so filing it there would offer two operations that
/// silently mean nothing and one, delete, that quietly destroys data rather than freeing a cache.
///
/// **Sidecar per clip rather than a central index**, the same shape the gateway's `FileStore`
/// uses: an index is one file whose corruption loses every clipping, while a directory of pairs
/// can be rebuilt by listing it.
@MainActor
@Observable
public final class ClippingStore {

    /// One saved piece of audio.
    public struct Clipping: Codable, Equatable, Identifiable, Sendable {
        /// The file name on disk, without extension. Stable, and not the play id.
        public var id: String
        /// What it is called in the list. A reading has no title of its own, so this is built
        /// from what is actually known: where it came from and when.
        public var title: String
        /// Where it came from — an app name, a site, a podcast. Shown as the subtitle.
        public var source: String?
        public var durationSeconds: Double?
        public var createdAt: Date
        /// For a reading, the words. This is what makes a clipping the only thing in Baton
        /// searchable by *what is said in it*, and it lets the existing transcript panel show a
        /// reading's text with no new UI.
        public var text: String?
        /// SHA-256, when it came from or is going to another device. Opaque here.
        public var sha256: String?

        // A chapter of a narrated book (`specs/document-clippings.md`). All nil for a reading.
        // Sidecar v2: a v1 sidecar has none of these and reads unchanged.

        /// The book this chapter belongs to: `PreparedBook.documentID`, the same on every device
        /// and in every voice, which is what position and "finished" sync on.
        public var documentID: String?
        public var documentTitle: String?
        public var author: String?
        /// 0-based.
        public var chapterIndex: Int?
        public var chapterTitle: String?
        public var lastPlayedAt: Date?
        /// The voice it is read in, as an `"engine:voice"` spec (`kokoro:af_heart`), so Change
        /// Voice can say which voice it has now. Sidecar v3; nil in a clipping kept
        /// before it, whose voice nobody wrote down.
        public var voice: String?

        public var isBookChapter: Bool { documentID != nil }

        public init(id: String, title: String, source: String? = nil,
                    durationSeconds: Double? = nil, createdAt: Date,
                    text: String? = nil, sha256: String? = nil) {
            self.id = id
            self.title = title
            self.source = source
            self.durationSeconds = durationSeconds
            self.createdAt = createdAt
            self.text = text
            self.sha256 = sha256
        }
    }

    /// What `adopt` needs to file a clipping as a chapter of a book.
    public struct BookChapter: Equatable, Sendable {
        public var documentID: String
        public var documentTitle: String
        public var author: String?
        public var chapterIndex: Int
        public var chapterTitle: String

        public init(documentID: String, documentTitle: String, author: String?, chapterIndex: Int,
                    chapterTitle: String) {
            self.documentID = documentID
            self.documentTitle = documentTitle
            self.author = author
            self.chapterIndex = chapterIndex
            self.chapterTitle = chapterTitle
        }
    }

    /// A clipping plus where it actually lives, which is the pairing every caller wants.
    public struct Item: Identifiable, Equatable, Sendable {
        public var clipping: Clipping
        public var url: URL
        public var id: String { clipping.id }

        /// Whether the audio is still on disk. An entry whose file has gone must be visible and
        /// obviously broken rather than silently failing at the moment someone presses play — a
        /// store whose entries can be false is worse than no store.
        public var isPresent: Bool { FileManager.default.fileExists(atPath: url.path) }

        /// The id this clipping has in the player's queue: its file URL, which is `asSong.id`.
        /// Not `id`, which is the clipping's own id; see `ClippingStore.item(forSongID:)`.
        public var songID: String { url.absoluteString }

        /// Whether this clipping is the one loaded in the player, given the player's
        /// `nowPlaying?.id`. The Clippings rows mark it the way music rows mark
        /// the current track, and this is the one comparison they all make.
        public func isLoaded(nowPlayingID: String?) -> Bool {
            nowPlayingID == songID
        }

        /// What the player is handed. The id is the file URL, which is what makes this play
        /// through the ordinary path — see the type's note.
        ///
        /// A book chapter is a track of an album named after the book, by its author, so the
        /// queue, the scrubber and now-playing show "The Machine Stops · 2" with no new UI.
        public var asSong: NavidromeSong {
            var song = NavidromeSong(
                id: songID,
                title: clipping.title,
                artist: clipping.isBookChapter ? (clipping.author ?? clipping.source) : clipping.source,
                album: clipping.isBookChapter ? (clipping.documentTitle ?? "Clippings") : "Clippings",
                duration: clipping.durationSeconds.map { Int($0) },
                coverArtID: nil
            )
            if let index = clipping.chapterIndex, clipping.isBookChapter {
                song.track = index + 1
                song.genre = "Audiobook"
            }
            return song
        }
    }

    public private(set) var items: [Item] = []

    private let directory: URL
    private let defaults: UserDefaults
    private var loaded = false
    /// Whether clipping audio is kept out of backups: true on the iPhone, false on the Mac
    /// (`BackupExclusion`, DOC-24). An argument rather than a check at the call site so the
    /// iPhone's behaviour can be tested on the Mac.
    private let excludesAudioFromBackup: Bool

    public init(directory: URL? = nil, defaults: UserDefaults = BatonStorage.defaults,
                excludesAudioFromBackup: Bool = BackupExclusion.appliesOnThisPlatform) {
        self.directory = directory ?? Self.defaultDirectory()
        self.defaults = defaults
        self.excludesAudioFromBackup = excludesAudioFromBackup
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        // Audio already on disk from a build that set nothing is still in the backup. Marked at
        // launch rather than once behind a flag: it costs one resource read per file, and it also
        // catches audio that reached this directory by any route that did not go through `adopt`.
        // Everything in this directory is the store's own, so all of its audio qualifies; the
        // sidecars beside it are not audio and stay backed up.
        if excludesAudioFromBackup {
            let marked = BackupExclusion.exclude(BackupExclusion.audioFiles(in: self.directory))
            if marked > 0 { clippingLog.notice("excluded \(marked) clipping audio files from backup") }
        }
    }

    // MARK: - Reading

    /// Newest first, which is the order "what did I save" wants.
    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    public func reload() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        items = names
            .filter { $0.hasSuffix(".json") && $0 != Self.dismissedFileName }
            .compactMap { name -> Item? in
                let id = String(name.dropLast(5))
                guard let clip = sidecarStore(id).load() else { return nil }
                return Item(clipping: clip, url: audioURL(id))
            }
            .sorted { $0.clipping.createdAt > $1.clipping.createdAt }
    }

    public func item(id: String) -> Item? { items.first { $0.id == id } }

    /// One chapter of a book, so a chapter is never adopted twice.
    public func item(documentID: String, chapterIndex: Int) -> Item? {
        items.first { $0.clipping.documentID == documentID && $0.clipping.chapterIndex == chapterIndex }
    }

    /// A book's chapters, in reading order.
    public func chapters(ofDocument documentID: String) -> [Item] {
        items.filter { $0.clipping.documentID == documentID }
            .sorted { ($0.clipping.chapterIndex ?? 0) < ($1.clipping.chapterIndex ?? 0) }
    }

    /// The clipping a **player** id refers to, which is not the same lookup as `item(id:)`.
    ///
    /// An `Item.id` is the clipping's own id; the id the player carries is `asSong.id`, the
    /// file URL. Passing one to the other compiles perfectly and returns nil forever, which is
    /// how the player's "Delete Clipping…" item shipped invisible: the menu asked whether the
    /// playing song was a clipping, using the wrong key, and quietly decided it never was.
    /// Both are `String`, so nothing but this method can keep them apart.
    public func item(forSongID songID: String) -> Item? {
        items.first { $0.asSong.id == songID }
    }

    /// Total bytes on disk, for the view's "3 clippings, 24 MB" line.
    public var totalBytes: Int {
        items.reduce(0) { total, item in
            let size = (try? FileManager.default.attributesOfItem(atPath: item.url.path)[.size] as? Int) ?? nil
            return total + (size ?? 0)
        }
    }

    // MARK: - Writing

    public enum StoreError: Error, Equatable {
        case couldNotStore(String)
    }

    /// Adopt an audio file as a clipping, **moving** it in.
    ///
    /// Moved rather than copied so there is exactly one copy and no way for the two to diverge.
    /// A rename within a filesystem is atomic, so a crash mid-adopt leaves either the file or no
    /// file, never a half-written one that plays as a truncated reading.
    @discardableResult
    public func adopt(_ source: URL, title: String, sourceName: String? = nil,
                      durationSeconds: Double? = nil, text: String? = nil,
                      sha256: String? = nil, chapter: BookChapter? = nil,
                      voice: String? = nil, now: Date = Date()) throws -> Item {
        loadIfNeeded()
        // Readings never said how long they were, so the player and the list had nothing to
        // show. The file knows.
        let durationSeconds = durationSeconds ?? Self.measuredDuration(of: source)
        let id = UUID().uuidString.lowercased()
        let destination = audioURL(id, extension: source.pathExtension.isEmpty ? "m4a" : source.pathExtension)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw StoreError.couldNotStore(error.localizedDescription)
        }
        // When the shared ledger already names this audio, that name wins and this device says
        // nothing about it.
        //
        // A device *collecting* a clipping has not chosen what it is called: the title it holds
        // is derived from the gateway's filename, which was fixed at upload and is the one thing
        // guaranteed to be stale. Stating it stamped `now` made it the newest word, so a clipping
        // renamed on the Mac arrived here under its old name — and worse, that statement then
        // travelled back and undid the rename at the other end.
        //
        // The seeding path already learned this and backdates to `createdAt`; `adopt` is the same
        // situation reached by a different route. Collecting is exactly the position of a device
        // that was switched off: it is learning about the clipping, not deciding anything about it.
        let known = sha256.flatMap { ledger.record(for: $0) }
        let effectiveTitle = known?.titleAt != nil ? (known?.title ?? title) : title
        let effectiveSource = known?.sourceAt != nil ? known?.source : sourceName
        var clipping = Clipping(id: id, title: effectiveTitle, source: effectiveSource,
                                durationSeconds: durationSeconds, createdAt: now,
                                text: text, sha256: sha256)
        clipping.voice = voice
        if let chapter {
            clipping.documentID = chapter.documentID
            clipping.documentTitle = chapter.documentTitle
            clipping.author = chapter.author
            clipping.chapterIndex = chapter.chapterIndex
            clipping.chapterTitle = chapter.chapterTitle
        }
        guard writeSidecar(clipping, id: id) else {
            // Do not leave audio with no record of what it is: that is a file nobody can
            // identify and nothing will ever clean up.
            try? FileManager.default.removeItem(at: destination)
            throw StoreError.couldNotStore("could not write the sidecar for \(id)")
        }
        // After the move, at the final path: the flag belongs to the file, not to the name it
        // was staged under. Only the audio; the sidecar just written is the record of what it is.
        if excludesAudioFromBackup { BackupExclusion.exclude(destination) }
        // Keeping the same audio again is a deliberate act and must beat an older tombstone,
        // exactly as a re-subscribe beats an unsubscribe. Without this, a clipping deleted
        // everywhere last week could never be kept again: it would upload to the same digest and
        // the next reconcile would delete it right back.
        if let digest = sha256 {
            var ledger = self.ledger
            ledger.restore(digest, at: now)
            // Only state a name nobody has stated before. Restating the one just read back would
            // re-stamp it `now` and reintroduce the bug in a subtler form: the value would be
            // right today and would outrank a rename made elsewhere a minute ago.
            if known?.titleAt == nil { ledger.setTitle(title, for: digest, at: now) }
            if known?.sourceAt == nil { ledger.setSource(sourceName, for: digest, at: now) }
            self.ledger = ledger
        }
        reload()
        clippingLog.notice("kept a clipping (\(effectiveTitle, privacy: .public))")
        return Item(clipping: clipping, url: destination)
    }

    /// What `replaceAudio` set aside: the audio a clipping had before, to put back if the change
    /// is abandoned.
    public struct PreviousAudio: Codable, Equatable, Sendable {
        /// The file name within the hold folder the caller gave.
        public var file: String
        public var durationSeconds: Double?
        public var sha256: String?
        public var voice: String?
    }

    /// Give a clipping other audio and keep everything else about it: its id, its title, its
    /// words, its chapter and when it was last played (Change Voice, TBX-10989). One row before
    /// and after, never a second one beside it.
    ///
    /// The new file takes the old one's place, **moved** in like `adopt`, under the same name
    /// when the two are the same kind of file, so a queue that holds the clipping's URL plays the
    /// new audio next time it reaches it. A player in the middle of the old file plays on to its
    /// end, since an open file outlives its name. The old audio is moved to `hold` when one is
    /// given, so the change can be undone, and removed otherwise.
    ///
    /// A new digest is stated in the shared ledger as `setSHA256` states one, under the title
    /// the clipping has, so a device collecting it later reads the same name.
    @discardableResult
    public func replaceAudio(id: String, with source: URL, durationSeconds: Double? = nil, sha256: String?,
                             voice: String?, holdingPreviousIn hold: URL? = nil,
                             now: Date = Date()) throws -> (item: Item, previous: PreviousAudio?) {
        loadIfNeeded()
        guard var item = item(id: id) else { throw StoreError.couldNotStore("no clipping \(id) to give new audio") }
        let durationSeconds = durationSeconds ?? Self.measuredDuration(of: source)
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let destination = audioURL(id, extension: ext)
        let fm = FileManager.default
        var previous: PreviousAudio?
        if fm.fileExists(atPath: item.url.path) {
            if let hold {
                let file = "\(id)-\(UUID().uuidString.lowercased()).\(item.url.pathExtension.isEmpty ? "m4a" : item.url.pathExtension)"
                do {
                    try fm.createDirectory(at: hold, withIntermediateDirectories: true)
                    try fm.moveItem(at: item.url, to: hold.appendingPathComponent(file))
                } catch {
                    throw StoreError.couldNotStore("could not set the old audio aside: \(error.localizedDescription)")
                }
                previous = PreviousAudio(file: file, durationSeconds: item.clipping.durationSeconds,
                                         sha256: item.clipping.sha256, voice: item.clipping.voice)
            } else {
                try? fm.removeItem(at: item.url)
            }
        }
        do {
            try fm.moveItem(at: source, to: destination)
        } catch {
            // Put the old audio back rather than leave a row with no file.
            if let previous, let hold { try? fm.moveItem(at: hold.appendingPathComponent(previous.file), to: item.url) }
            throw StoreError.couldNotStore(error.localizedDescription)
        }
        if excludesAudioFromBackup { BackupExclusion.exclude(destination) }
        item.clipping.durationSeconds = durationSeconds
        item.clipping.sha256 = sha256
        item.clipping.voice = voice
        guard writeSidecar(item.clipping, id: id) else {
            throw StoreError.couldNotStore("could not write the sidecar for \(id)")
        }
        if let digest = sha256, digest != previous?.sha256 {
            var ledger = self.ledger
            if ledger.record(for: digest)?.titleAt == nil { ledger.setTitle(item.clipping.title, for: digest, at: item.clipping.createdAt) }
            if ledger.record(for: digest)?.sourceAt == nil { ledger.setSource(item.clipping.source, for: digest, at: item.clipping.createdAt) }
            ledger.restore(digest, at: now)
            self.ledger = ledger
        }
        reload()
        clippingLog.notice("gave a clipping new audio (\(item.clipping.title, privacy: .public))")
        return (Item(clipping: item.clipping, url: destination), previous)
    }

    /// The length of an audio file, or nil when it cannot be read as audio.
    nonisolated static func measuredDuration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// When a clipping was last played, for the book row's "last played" and storage rules.
    public func setLastPlayed(id: String, at date: Date = Date()) {
        guard var item = item(id: id) else { return }
        item.clipping.lastPlayedAt = date
        guard writeSidecar(item.clipping, id: id) else { return }
        reload()
    }

    /// Record the content digest of a clipping that has since been uploaded.
    ///
    /// Written after the fact rather than at `adopt` time because the digest is what the *other*
    /// device deduplicates on, and it only becomes meaningful once the file has actually reached
    /// the gateway. A clipping that was never uploaded has no digest, which is the honest state.
    public func setSHA256(id: String, to digest: String, at now: Date = Date()) {
        guard var item = item(id: id) else { return }
        item.clipping.sha256 = digest
        guard writeSidecar(item.clipping, id: id) else { return }
        // The ledger is keyed by digest, so a clipping cannot appear in it until it has one.
        // This is the moment it does: state its title and source now, or the other device would
        // collect the file and have nothing shared to compare against, leaving a later rename
        // here with no earlier statement to beat.
        var ledger = self.ledger
        ledger.setTitle(item.clipping.title, for: digest, at: item.clipping.createdAt)
        ledger.setSource(item.clipping.source, for: digest, at: item.clipping.createdAt)
        ledger.restore(digest, at: now)
        self.ledger = ledger
        reload()
    }

    // MARK: - Dismissed clippings

    /// Digests this device has deliberately removed and does not want back.
    ///
    /// **Deleting without this is futile on a collecting device.** `ClippingsView.collect()`
    /// decides what to fetch by comparing the gateway's listing against the digests it holds
    /// locally, so removing a clipping takes its digest out of that set and the very next refresh
    /// downloads it again. A union of "what is there" and "what I have" converges for adding and
    /// is structurally unable to express a removal.
    ///
    /// This repo has already paid for that lesson once: `PodcastSubscriptionLedger` exists
    /// because unsubscribing on one device was handed straight back by the other. Same
    /// shape, same answer — a tombstone with a clock.
    ///
    /// Thirty days, chosen against the gateway's own `FileStore.defaultMaximumAge` of fourteen.
    /// A tombstone only has to outlive the file it is suppressing; beyond that it is dead weight,
    /// and never expiring means this list grows for the life of the install.
    public static let dismissedRetention: TimeInterval = 30 * 24 * 60 * 60
    static let dismissedFileName = "dismissed.json"

    private var dismissedURL: URL { directory.appendingPathComponent(Self.dismissedFileName) }

    /// Versioned backing for the tombstones (S-F14).
    ///
    /// A tombstone list that reads as empty is not a harmless blank: every clipping this device
    /// deleted comes back on the next reconcile, which is the failure the list exists to stop.
    /// A damaged `dismissed.json` used to do exactly that, and the next dismissal wrote the
    /// short list over it. The file name is unchanged and the old raw `[String: Date]` map is
    /// still adopted on load.
    private var dismissedStore: VersionedStore<[String: Date]> {
        VersionedStore<[String: Date]>(fileURL: dismissedURL, currentVersion: 1,
                                       keepBackup: true, log: clippingLog)
    }

    /// Digests dismissed on this device and still within the retention window.
    public var dismissedDigests: Set<String> {
        Set(loadDismissed().keys)
    }

    private func loadDismissed() -> [String: Date] {
        guard let raw = dismissedStore.load() else { return [:] }
        let cutoff = Date().addingTimeInterval(-Self.dismissedRetention)
        return raw.filter { $0.value > cutoff }
    }

    /// Reports whether the tombstone file actually reached the disk. This is the write the
    /// whole dismissal mechanism rests on: swallowing its failure is how a deleted clipping
    /// comes straight back on the next refresh, with nothing anywhere saying why.
    @discardableResult
    private func saveDismissed(_ entries: [String: Date]) -> Bool {
        // `VersionedStore.save` logs the failure, and returning it keeps the caller's contract:
        // false means a removed clipping may come back on the next refresh.
        dismissedStore.save(entries)
    }

    /// Record that this device does not want a digest back, pruning anything expired.
    /// Returns false when the tombstone could not be written, which means the clipping will
    /// be collected again.
    @discardableResult
    public func dismiss(sha256 digest: String, now: Date = Date()) -> Bool {
        var entries = loadDismissed()
        entries[digest] = now
        return saveDismissed(entries)
    }

    /// Forget a dismissal, so the clipping may be collected again.
    @discardableResult
    public func undismiss(sha256 digest: String) -> Bool {
        var entries = loadDismissed()
        entries.removeValue(forKey: digest)
        return saveDismissed(entries)
    }

    /// Writes a clipping's sidecar, reporting whether it landed.
    ///
    /// The only place a sidecar is written. `adopt` used to encode and write its own copy, so
    /// the two paths could drift in format or in error handling, and this is the moment the
    /// migration puts them together (S-F14).
    ///
    /// Callers that also state something in the shared ledger must check this first: the ledger
    /// travels to the other device, so announcing a rename whose local sidecar silently did not
    /// change leaves the two devices disagreeing with no way to notice.
    @discardableResult
    private func writeSidecar(_ clipping: Clipping, id: String) -> Bool {
        sidecarStore(id).save(clipping) // logs on failure; a bad sidecar is kept aside
    }

    /// Rename a clipping, and say so in the shared ledger so the other device follows.
    ///
    /// The ledger write is what makes this travel. Without it the sidecar changes here and the
    /// phone keeps the old title for ever, which is the defect this whole mechanism exists for
    ///. A clipping that never reached the gateway has no digest and so nothing to
    /// say — it is local by definition.
    public func rename(id: String, to title: String, at now: Date = Date()) {
        guard var item = item(id: id) else { return }
        item.clipping.title = title
        // The ledger write below travels to the other device. Stating a rename there while the
        // local sidecar quietly did not change is worse than not renaming at all, so a failed
        // sidecar write stops here.
        guard writeSidecar(item.clipping, id: id) else { return }
        if let digest = item.clipping.sha256 {
            var ledger = self.ledger
            ledger.setTitle(title, for: digest, at: now)
            self.ledger = ledger
        }
        reload()
    }

    /// Delete a clipping and its audio. There is no copy anywhere else, so callers must confirm
    /// first — this is not a cache eviction.
    /// Delete a clipping and its audio. There is no copy anywhere else, so callers must confirm
    /// first — this is not a cache eviction.
    ///
    /// - Parameter dismissing: also record the digest as unwanted, so a device that collects from
    ///   the gateway does not download it again on its next refresh. Defaults to true because a
    ///   delete that undoes itself is not a delete; pass false only when the file is being removed
    ///   from the gateway as well and there is nothing left to come back.
    /// - Parameters:
    ///   - dismissing: also record the digest as unwanted **on this device**, so a collector does
    ///     not download it again on its next refresh. Defaults to true because a delete that
    ///     undoes itself is not a delete.
    ///   - everywhere: also state in the shared ledger that this clipping is gone, so the other
    ///     device deletes its copy too. The two flags are deliberately independent: "remove from
    ///     this device" is local and must not reach the other one, and "delete everywhere" needs
    ///     no local tombstone because the ledger already carries the stronger statement.
    public func remove(id: String, dismissing: Bool = true, everywhere: Bool = false,
                       at now: Date = Date()) {
        guard let item = item(id: id) else { return }
        if let digest = item.clipping.sha256 {
            if everywhere {
                var ledger = self.ledger
                ledger.remove(digest, at: now)
                self.ledger = ledger
            } else if dismissing {
                dismiss(sha256: digest)
            }
        }
        try? FileManager.default.removeItem(at: item.url)
        try? FileManager.default.removeItem(at: sidecarURL(id))
        reload()
    }

    // MARK: - The shared ledger

    /// This device's copy of what every device agrees about clippings.
    ///
    /// Held in `UserDefaults` rather than beside the sidecars because that is what
    /// `PreferenceSync` carries, and inventing a second transport for one file would mean two
    /// things that can disagree about the same fact.
    public var ledger: ClippingLedger {
        get { ClippingLedger.decode(defaults.data(forKey: ClippingLedger.storageKey)) ?? .init() }
        set { defaults.set(newValue.encoded(), forKey: ClippingLedger.storageKey) }
    }

    /// Seed the ledger from what is already on disk, once.
    ///
    /// **Stamped with each clipping's `createdAt`, not with now.** Seeding at "now" would make a
    /// device that had been switched off for a week arrive claiming its stale titles were the
    /// most recent word, silently reverting a rename made elsewhere. Backdating means any real
    /// statement, from any device, beats the seed.
    public func seedLedgerIfNeeded() {
        guard !defaults.bool(forKey: Self.ledgerSeededKey) else { return }
        loadIfNeeded()
        var ledger = self.ledger
        for item in items {
            guard let digest = item.clipping.sha256 else { continue }   // never travelled
            if ledger.record(for: digest) == nil {
                ledger.setTitle(item.clipping.title, for: digest, at: item.clipping.createdAt)
                ledger.setSource(item.clipping.source, for: digest, at: item.clipping.createdAt)
            }
        }
        self.ledger = ledger
        defaults.set(true, forKey: Self.ledgerSeededKey)
    }

    static let ledgerSeededKey = "tonebox.clippings.ledgerSeeded"

    /// Bring local state into line with the shared ledger.
    ///
    /// Returns what changed, so a caller can say so rather than having things move under the
    /// user with no explanation.
    /// `deleted` carries the **playable** ids of what went, not a count. The caller has to take
    /// those out of the play queue, and once the files are gone there is no way to work out what
    /// they were — a clipping deleted on the other device would otherwise keep playing here with
    /// nobody having touched this machine.
    @discardableResult
    public func reconcileWithLedger() -> (renamed: Int, deleted: [String]) {
        loadIfNeeded()
        let ledger = self.ledger
        var renamed = 0
        var deleted: [String] = []

        for item in items {
            guard let digest = item.clipping.sha256,
                  let record = ledger.record(for: digest) else { continue }

            if record.removed {
                // Deleted everywhere. No tombstone in `dismissedDigests`: that set means "not on
                // this device", and the ledger already carries the stronger statement. Writing
                // both would say the same thing twice in two places that can drift.
                deleted.append(item.asSong.id)
                try? FileManager.default.removeItem(at: item.url)
                try? FileManager.default.removeItem(at: sidecarURL(item.id))
                continue
            }
            var clipping = item.clipping
            var changed = false
            if let title = record.title, title != clipping.title { clipping.title = title; changed = true }
            if record.sourceAt != nil, record.source != clipping.source { clipping.source = record.source; changed = true }
            if changed, writeSidecar(clipping, id: item.id) {
                renamed += 1
            }
        }
        if renamed > 0 || !deleted.isEmpty { reload() }
        return (renamed, deleted)
    }

    // MARK: - Paths

    /// The audio file for an id. Extension discovered rather than assumed, so a clipping adopted
    /// as a WAV still resolves after a later version starts writing something else.
    private func audioURL(_ id: String) -> URL {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        // A sidecar sibling is not audio. `<id>.json` was excluded by suffix, which stopped
        // being enough the moment `VersionedStore` could leave `<id>.json.corrupt-<timestamp>`
        // next to it: that name has the id prefix, does not end in `.json`, and would have been
        // handed back as the clipping's audio file.
        if let match = names.first(where: { $0.hasPrefix(id + ".") && !$0.hasPrefix(id + ".json") }) {
            return directory.appendingPathComponent(match)
        }
        return audioURL(id, extension: "m4a")
    }

    private func audioURL(_ id: String, extension ext: String) -> URL {
        directory.appendingPathComponent("\(id).\(ext)")
    }

    private func sidecarURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    /// Versioned backing for one clipping's sidecar (S-F14).
    ///
    /// A sidecar is the only record of what a clipping *is*: its title, its source, its
    /// transcript. Lose it and the audio is a file nobody can identify. It used to be read with
    /// a `try?` inside `reload`, so an unreadable one made the clipping vanish from the list
    /// while its audio stayed on disk forever. Now the bytes are kept aside and the clipping is
    /// still absent, which is the same visible outcome with the evidence preserved.
    ///
    /// No `.bak`: the sidecar is small and written whole on every rename, so a rolling copy
    /// would double the writes for a file whose last-good state is one edit behind anyway.
    private func sidecarStore(_ id: String) -> VersionedStore<Clipping> {
        // v2 added the book-chapter fields. All optional, so v1 reads unchanged (identity
        // migration); the bump is so a downgraded build reads a v2 sidecar but refuses to write
        // it, rather than dropping fields it does not know about on its next rename.
        // v3 added `voice`, optional too.
        VersionedStore<Clipping>(fileURL: sidecarURL(id), currentVersion: 3,
                                 keepBackup: false, log: clippingLog)
    }

    private static func defaultDirectory() -> URL { BatonStorage.supportSubdirectory("Clippings") }
}
