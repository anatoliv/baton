import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import Observation

/// What the music friend has learned from being told it was wrong.
///
/// This is the part that has to be handled carefully, so the constraints are stated before
/// the code.
///
/// `RemoteMemoryStore` holds a rule: every stored sentence traces to something the person
/// literally said, and there is no field for an inference. That rule is why "seems to like
/// sad music on Sundays" cannot be stored there rather than merely being discouraged. This
/// type inherits it. A rating is not an inference — it is an explicit act, about one
/// exchange, at a known moment — so every correction here carries the request that produced
/// it and the date it was rated. **A correction that cannot cite its exchange is not
/// stored.**
///
/// Three further limits, each of which exists because a system that learns can learn the
/// wrong thing:
///
/// - **Only explicit ratings.** Never "you skipped it", never "you asked again". Implicit
///   signals are exactly where a recommender starts inventing a person.
/// - **Visible and deletable.** A learned rule you cannot see is one you cannot correct.
///   They are listed in the log screen with their source, and removing one is a tap.
/// - **Bounded.** A prompt that grows without limit eventually crowds out the instructions
///   that make the agent work at all, and does so silently.
public struct FriendCorrection: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    /// What the person asked, verbatim — the quote this correction rests on.
    public var request: String
    /// What went wrong, in their words when they gave them.
    public var note: String?
    public var fault: FriendExchange.Fault
    public var date: Date
    /// The exchange this came from, so the claim can always be traced back.
    public var exchangeID: UUID
    /// What the friend actually did — the search it ran, the track it started. Without
    /// this a correction says "that was wrong" and nothing else, which gives a model
    /// nothing to update on: same request, same priors, one slot burned.
    public var resolution: String

    public init(id: UUID = UUID(), request: String, note: String?, fault: FriendExchange.Fault,
                date: Date, exchangeID: UUID, resolution: String = "") {
        self.id = id
        self.request = request
        self.note = note
        self.fault = fault
        self.date = date
        self.exchangeID = exchangeID
        self.resolution = resolution
    }

    /// One line for the prompt. Written as a fact about a past exchange rather than a rule,
    /// because a rule invites over-application: "when I said X you did the wrong thing" is
    /// something a model can weigh, while "never do Y" is something it obeys too eagerly.
    public var promptLine: String {
        let complaint = note.map { "they said: \"\($0)\"" } ?? faultPhrase
        let did = resolution.isEmpty ? "" : " You \(resolution)."
        return "- When they asked \"\(request)\":\(did) That was wrong: \(complaint)."
    }

    private var faultPhrase: String {
        switch fault {
        case .wrongTrack: "it understood them but played the wrong thing"
        case .misunderstood: "it misunderstood what they meant"
        case .tooSlow: "it took too long"
        case .tooChatty: "it said far more than they wanted"
        }
    }
}

/// The corrections, on disk, bounded and inspectable.
///
/// `@Observable` for the same reason as `RemoteMemoryStore`: `FriendLogView` has shown these
/// with a swipe-to-delete since it was written, and nothing told the list the array had
/// changed — so the row stayed on screen until the sheet was reopened.
@MainActor
@Observable
public final class FriendLearningStore {
    /// Deliberately small. Twelve lines is enough to carry real corrections and short
    /// enough that it cannot quietly become the majority of the system prompt.
    public static let maxCorrections = 12

    private let url: URL
    private let store: VersionedStore<[FriendCorrection]>
    public private(set) var corrections: [FriendCorrection] = []

    /// Whether the last write to disk actually landed, and whether the last read did.
    ///
    /// Additive rather than a changed return type on `learn`, so nothing built on this class has
    /// to move. `save()` returned `Void` and could not fail (S-F2).
    public private(set) var lastWriteSucceeded = true
    public private(set) var lastLoadSucceeded = true

    /// Where a rating that carries the person's *words* goes instead of here.
    ///
    /// "I meant Classic Trance" is not a complaint, it is a statement of what they mean —
    /// which is exactly what `RemoteMemoryStore` already holds, with quote provenance, its
    /// own caps, its own rendering and a `memories`/`forget` UX people already know. Storing
    /// it here as well would be a second memory store with weaker semantics, and it reads to
    /// a model as a rap sheet rather than as guidance.
    ///
    /// So the two split by what the data *is*: words become memory, and a fault with no
    /// words stays here as evidence — "you played X and that was wrong" — which memory has
    /// no field for and could not express without inventing one.
    public var memory: RemoteMemoryStore?

