import BatonSpeech
import Foundation
import Observation

/// A bounded, persisted history of spoken summaries sent through the `speak_summary` MCP tool, so
/// any past one can be replayed — not just the most recent. Each entry keeps the text, the resolved
/// voice (as `"engine:voice"`, e.g. `"kokoro:af_bella"`, or `nil` for the built-in system voice),
/// the engine actually used, an optional task category, and when it was spoken. Newest first,
/// capped at `maxEntries`. Persisted as JSON in `UserDefaults` (excluded from settings export as
/// session data).
@MainActor @Observable
final class SpeechHistoryStore {
    struct Entry: Identifiable, Codable, Equatable {
        let id: UUID
        let text: String
        /// Resolved voice as `"engine:voice"`; `nil` means the built-in system voice was used.
        let voice: String?
        /// Display label for the engine used: `"kokoro"`, `"chatterbox"`, or `"system"`.
        let engine: String
        let category: String?
        let date: Date
    }

    private(set) var entries: [Entry] = []

    static let maxEntries = 50
    static let key = "baton.speech.history"

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Record a spoken summary at the top of the history, trimming to `maxEntries`.
    func record(text: String, voice: String?, engine: String, category: String?) {
        let entry = Entry(id: UUID(), text: text, voice: voice, engine: engine, category: category, date: Date())
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// Re-synthesizes and plays a past spoken summary. Mirrors a fresh summary: synthesize the stored
/// text in the stored voice via the self-hosted server, and fall back to the built-in macOS voice
/// if that voice is unavailable or the server is unreachable — so Replay always produces sound.
enum SpeechSummaryReplay {
    @MainActor
    static func play(_ entry: SpeechHistoryStore.Entry, on engine: SpeechPlaybackEngine) async {
        let utterance: SpeechPlaybackEngine.Utterance
        if let voice = parseVoice(entry.voice),
           let audio = try? await SpeechService.synthesize(text: entry.text, voice: voice),
           let url = try? writeTemp(audio) {
            utterance = .file(url)
        } else {
            utterance = .native(entry.text)
        }
        engine.play(utterance, text: entry.text)
    }

    /// `"engine:voice"` → a `SpeechConfig.Voice`; `nil`/unparseable → `nil` (system voice).
    private static func parseVoice(_ string: String?) -> SpeechConfig.Voice? {
        guard let string else { return nil }
        let parts = string.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let engine = SpeechConfig.Engine(rawValue: parts[0].lowercased()) else { return nil }
        return SpeechConfig.Voice(engine: engine, voice: parts[1])
    }

    private static func writeTemp(_ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-speech", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }
}
