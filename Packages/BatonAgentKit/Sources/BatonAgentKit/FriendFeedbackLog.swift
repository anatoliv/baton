import Foundation
import OSLog

/// One subsystem for the whole app, shared by the feedback log and the
/// learning store so a failure in either reads the same in `log show`.
let friendLog = Logger(subsystem: "io.tonebox.baton", category: "MusicFriend")

/// What the music friend was asked, what it did about it, and what you thought.
///
/// The point is not a score. A thumbs-down on its own says "that was bad", which is
/// unactionable — the interesting question is *which part* was bad, and the four answers
/// point at four different fixes:
///
/// - **wrong track** — it understood you and chose badly. That is tool arguments or
///   library search, not the prompt.
/// - **misunderstood** — it heard something else entirely. That is the prompt.
/// - **too slow** — it was right and late. That is the model or the round trips.
/// - **too chatty** — it was right and buried it. That is the prompt, differently.
///
/// Every exchange also records what it *did*: which tools, with which arguments, and what
/// ended up playing. "It played the wrong thing" is impossible to act on a week later
/// without that; with it, the fix is usually obvious from reading three of them.
///
/// **On learning from this.** `RemoteMemoryStore` holds a rule that this file inherits
/// rather than works around: every stored sentence traces to something the person
/// literally said, and there is no field for an inference. A rating is not an inference —
/// it is an explicit act by the person, about a specific exchange, and it is stored with
/// the exchange it came from. So a correction derived here can always answer "why do you
/// believe that?" with a quote and a date. Anything that cannot is not stored.
public struct FriendExchange: Codable, Identifiable, Sendable, Equatable {
    /// Where the conversation happened. Ratings are worth comparing across these: the same
    /// question asked by voice on a phone and typed into Telegram are not the same question.
    public enum Surface: String, Codable, Sendable, CaseIterable {
        case phone, mac, watch, telegram, discord, mcp
    }

    /// Why a thumbs-down. Deliberately four, deliberately about *what went wrong* rather
    /// than how bad it was — a five-star scale would collect opinions instead of causes.
    public enum Fault: String, Codable, Sendable, CaseIterable {
        case wrongTrack, misunderstood, tooSlow, tooChatty

        public var label: String {
            switch self {
            case .wrongTrack: "Wrong track"
            case .misunderstood: "Misunderstood me"
            case .tooSlow: "Too slow"
            case .tooChatty: "Too chatty"
            }
        }
    }

    public enum Rating: String, Codable, Sendable { case up, down }

    /// One tool the agent invoked, and what it asked for. The arguments matter: "it played
    /// the wrong thing" is usually `music_search` with a query nobody would have typed.
    public struct Action: Codable, Sendable, Equatable {
        public var tool: String
        public var arguments: String
        public var succeeded: Bool
        /// The head of what the tool handed back — what the model was actually looking at.
        ///
        /// "Wrong track" cannot be diagnosed from the query alone. The interesting question
        /// is almost always what else was on the list: whether the right answer was sitting
        /// at position two and was passed over, or was never returned at all. Those are
        /// different bugs — one is the model choosing badly, the other is the library search
        /// — and without the candidates they are indistinguishable.
        public var candidates: String

        public init(tool: String, arguments: String, succeeded: Bool, candidates: String = "") {
            self.tool = tool
            self.arguments = arguments
            self.succeeded = succeeded
            self.candidates = candidates
        }
    }

    public var id: UUID
    public var date: Date
    public var surface: Surface
    /// Exactly what the person said, unedited. This is the quote every later claim rests on.
    public var request: String
    /// What the agent said back.
    public var reply: String
    public var actions: [Action]
    /// What actually ended up playing, if anything — titles, because ids age badly in a log
    /// a human is meant to read.
    public var played: [String]
    public var latency: TimeInterval
    public var model: String
    public var rating: Rating?
    public var fault: Fault?
    /// The person's own words about what went wrong, when they bother to type them. Optional,
    /// and worth more than everything else in the record when present.
    public var note: String?
    /// They skipped what the friend put on, almost immediately.
    ///
    /// The single best ground truth for a wrong track — far more common than a thumbs-down,
    /// because skipping is what people actually do when music is wrong. It is recorded and
    /// **never learned from**: `FriendLearningStore` stays blind to it deliberately.
    /// Implicit signals are exactly where a recommender starts inventing a person, and one
    /// skip can mean "wrong" or "heard it yesterday" or "the phone rang".
    public var skippedQuickly: Bool = false

