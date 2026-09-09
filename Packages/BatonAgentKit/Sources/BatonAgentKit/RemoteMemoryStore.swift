import Foundation
import BatonSubsonicKit
import BatonSubsonicModels
import Observation

/// The small set of things about its owner that Baton keeps between sessions.
///
/// Almost everything a music companion needs to "know you" is **not** memory —
/// it is already on the Navidrome server, current by definition: play counts,
/// ratings, likes, what you added last week. Copying that here would be building
/// a cache that goes stale and then lies. So this file holds only what the
/// server cannot answer:
///
/// - **Stated preferences and facts** — "no vocals while I'm working", "the
///   gothic playlists are my partner's", "'my trance' means the Classic Trance
///   ones". Each one carries the person's own words.
/// - **What the agent recently started**, per chat. Without it, "surprise me"
///   surprises you with the same three tracks every time, and nothing can notice
///   that this is the third time today.
/// - **When Baton last mentioned a fact about your listening**, so a remark like
///   "34th play this month" happens once rather than on plays 34, 35 and 36.
///
/// **Every stored sentence traces to something the person literally said** — the
/// `quote` is required, not optional. That is what makes "seems to like sad
/// music on Sundays" impossible to store rather than merely discouraged: there
/// is no field for an inference. Plain JSON in a readable file, because being
/// openable and legible is part of the promise, not a convenience.
///
/// `@Observable` because the phone now shows these, and a list that does not
/// refresh after a delete is how a working forget reads as a broken one. `@MainActor`
/// because this is where the mutable state is — and it is stated rather than left to the
/// compiler's non-`Sendable` check at each use site, which is what it rested on while the
/// attribute was stranded above a type inserted between it and this class.
/// Keep the attributes touching the declaration; a comment in between is what hid this.
@MainActor
@Observable
public final class RemoteMemoryStore {
    // MARK: Shapes

    public struct Entry: Codable, Equatable, Identifiable {
        public var id: Int
        /// `preference`, `fact`, `vocabulary`, or `dislike` — a label for the
        /// reader, not a switch anything branches on.
        public var kind: String
        /// One line, in Baton's words, of what this means.
        public var text: String
        /// What the person actually said. Required.
        public var quote: String
        public var created: Date
        public var lastApplied: Date?
    }

    struct Pick: Codable, Equatable {
        var what: String
        var when: Date
    }

    private struct Contents: Codable {
        var version = 1
        var entries: [Entry] = []
        var recentPicks: [String: [Pick]] = [:]
        /// Trigger name → when Baton last said it. See `mayMention`.
        var lastMentioned: [String: Date] = [:]
    }

    /// Past this, the oldest-applied entries stop being rendered. A companion
    /// that recites thirty rules at itself before every answer is not using
    /// memory, it is drowning in it.
    static let renderLimit = 20
    /// Hard cap on what's kept at all.
    static let entryLimit = 30
    /// How many recent picks to keep per chat.
    static let pickLimit = 8
    /// A friend mentions the play count once and lets it go.
    static let mentionInterval: TimeInterval = 24 * 60 * 60

    // MARK: State

    private var contents = Contents()
    private let url: URL?
    private let store: VersionedStore<Contents>?

    public var entries: [Entry] { contents.entries }

    /// Whether the last write to disk actually landed.
    ///
    /// `save()` returned `Void` and could not fail, so the router said "Noted, remembered" whether
    /// or not anything had been written, and the only symptom of a full or read-only disk was a
    /// friend that seemed to forget everything (S-F2). Additive rather than a changed return type
    /// on `remember`, so nothing built on this class's API has to move.
    public private(set) var lastWriteSucceeded = true

    /// Whether the file could be read at startup. `false` means it was unreadable and has been
    /// preserved aside, so this object's state is not what the device holds.
    public private(set) var lastLoadSucceeded = true

    /// `url: nil` keeps everything in memory — what the tests use, and what a
    /// caller gets if the support directory is unwritable.
    public init(url: URL? = RemoteMemoryStore.defaultURL(),
                defaults: UserDefaults = FriendLedgerStore.defaultDefaults()) {
        self.url = url
        // `keepBackup: true` because this is irreplaceable: the person said these sentences, and
        // nothing can re-derive them. See `VersionedStore` for what the envelope buys.
        self.store = url.map {
            VersionedStore<Contents>(fileURL: $0, currentVersion: 1, keepBackup: true,
                                     encoder: .remoteMemory, decoder: .remoteMemory,
                                     log: remoteLog)
        }
        self.defaults = defaults
        load()
    }