    public init(url: URL? = nil,
                defaults: UserDefaults = FriendLedgerStore.defaultDefaults()) {
        let fileURL = url ?? Self.defaultURL()
        self.url = fileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // `keepBackup: true`: a correction is something the owner took the trouble to give, and
        // nothing can re-derive it.
        self.store = VersionedStore<[FriendCorrection]>(
            fileURL: fileURL, currentVersion: 1, keepBackup: true,
            encoder: encoder, log: friendLog)
        self.defaults = defaults
        load()
    }

    /// Where the shared, merged view lives. Injectable so tests never touch the real one.
    private let defaults: UserDefaults
    /// True only while `adoptLedger` is writing what the ledger already says.
    private var isAdopting = false

    /// Ledger keys for corrections this device deliberately dropped — retired, forgotten, or
    /// superseded by the owner's own words — waiting to become tombstones on the next publish.
    private var pendingRemovals: Set<String> = []

    // MARK: - Crossing devices

    /// This store's half of the shared ledger, read live from `UserDefaults` — never cached,
    /// because `PreferenceSync` writes the merged result there and a cached copy would be
    /// stale from that instant.
    private var ledger: FriendLedger {
        get { FriendLedger.decode(defaults.data(forKey: FriendLedger.storageKey)) ?? .init() }
        set { defaults.set(newValue.encoded(), forKey: FriendLedger.storageKey) }
    }

    /// Record the current corrections, turning a **retired** one into a tombstone.
    ///
    /// The tombstone is the whole point here. `retireIfApproved` deletes a correction when the
    /// friend later gets that request right, and a deletion that leaves no trace cannot be told
    /// from "this device never had it" — so the other device would push the complaint straight
    /// back and the friend would go on being corrected about something it has fixed.
    ///
    /// **Only a recorded retirement or deletion tombstones**, for the reason spelled out on
    /// `RemoteMemoryStore.publishToLedger`: this used to tombstone anything the ledger held and
    /// this store did not, and an absence has several causes of which deletion is one. A failed
    /// load and a local capacity trim both produced absences, and both were broadcast as the
    /// owner deleting a correction (S-F2, S-F18).
    func publishToLedger(now: Date = Date()) {
        guard lastLoadSucceeded else {
            friendLog.error("""
                not publishing the friend's corrections: this device could not read its own \
                store, so it has nothing trustworthy to say about them.
                """)
            return
        }
        var ledger = self.ledger
        let live = Dictionary(corrections.map { (FriendLedger.key(for: $0.request), $0) },
                              uniquingKeysWith: { _, latest in latest })

        var records: [String: FriendLedger.Correction] = [:]
        for record in ledger.corrections { records[record.key] = record }

        for (key, correction) in live {
            let existing = records[key]
            if let existing, !existing.removed, existing.request == correction.request,
               existing.note == correction.note, existing.resolution == correction.resolution,
               existing.fault == correction.fault.rawValue {
                continue
            }
            records[key] = FriendLedger.Correction(
                key: key, request: correction.request, note: correction.note,
                fault: correction.fault.rawValue, resolution: correction.resolution,
                date: correction.date, removed: false, removedAt: nil, statedAt: now)
        }

        for key in pendingRemovals {
            guard var record = records[key], !record.removed else { continue }
            record.removed = true
            record.removedAt = now
            record.statedAt = now
            records[key] = record
        }
        pendingRemovals.removeAll()

        ledger.corrections = records.values.sorted { $0.key < $1.key }
        self.ledger = ledger
    }