    public init(id: UUID = UUID(), date: Date = Date(), surface: Surface, request: String,
                reply: String, actions: [Action] = [], played: [String] = [],
                latency: TimeInterval = 0, model: String = "", rating: Rating? = nil,
                fault: Fault? = nil, note: String? = nil, skippedQuickly: Bool = false) {
        self.id = id
        self.date = date
        self.surface = surface
        self.request = request
        self.reply = reply
        self.actions = actions
        self.played = played
        self.latency = latency
        self.model = model
        self.rating = rating
        self.fault = fault
        self.note = note
        self.skippedQuickly = skippedQuickly
    }

    /// A one-line summary of what it did, for the log screen.
    public var resolution: String {
        if !played.isEmpty {
            return "played " + played.prefix(3).joined(separator: ", ")
                + (played.count > 3 ? " +\(played.count - 3) more" : "")
        }
        if let first = actions.first {
            return actions.count == 1 ? first.tool : "\(first.tool) +\(actions.count - 1)"
        }
        return "answered"
    }
}

/// The rolling record of exchanges, on disk, readable by a person.
///
/// Local by default and capped: a log that grows without limit becomes a thing nobody opens
/// and eventually a privacy liability. Plain JSON for the same reason `RemoteMemoryStore`
/// uses it — being openable is part of the promise.
@MainActor
public final class FriendFeedbackLog {
    public static let defaultLimit = 500

    private let url: URL
    private let limit: Int
    public private(set) var exchanges: [FriendExchange] = []

    public init(url: URL? = nil, limit: Int = FriendFeedbackLog.defaultLimit) {
        self.limit = limit
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
        return folder.appendingPathComponent("music-friend-log.json")
    }

    /// Newest first — the order anyone reading a log actually wants.
    public func record(_ exchange: FriendExchange) {
        exchanges.insert(exchange, at: 0)
        if exchanges.count > limit { exchanges.removeLast(exchanges.count - limit) }
        save()
    }

    /// Rate an exchange after the fact, which is when people actually rate things: the
    /// track that was wrong is often only obviously wrong a verse later.
    @discardableResult
    public func rate(_ id: UUID, _ rating: FriendExchange.Rating,
                     fault: FriendExchange.Fault? = nil, note: String? = nil) -> Bool {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return false }
        exchanges[index].rating = rating
        exchanges[index].fault = rating == .down ? fault : nil
        // Only overwrite when there is something new to say: a bare re-rating used to erase
        // the words someone had typed, which are the most valuable part of the record.
        if let note, !note.isEmpty { exchanges[index].note = note }
        save()
        return true
    }

    /// How long after the friend started something counts as "they did not want that".
    ///
    /// Ten seconds is well short of any track and well past a mis-tap. Longer would collect
    /// ordinary skipping; shorter would miss the moment someone hears the first bar and
    /// reaches for the button.
    public static let quickSkipWindow: TimeInterval = 10

    /// Mark the most recent exchange as skipped, if it started something and it was recent.
    @discardableResult
    public func noteQuickSkip(now: Date = Date()) -> Bool {
        guard let index = exchanges.firstIndex(where: { !$0.played.isEmpty }),
              now.timeIntervalSince(exchanges[index].date) <= Self.quickSkipWindow + exchanges[index].latency
        else { return false }
        guard !exchanges[index].skippedQuickly else { return false }
        exchanges[index].skippedQuickly = true
        save()
        return true
    }

    /// Exchanges whose music was abandoned at once — where to look first for a wrong track,
    /// and usually a much bigger set than the ones anyone bothered to rate.
    public var quicklySkipped: [FriendExchange] { exchanges.filter(\.skippedQuickly) }

    public func clear() {
        exchanges = []
        save()
    }

    // MARK: - What the ratings say

    public var rated: [FriendExchange] { exchanges.filter { $0.rating != nil } }

    /// Counts by fault, worst first — the shape that answers "what should I fix next".
    public var faultTally: [(fault: FriendExchange.Fault, count: Int)] {
        Dictionary(grouping: exchanges.compactMap(\.fault), by: { $0 })
            .map { (fault: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url) else {
            friendLog.error("could not read \(self.url.lastPathComponent, privacy: .public)")
            return
        }
        guard
              let decoded = try? JSONDecoder().decode([FriendExchange].self, from: data)
        else {
            // Move it aside rather than over it. Decoding to empty and then saving on the
            // next mutation is how a corrupt file becomes a deleted one.
            let quarantine = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: quarantine)
            try? FileManager.default.moveItem(at: url, to: quarantine)
            friendLog.error("\(self.url.lastPathComponent, privacy: .public) would not decode — moved aside")
            return
        }
        exchanges = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(exchanges).write(to: url, options: .atomic)
        } catch {
            // A silently failing write loses every rating since the last good one, and the
            // only symptom is a feature that seems not to learn.
            friendLog.error("could not save \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