    /// Where the shared, merged view lives. Injectable so tests never touch the real one.
    private let defaults: UserDefaults
    /// True only while `adoptLedger` is writing what the ledger already says.
    private var isAdopting = false

    /// Ledger keys the owner actually asked to forget, waiting to be turned into tombstones by
    /// the next publish. See `publishToLedger` for why an absence is not enough.
    private var pendingRemovals: Set<String> = []

    // MARK: Remembering

    /// Store something the person said. `quote` is required and must be
    /// non-empty — a memory with no source is exactly what this store exists to
    /// prevent.
    @discardableResult
    public func remember(kind: String, text: String, quote: String, now: Date = Date()) -> Entry? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !quote.isEmpty else { return nil }

        // Same gist twice is a correction, not a second memory.
        contents.entries.removeAll { $0.text.caseInsensitiveCompare(text) == .orderedSame }

        let entry = Entry(
            id: (contents.entries.map(\.id).max() ?? 0) + 1,
            kind: kind.isEmpty ? "preference" : kind,
            text: text, quote: quote, created: now, lastApplied: nil
        )
        contents.entries.append(entry)
        contents.entries = Self.capped(contents.entries)
        save()
        return entry
    }

    @discardableResult
    public func forget(id: Int) -> Entry? {
        guard let index = contents.entries.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = contents.entries.remove(at: index)
        // Recorded, because the publish below can no longer infer a deletion from an absence.
        pendingRemovals.insert(FriendLedger.key(for: removed.text))
        save()
        return removed
    }

    public func forgetEverything() {
        for entry in contents.entries { pendingRemovals.insert(FriendLedger.key(for: entry.text)) }
        contents = Contents()
        save()
    }

    // MARK: What was recently played

    func recordPick(_ what: String, key: String, now: Date = Date()) {
        let what = what.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !what.isEmpty else { return }
        var picks = contents.recentPicks[key] ?? []
        picks.insert(Pick(what: what, when: now), at: 0)
        contents.recentPicks[key] = Array(picks.prefix(Self.pickLimit))
        save()
    }

    func recentPicks(key: String) -> [Pick] { contents.recentPicks[key] ?? [] }

    // MARK: Saying a thing once

    /// True when Baton hasn't made this kind of remark for a day. The cap lives
    /// here, in code, rather than in the prompt — a model cannot be trusted to
    /// keep a budget it can't see, and this is the difference between a friend
    /// mentioning something and software nagging.
    func mayMention(_ trigger: String, now: Date = Date()) -> Bool {
        guard let last = contents.lastMentioned[trigger] else { return true }
        return now.timeIntervalSince(last) >= Self.mentionInterval
    }

    func recordMention(_ trigger: String, now: Date = Date()) {
        contents.lastMentioned[trigger] = now
        save()
    }

    // MARK: Rendering for the model

    /// The block handed to the agent, or nil when there is nothing to say.
    public func rendered(now: Date = Date()) -> String? {
        // Take whatever the other device has told us before answering. Adopting on read
        // rather than at a call site is deliberate: the Mac keeps these stores inside
        // `RemoteCommandRouter`, well out of reach of the sync scheduler, so any explicit
        // hook would have to be threaded through the composition root and could be forgotten
        // by whoever adds the next surface. This cannot be forgotten, and it is idempotent —
        // it returns immediately and writes nothing when the ledger says what we already know.
        adoptLedger()

        guard !contents.entries.isEmpty else { return nil }
        let shown = contents.entries
            .sorted { ($0.lastApplied ?? $0.created) > ($1.lastApplied ?? $1.created) }
            .prefix(Self.renderLimit)
            .sorted { $0.id < $1.id }
        return "Things the owner has told you:\n"
            + shown.map { "- [\($0.id)] \($0.text)" }.joined(separator: "\n")
    }

    /// Human-facing listing for the `memories` command.
    func listing() -> String {
        guard !contents.entries.isEmpty else {
            return "I'm not keeping anything yet. Tell me something like “remember I don't want vocals while I work”."
        }
        let rows = contents.entries.map { entry in
            "*\(entry.id).* \(entry.text)\n    _you said: “\(entry.quote)”_"
        }
        return rows.joined(separator: "\n") + "\n\n`forget <number>` removes one, `forget everything` clears them all."
    }

    // MARK: Persistence

    /// Re-read the file, for when something wrote it underneath this object — which means
    /// a settings import replacing it after launch.
    public func reload() { load() }

    private func load() {
        guard let store else { lastLoadSucceeded = true; return }
        let result = store.loadWithOutcome()
        // A quarantined file is the dangerous case and the one that had no branch at all: both
        // `try?` swallowed, `contents` stayed empty, and the next mutation replaced the good file
        // with an empty one and told the other device every memory had been deleted (S-F2). The
        // deletion half is now impossible by construction — see `publishToLedger` — and this flag
        // is the second layer: a store that could not read its own file has nothing trustworthy
        // to say about what this device holds.
        lastLoadSucceeded = result.outcome != .quarantined
        guard let decoded = result.payload else { return }
        contents = decoded
        // Enforce the cap here rather than only on write. `entryLimit` is the bound the prompt
        // rests on, and it was applied in `remember` alone — so a file arriving from a settings
        // import (`SettingsTransfer` ships this file wholesale) went into the system prompt at
        // whatever size it happened to be (S-F18). In memory only: writing on load would mean a
        // launch that mutates the file before the owner has done anything.
        contents.entries = Self.capped(contents.entries)
    }

    /// The newest `entryLimit` entries, ordered by id as the rest of the class expects.
    ///
    /// One function so `load`, `remember` and `adoptLedger` cannot disagree about which entries a
    /// trim drops. The three had the same six lines written out three times.
    private static func capped(_ entries: [Entry]) -> [Entry] {
        guard entries.count > entryLimit else { return entries }
        // Drop what has gone longest without being useful.
        var kept = entries.sorted { ($0.lastApplied ?? $0.created) < ($1.lastApplied ?? $1.created) }
        kept.removeFirst(kept.count - entryLimit)
        return kept.sorted { $0.id < $1.id }
    }

    @discardableResult
    private func save() -> Bool {
        // Write first, publish second. The old order published and then wrote, so a state that
        // failed to persist was still announced to the other device as this device's truth.
        guard let store else {
            // In-memory store (tests, or an unwritable support directory). There is nothing to
            // fail, and the ledger half still has to work.
            lastWriteSucceeded = true
            if !isAdopting { publishToLedger() }
            return true
        }
        let written = store.save(contents)
        lastWriteSucceeded = written
        guard written else {
            // A companion that can't write a note is still a companion; losing the file must
            // never take the conversation down with it. `VersionedStore.save` has already logged
            // why, and `lastWriteSucceeded` is what the router reads.
            return false
        }
        // The file on disk is now exactly what this object holds, whatever the load said.
        lastLoadSucceeded = true
        // Publish beside every save rather than at each call site: a mutation added later
        // cannot forget to, which is exactly how a ledger quietly stops matching its store.
        // Guarded against re-entry because `adoptLedger` saves too, and publishing what we
        // just adopted would restate every record and start a push ping-pong.
        if !isAdopting { publishToLedger() }
        return true
    }

    // MARK: - Crossing devices

    /// This store's half of the shared ledger, read live from `UserDefaults`.
    ///
    /// Computed rather than cached, deliberately: `PreferenceSync` writes the merged result
    /// straight into defaults, and a cached copy would be stale from that moment — which is
    /// the defect this repo spent 2026-09-07 fixing in four other places. `ClippingStore`
    /// does the same thing for the same reason.
    private var ledger: FriendLedger {
        get { FriendLedger.decode(defaults.data(forKey: FriendLedger.storageKey)) ?? .init() }
        set { defaults.set(newValue.encoded(), forKey: FriendLedger.storageKey) }
    }

    /// Record the current entries in the ledger, so the other device can see them.
    ///
    /// Called after every change. A memory the owner **forgot** becomes a tombstone rather than
    /// simply disappearing: an absence is indistinguishable from "this device never heard about
    /// it", so without a record a forget would be undone by the other device pushing the memory
    /// straight back.
    ///
    /// **Only a recorded forget tombstones.** This used to tombstone every ledger record with no
    /// matching live entry, which reads as "publish the truth" and is not: an absence has at
    /// least three causes, and only one of them is a deletion. A file that failed to load left
    /// the store empty and tombstoned everything, for 180 days, on the other device too. A local
    /// capacity trim tombstoned whatever it dropped, broadcasting a decision about this device's
    /// prompt budget as the owner deleting a memory (S-F2, S-F18).
    ///
    /// So `forget`, `forgetEverything` and nothing else put a key in `pendingRemovals`, and this
    /// consumes it. A record that is simply absent is now left exactly as it is, which is
    /// recoverable: the next `adoptLedger` brings it back.
    func publishToLedger(now: Date = Date()) {
        guard lastLoadSucceeded else {
            remoteLog.error("""
                not publishing the friend's memories: this device could not read its own store, \
                so it has nothing trustworthy to say about them.
                """)
            return
        }
        var ledger = self.ledger
        let live = Dictionary(contents.entries.map { (FriendLedger.key(for: $0.text), $0) },
                              uniquingKeysWith: { _, latest in latest })

        var records: [String: FriendLedger.Memory] = [:]
        for record in ledger.memories { records[record.key] = record }

        for (key, entry) in live {
            let existing = records[key]
            // Unchanged and already live: leave the timestamp alone, or every save would
            // restate everything and the two devices would push at each other forever.
            if let existing, !existing.removed, existing.text == entry.text,
               existing.kind == entry.kind, existing.quote == entry.quote {
                continue
            }
            records[key] = FriendLedger.Memory(
                key: key, text: entry.text, kind: entry.kind, quote: entry.quote,
                created: entry.created, removed: false, removedAt: nil, statedAt: now)
        }

        for key in pendingRemovals {
            guard var record = records[key], !record.removed else { continue }
            record.removed = true
            record.removedAt = now
            record.statedAt = now
            records[key] = record
        }
        pendingRemovals.removeAll()

        ledger.memories = records.values.sorted { $0.key < $1.key }
        self.ledger = ledger
    }

    /// Adopt the merged ledger — what both devices now agree the friend has been told.
    ///
    /// Runs after a sync, beside `SearchRecents.reload()` and the clipping reconcile, for the
    /// identical reason: the merge lands in `UserDefaults` and this object holds a file.
    /// Returns true when anything actually changed, so a caller can avoid a pointless save.
    @discardableResult
    public func adoptLedger() -> Bool {
        let ledger = self.ledger
        guard !ledger.memories.isEmpty else { return false }

        var byKey = Dictionary(contents.entries.map { (FriendLedger.key(for: $0.text), $0) },
                               uniquingKeysWith: { _, latest in latest })
        var changed = false

        for record in ledger.memories {
            if record.removed {
                if byKey.removeValue(forKey: record.key) != nil { changed = true }
                continue
            }
            if var existing = byKey[record.key] {
                guard existing.text != record.text || existing.kind != record.kind
                        || existing.quote != record.quote else { continue }
                existing.text = record.text
                existing.kind = record.kind
                existing.quote = record.quote
                byKey[record.key] = existing
                changed = true
            } else {
                // Arriving from the other device. The numeric id is local and is minted here;
                // it is never carried across, because both devices mint from their own
                // sequence and the same number means different things on each.
                let nextID = (byKey.values.map(\.id).max() ?? 0) + 1
                byKey[record.key] = Entry(id: nextID, kind: record.kind, text: record.text,
                                          quote: record.quote, created: record.created,
                                          lastApplied: nil)
                changed = true
            }
        }

        guard changed else { return false }
        isAdopting = true
        defer { isAdopting = false }
        contents.entries = Self.capped(byKey.values.sorted { $0.id < $1.id })
        save()
        return true
    }

    public static func defaultURL() -> URL? {
        BatonStorage.supportDirectory().appendingPathComponent("remote-memory.json")
    }
}

