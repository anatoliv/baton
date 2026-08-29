import BatonPlaybackKit
import Foundation
import Observation

/// Readings you stopped part-way, kept so you can pick one up where you left off.
///
/// **This is a deliberate, argued exception to decision 1** (`specs/read-aloud.md`: readings are
/// not persisted), agreed with Anatoli rather than assumed. Resuming a long article genuinely
/// requires remembering what was being read, and the decision it narrows is shipped, documented in
/// Help and stated in the Settings pane, so the exception is written down in all three places
/// rather than quietly taken.
///
/// Three properties keep it defensible, and each answers one of the reasons decision 1 gave for
/// storing nothing:
///
/// 1. **Only redacted text is stored.** The chunks kept here are what `SpeakableText.prepare`
///    emitted, which is what was spoken. Redaction happens before synthesis, so a credential
///    never reached the speaker and cannot reach this file either. That is a property of where
///    the redactor sits, not a check performed here — and `speak_summary` writing raw text to a
///    `UserDefaults` history while speaking the redacted version is exactly the bug this design
///    avoids by construction.
/// 2. **Its own store, with its own cap.** Not `SpeechHistory`, whose 50 entries are the user's
///    spoken summaries: one long article would have evicted them. A separate file, five entries,
///    oldest dropped first.
/// 3. **A retention the user can see.** Entries expire after `retention`, enforced on every load
///    and every save, and the Settings pane says the number rather than leaving it implicit.
///
/// Kept out of `PreferenceSync` on purpose: this is per-device reading position, like podcast
/// progress, and syncing it would mean the text of what you were reading travelling between
/// machines. That was never agreed and is not what "resume" asks for.
///
/// **Not the Later tab**, which was the card's suggested home and does not fit. `PinnedItem` is
/// built around a server entity — `refID` resolves against Navidrome and `asSong` reconstructs a
/// `NavidromeSong` for the music controller. A reading has no server id, no artwork and does not
/// play through that controller at all. Putting one there would need a synthetic id and a
/// meaningless `asSong`, so readings resume from their own menu instead.
@MainActor
@Observable
final class UnfinishedReadings {

    /// One reading, stopped part-way.
    struct Entry: Codable, Equatable, Identifiable {
        let id: UUID
        /// The prepared, redacted chunks — the same strings that were spoken.
        var chunks: [String]
        /// How many chunks were finished. Resuming starts at this index.
        var resumeIndex: Int
        /// Where the text came from, for the menu title. A reading has no title of its own.
        var sourceName: String?
        var startedAt: Date
        var updatedAt: Date

        /// What the menu shows. The source and how far in you were are the only two things
        /// actually known, so they are the only two things claimed.
        var menuTitle: String {
            let source = (sourceName?.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap { $0.isEmpty ? nil : $0 } ?? "Reading"
            let percent = chunks.isEmpty ? 0 : Int(Double(resumeIndex) / Double(chunks.count) * 100)
            return "\(source) — \(percent)% in"
        }
    }

    /// Five, not fifty. A reading is large (a whole article's text) and the use is "the thing I
    /// was in the middle of", not an archive.
    static let maximumEntries = 5
    /// How long an unfinished reading is kept. Stated to the user in Settings and in Help; a
    /// retention nobody can see is indistinguishable from keeping things forever.
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    private(set) var entries: [Entry] = []

    private let storeURL: URL
    private var loaded = false

    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("unfinished-readings.json")
    }

    private var store: VersionedStore<[Entry]> {
        VersionedStore(fileURL: storeURL, keepBackup: false)
    }

    // MARK: - Lifecycle

    func loadIfNeeded(now: Date = Date()) {
        guard !loaded else { return }
        loaded = true
        entries = store.load() ?? []
        // Expire on the way in as well as on the way out. A machine that was off for a fortnight
        // would otherwise show a stale reading in the menu until something else prompted a save.
        prune(now: now)
    }

    /// Record where a reading got to, replacing any earlier state for the same reading.
    ///
    /// A reading that finished, or never got past its first chunk, is not worth resuming and is
    /// removed rather than stored: "resume" on something you have not started is noise in a menu.
    func record(id: UUID, chunks: [String], resumeIndex: Int, sourceName: String?,
                startedAt: Date, now: Date = Date()) {
        loadIfNeeded(now: now)
        entries.removeAll { $0.id == id }
        guard resumeIndex > 0, resumeIndex < chunks.count else {
            persist()
            return
        }
        entries.insert(
            Entry(id: id, chunks: chunks, resumeIndex: resumeIndex,
                  sourceName: sourceName, startedAt: startedAt, updatedAt: now),
            at: 0
        )
        prune(now: now)
    }

    /// Drop one reading — it was resumed to the end, or the user cleared it.
    func remove(id: UUID, now: Date = Date()) {
        loadIfNeeded(now: now)
        entries.removeAll { $0.id == id }
        persist()
    }

    /// Forget every unfinished reading. Wired to the Settings button, so the promise that they
    /// can be cleared is something the user can act on rather than only read.
    func clear() {
        loaded = true
        entries = []
        try? FileManager.default.removeItem(at: storeURL)
    }

    // MARK: - Internals

    private func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.updatedAt) > Self.retention }
        if entries.count > Self.maximumEntries {
            entries = Array(entries.prefix(Self.maximumEntries))
        }
        persist()
    }

    private func persist() {
        _ = store.save(entries)
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Baton", isDirectory: true)
    }
}