    /// Adopt the merged ledger — what both devices now agree the friend got wrong.
    ///
    /// A retirement recorded on the other device removes the correction here, which is the
    /// answer to the question TBX-5125 raised: a retirement *is* a statement the other device
    /// should adopt, because it means the friend demonstrably got that request right, and
    /// that is a fact about the friend rather than about the device that observed it.
    @discardableResult
    public func adoptLedger() -> Bool {
        let ledger = self.ledger
        guard !ledger.corrections.isEmpty else { return false }

        var byKey = Dictionary(corrections.map { (FriendLedger.key(for: $0.request), $0) },
                               uniquingKeysWith: { _, latest in latest })
        var changed = false

        for record in ledger.corrections {
            if record.removed {
                if byKey.removeValue(forKey: record.key) != nil { changed = true }
                continue
            }
            // A fault this build does not know is one a newer version of the other app added.
            // Skip it rather than substituting a fault we can invent: the correction's whole
            // value is telling the friend *what* it got wrong, and a guessed category would
            // put words in the user's mouth. Forward-compatible in the safe direction — the
            // record stays in the ledger and an updated build will pick it up.
            guard let fault = FriendExchange.Fault(rawValue: record.fault) else { continue }
            let incoming = FriendCorrection(
                request: record.request, note: record.note, fault: fault,
                date: record.date, exchangeID: byKey[record.key]?.exchangeID ?? UUID(),
                resolution: record.resolution)
            if let existing = byKey[record.key],
               existing.request == incoming.request, existing.note == incoming.note,
               existing.resolution == incoming.resolution, existing.fault == incoming.fault {
                continue
            }
            byKey[record.key] = incoming
            changed = true
        }

        guard changed else { return false }
        isAdopting = true
        defer { isAdopting = false }
        corrections = byKey.values.sorted { $0.date > $1.date }
        if corrections.count > Self.maxCorrections {
            corrections.removeLast(corrections.count - Self.maxCorrections)
        }
        save()
        return true
    }

    private static func defaultURL() -> URL {
        BatonStorage.supportDirectory().appendingPathComponent("music-friend-learned.json")
    }

    /// Learn from a rated exchange. Returns nil when there is nothing legitimate to learn.
    ///
    /// Deliberately refuses three cases. A thumbs-up teaches nothing actionable — "that was
    /// right" does not say what to do differently. **Too slow** is not about understanding
    /// at all; no sentence in a prompt makes a model faster, and pretending otherwise puts
    /// noise where corrections should be. And a duplicate of a request already corrected
    /// would let one recurring annoyance crowd out eleven others.
    @discardableResult
    public func learn(from exchange: FriendExchange) -> FriendCorrection? {
        guard exchange.rating == .down else { return nil }

        // A thumbs-down over a chat bridge carries no fault — there are no buttons there —
        // but it very often carries words, and the words are the better evidence. Requiring
        // a fault meant every bridge rating was silently discarded: the store that reached a
        // model was permanently empty.
        let fault = exchange.fault ?? (exchange.note?.isEmpty == false ? .misunderstood : nil)
        guard let fault, fault != .tooSlow else { return nil }

        // Nothing to teach with. Without either a fault *category* or the person's own
        // words, the line reads "that was wrong" and gives the model nothing to change —
        // while occupying one of twelve slots for good.
        guard exchange.fault != nil || exchange.note?.isEmpty == false else { return nil }

        // Words go to memory, where guidance belongs, and nothing is stored here.
        if let note = exchange.note, !note.isEmpty, let memory {
            memory.remember(kind: "correction", text: guidance(from: exchange, note: note), quote: note)
            // Any older evidence-line about the same request is superseded by the person
            // actually saying what they meant. A real deletion, so it is recorded: without the
            // tombstone the other device pushes the superseded complaint straight back.
            recordRemovals(matching: exchange.request)
            corrections.removeAll { $0.request.caseInsensitiveCompare(exchange.request) == .orderedSame }
            save()
            return nil
        }

        // A newer correction for the same request replaces the older one rather than being
        // dropped. The first version kept the earliest, so a vague early complaint blocked
        // the later, better-explained one for ever.
        corrections.removeAll { $0.request.caseInsensitiveCompare(exchange.request) == .orderedSame }

        let correction = FriendCorrection(request: exchange.request, note: exchange.note,
                                          fault: fault, date: exchange.date, exchangeID: exchange.id,
                                          resolution: exchange.resolution)
        corrections.insert(correction, at: 0)
        if corrections.count > Self.maxCorrections {
            corrections.removeLast(corrections.count - Self.maxCorrections)
        }
        save()
        return correction
    }

