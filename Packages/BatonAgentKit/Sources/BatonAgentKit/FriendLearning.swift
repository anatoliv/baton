import Foundation
import OSLog

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
        return "- When they asked \"\(request)\":\(did) That was wrong — \(complaint)."
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
@MainActor
public final class FriendLearningStore {
    /// Deliberately small. Twelve lines is enough to carry real corrections and short
    /// enough that it cannot quietly become the majority of the system prompt.
    public static let maxCorrections = 12

    private let url: URL
    public private(set) var corrections: [FriendCorrection] = []

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

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        load()
    }

    private static func defaultURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base.appendingPathComponent("Baton", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("music-friend-learned.json")
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
            // actually saying what they meant.
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
        corrections.removeAll { $0.request.caseInsensitiveCompare(exchange.request) == .orderedSame }
        if corrections.count != before { save() }
    }

    public func forget(_ id: UUID) {
        corrections.removeAll { $0.id == id }
        save()
    }

    public func forgetAll() {
        corrections = []
        save()
    }

    /// The block appended to the system prompt, or nil when there is nothing to say.
    ///
    /// Framed as history rather than law, and explicitly *not* a list of bans: a model
    /// handed "never play X" will refuse X in situations where X was exactly right.
    public var promptBlock: String? {
        guard !corrections.isEmpty else { return nil }
        return """
        THINGS YOU GOT WRONG BEFORE, in this person's judgement. Treat them as evidence \
        about what they mean, not as rules to obey:
        \(corrections.map(\.promptLine).joined(separator: "\n"))
        """
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url) else {
            friendLog.error("could not read \(self.url.lastPathComponent, privacy: .public)")
            return
        }
        guard
              let decoded = try? JSONDecoder().decode([FriendCorrection].self, from: data)
        else {
            // Move it aside rather than over it. Decoding to empty and then saving on the
            // next mutation is how a corrupt file becomes a deleted one.
            let quarantine = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: quarantine)
            try? FileManager.default.moveItem(at: url, to: quarantine)
            friendLog.error("\(self.url.lastPathComponent, privacy: .public) would not decode — moved aside")
            return
        }
        corrections = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(corrections).write(to: url, options: .atomic)
        } catch {
            // A silently failing write loses every rating since the last good one, and the
            // only symptom is a feature that seems not to learn.
            friendLog.error("could not save \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
