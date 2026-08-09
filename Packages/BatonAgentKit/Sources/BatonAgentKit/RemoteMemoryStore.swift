import Foundation
import BatonSubsonicKit
import BatonSubsonicModels

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
@MainActor
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

    public var entries: [Entry] { contents.entries }

    /// `url: nil` keeps everything in memory — what the tests use, and what a
    /// caller gets if the support directory is unwritable.
    public init(url: URL? = RemoteMemoryStore.defaultURL()) {
        self.url = url
        load()
    }

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
        if contents.entries.count > Self.entryLimit {
            // Drop what has gone longest without being useful.
            contents.entries.sort { ($0.lastApplied ?? $0.created) < ($1.lastApplied ?? $1.created) }
            contents.entries.removeFirst(contents.entries.count - Self.entryLimit)
            contents.entries.sort { $0.id < $1.id }
        }
        save()
        return entry
    }

    @discardableResult
    public func forget(id: Int) -> Entry? {
        guard let index = contents.entries.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = contents.entries.remove(at: index)
        save()
        return removed
    }

    public func forgetEverything() {
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

    private func load() {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.remoteMemory.decode(Contents.self, from: data)
        else { return }
        contents = decoded
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.remoteMemory.encode(contents)
            try data.write(to: url, options: .atomic)
        } catch {
            // A companion that can't write a note is still a companion; losing
            // the file must never take the conversation down with it.
            remoteLog.error("Couldn't save remote memory: \(error.localizedDescription, privacy: .public)")
        }
    }

    public static func defaultURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return base
            .appendingPathComponent("Baton", isDirectory: true)
            .appendingPathComponent("remote-memory.json")
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