    /// Their words, phrased as something the friend should know rather than as a scolding.
    private func guidance(from exchange: FriendExchange, note: String) -> String {
        "When they ask \"\(exchange.request)\", they mean: \(note)"
    }

    /// A later approval of the same request retires the correction.
    ///
    /// Without this nothing ever expires: a correction that made sense once applies for
    /// ever, including after the thing it complained about has been fixed. An up-rating on
    /// the same words is the person saying so.
    public func retireIfApproved(_ exchange: FriendExchange) {
        guard exchange.rating == .up else { return }
        let before = corrections.count
        recordRemovals(matching: exchange.request)
        corrections.removeAll { $0.request.caseInsensitiveCompare(exchange.request) == .orderedSame }
        if corrections.count != before { save() }
    }

    public func forget(_ id: UUID) {
        if let going = corrections.first(where: { $0.id == id }) {
            pendingRemovals.insert(FriendLedger.key(for: going.request))
        }
        corrections.removeAll { $0.id == id }
        save()
    }

    public func forgetAll() {
        for correction in corrections { pendingRemovals.insert(FriendLedger.key(for: correction.request)) }
        corrections = []
        save()
    }

    /// Note that every correction about `request` is about to be deleted on purpose, so the next
    /// publish can tell this apart from a correction that is merely absent.
    private func recordRemovals(matching request: String) {
        for correction in corrections
        where correction.request.caseInsensitiveCompare(request) == .orderedSame {
            pendingRemovals.insert(FriendLedger.key(for: correction.request))
        }
    }

    /// The block appended to the system prompt, or nil when there is nothing to say.
    ///
    /// Framed as history rather than law, and explicitly *not* a list of bans: a model
    /// handed "never play X" will refuse X in situations where X was exactly right.
    public var promptBlock: String? {
        // Same reasoning as `RemoteMemoryStore.rendered`: adopt on read, so no surface has to
        // remember to, and idempotent so it costs nothing when nothing arrived.
        adoptLedger()

        guard !corrections.isEmpty else { return nil }
        return """
        THINGS YOU GOT WRONG BEFORE, in this person's judgement. Treat them as evidence \
        about what they mean, not as rules to obey:
        \(corrections.map(\.promptLine).joined(separator: "\n"))
        """
    }

    /// Re-read the file, for when something wrote it underneath this object.
    ///
    /// The case that matters is "Set up from a Mac": the import replaces this file and the
    /// object was built at launch, so without this the phone shows an empty friend beside a
    /// file full of corrections. Same shape as `AgentConfig.reload`.
    public func reload() { load() }

    private func load() {
        let result = store.loadWithOutcome()
        // `VersionedStore` does what this method used to do by hand — quarantine rather than
        // overwrite — and two things it did not: it keeps a `.bak` of the last good file, and it
        // refuses to write over a file from a newer build rather than downgrading it. The
        // hand-rolled version also lost the previous quarantine on each failure, so a second
        // corrupt file destroyed the evidence from the first (S-F2, S-F14).
        lastLoadSucceeded = result.outcome != .quarantined
        guard let decoded = result.payload else { return }
        // Capped here, not only in `learn`. The type doc promises the prompt is bounded, and
        // trimming lived on the write path alone — so a `music-friend-learned.json` arriving
        // through a settings import went into the system prompt at whatever size it was
        // (S-F18). In memory only: a launch must not rewrite the file before the owner acts.
        corrections = Array(decoded.prefix(Self.maxCorrections))
    }

    @discardableResult
    private func save() -> Bool {
        // Write first, publish second. The old order announced a state to the other device
        // before knowing whether this one had managed to keep it.
        let written = store.save(corrections)
        lastWriteSucceeded = written
        guard written else {
            // A silently failing write loses every rating since the last good one, and the
            // only symptom is a feature that seems not to learn. `VersionedStore.save` logs why.
            return false
        }
        lastLoadSucceeded = true
        // Beside every save, so a mutation added later cannot forget to publish. Guarded
        // against re-entry: `adoptLedger` saves too, and restating what we just adopted would
        // start a push ping-pong between the two devices.
        if !isAdopting { publishToLedger() }
        return true
    }
}
