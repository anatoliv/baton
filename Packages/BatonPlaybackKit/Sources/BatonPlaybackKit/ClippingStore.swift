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

    /// A clipping plus where it actually lives, which is the pairing every caller wants.
    public struct Item: Identifiable, Equatable, Sendable {
        public var clipping: Clipping
        public var url: URL
        public var id: String { clipping.id }

        /// Whether the audio is still on disk. An entry whose file has gone must be visible and
        /// obviously broken rather than silently failing at the moment someone presses play — a
        /// store whose entries can be false is worse than no store.
        public var isPresent: Bool { FileManager.default.fileExists(atPath: url.path) }

        /// What the player is handed. The id is the file URL, which is what makes this play
        /// through the ordinary path — see the type's note.
        public var asSong: NavidromeSong {
            NavidromeSong(
                id: url.absoluteString,
                title: clipping.title,
                artist: clipping.source,
                album: "Clippings",
                duration: clipping.durationSeconds.map { Int($0) },
                coverArtID: nil
            )
        }
    }

    public private(set) var items: [Item] = []

    private let directory: URL
    private let defaults: UserDefaults
    private var loaded = false

    public init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory ?? Self.defaultDirectory()
        self.defaults = defaults
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
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
                guard let data = try? Data(contentsOf: sidecarURL(id)),
                      let clip = try? JSONDecoder().decode(Clipping.self, from: data)
                else { return nil }
                return Item(clipping: clip, url: audioURL(id))
            }
            .sorted { $0.clipping.createdAt > $1.clipping.createdAt }
    }

    public func item(id: String) -> Item? { items.first { $0.id == id } }

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
                      sha256: String? = nil, now: Date = Date()) throws -> Item {
        loadIfNeeded()
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
        let clipping = Clipping(id: id, title: effectiveTitle, source: effectiveSource,
                                durationSeconds: durationSeconds, createdAt: now,
                                text: text, sha256: sha256)
        do {
            try JSONEncoder().encode(clipping).write(to: sidecarURL(id), options: .atomic)
        } catch {
            // Do not leave audio with no record of what it is: that is a file nobody can
            // identify and nothing will ever clean up.
            try? FileManager.default.removeItem(at: destination)
            throw StoreError.couldNotStore(error.localizedDescription)
        }
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

    /// Record the content digest of a clipping that has since been uploaded.
    ///
    /// Written after the fact rather than at `adopt` time because the digest is what the *other*
    /// device deduplicates on, and it only becomes meaningful once the file has actually reached
    /// the gateway. A clipping that was never uploaded has no digest, which is the honest state.
    public func setSHA256(id: String, to digest: String, at now: Date = Date()) {
        guard var item = item(id: id) else { return }
        item.clipping.sha256 = digest
        try? JSONEncoder().encode(item.clipping).write(to: sidecarURL(id), options: .atomic)
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

    /// Digests dismissed on this device and still within the retention window.
    public var dismissedDigests: Set<String> {
        Set(loadDismissed().keys)
    }

    private func loadDismissed() -> [String: Date] {
        guard let data = try? Data(contentsOf: dismissedURL),
              let raw = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        let cutoff = Date().addingTimeInterval(-Self.dismissedRetention)
        return raw.filter { $0.value > cutoff }
    }

    private func saveDismissed(_ entries: [String: Date]) {
        try? JSONEncoder().encode(entries).write(to: dismissedURL, options: .atomic)
    }

    /// Record that this device does not want a digest back, pruning anything expired.
    public func dismiss(sha256 digest: String, now: Date = Date()) {
        var entries = loadDismissed()
        entries[digest] = now
        saveDismissed(entries)
    }

    /// Forget a dismissal, so the clipping may be collected again.
    public func undismiss(sha256 digest: String) {
        var entries = loadDismissed()
        entries.removeValue(forKey: digest)
        saveDismissed(entries)
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
        try? JSONEncoder().encode(item.clipping).write(to: sidecarURL(id), options: .atomic)
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
    @discardableResult
    /// `deleted` carries the **playable** ids of what went, not a count. The caller has to take
    /// those out of the play queue, and once the files are gone there is no way to work out what
    /// they were — a clipping deleted on the other device would otherwise keep playing here with
    /// nobody having touched this machine.
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
            if changed {
                try? JSONEncoder().encode(clipping).write(to: sidecarURL(item.id), options: .atomic)
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
        if let match = names.first(where: { $0.hasPrefix(id + ".") && !$0.hasSuffix(".json") }) {
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

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Baton/Clippings", isDirectory: true)
    }
}