/// Where the shared friend ledger lives by default.
///
/// A throwaway suite under XCTest, never `.standard` — the same rule as
/// `MusicEqualizer.defaultStore` and the in-memory Keychain. Without it,
/// adopting on read would pull the developer's own friend memory into every test that
/// constructs one of these stores, and write back to it.
public enum FriendLedgerStore {
    /// `redirect` is a parameter only so a test can resolve the probe branch without being
    /// launched as a probe; every caller in the app takes the default.
    public static func defaultDefaults(environment: BatonEnvironment = .current,
                                       redirect: BatonStorage.Redirect = BatonStorage.current) -> UserDefaults {
        // A probe launch first, because it outranks both of the cases below: the point of one is
        // that the *shipping* app runs normally against throwaway storage, so it is neither a test
        // run nor the owner's real domain. Sharing this one line with `PreferenceSync` is what
        // makes the two halves of friend sync land in the same place by construction rather than
        // by two call sites agreeing.
        if redirect.isActive { return BatonStorage.resolvedDefaults(for: redirect) }
        guard environment.isTesting else { return .standard }
        return UserDefaults(suiteName: "io.tonebox.tests.friendledger.\(UUID().uuidString)") ?? .standard
    }
}

private extension JSONEncoder {
    /// Readable on purpose: the file being openable is part of the promise.
    static var remoteMemory: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var remoteMemory: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
