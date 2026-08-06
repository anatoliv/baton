import Foundation
import BatonSubsonicKit
import BatonSubsonicModels

/// What the agent is allowed to see of a tool result, and what Baton adds to it.
///
/// Everything the model knows about the library arrives through here, so this is
/// where the two chronic problems get solved: results that are mostly noise, and
/// results that are silently cut in half.
///
/// Measured against a real library: one liked song serializes to 483 characters,
/// of which roughly half is `bit_rate_kbps`, `sampling_rate_hz`, `channels`,
/// `size_bytes`, `musicbrainz_id` and friends — none of which mean anything to a
/// conversation about music. At that size `music_liked` with its default of 40
/// songs came to 28,357 characters, so the 6,000-character budget admitted **12
/// songs and a fragment of the thirteenth**. Two thirds of the taste signal was
/// being thrown away before the model ever saw it, and the third that arrived
/// ended mid-object.
///
/// This is deliberately remote-only. An MCP client driving Baton from a script
/// may well want the bitrate; a chat agent never does.
@MainActor
public enum RemoteAgentResults {
    /// Per-song keys with no bearing on what to play or what to say about it.
    /// Dropping them roughly halves a song's serialized size.
    static let noiseKeys: Set<String> = [
        "bit_depth", "bit_rate_kbps", "bpm", "channels", "comment", "content_type",
        "format", "musicbrainz_id", "quality", "sampling_rate_hz", "size_bytes", "track",
    ]

    /// Arrays worth trimming when a result is too big, longest-first.
    private static let trimmableArrays = ["songs", "albums", "artists", "tracks", "playlists", "genres"]

    /// Shape a tool result for the model: strip the noise, then fit it to the
    /// budget by *dropping whole items* rather than cutting the string.
    ///
    /// The old behaviour was `String.prefix(6000)`, which hands the model a
    /// truncated JSON object and a note apologising for it. Trimming by item
    /// keeps the payload parseable at every size, and says plainly how many
    /// were left out — which the model can act on ("showing 26 of 65").
    static func shape(_ result: String, limit: Int = 6000) -> String {
        guard let data = result.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Not JSON — a plain sentence like "Music volume set to 70."
            return result.count > limit ? String(result.prefix(limit)) + "…" : result
        }

        json = stripNoise(from: json)

        // Rendering has to include the omission note, or adding it at the end
        // pushes the payload back over the budget.
        var dropped: [String: Int] = [:]
        func render(_ candidate: [String: Any]) -> String {
            guard !dropped.isEmpty else { return encode(candidate) }
            var withNote = candidate
            withNote["omitted"] = dropped
                .map { "\($0.value) more \($0.key)" }.sorted().joined(separator: ", ")
            return encode(withNote)
        }

        var rendered = render(json)
        while rendered.count > limit {
            guard let (key, items) = largestArray(in: json), items.count > 1 else { break }
            // Binary search the longest prefix that fits. Halving instead cost
            // six songs of taste signal on a real result — 20 where 26 fit.
            var low = 1, high = items.count - 1, best = 1
            while low <= high {
                let mid = (low + high) / 2
                var probe = json
                probe[key] = Array(items.prefix(mid))
                if render(probe).count <= limit {
                    best = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            dropped[key, default: 0] += items.count - best
            json[key] = Array(items.prefix(best))
            rendered = render(json)
        }

        // A single item can still exceed the budget on its own; only then does
        // the string get cut, and the note says so.
        return rendered.count > limit ? String(rendered.prefix(limit)) + "…(truncated)" : rendered
    }

    private static func stripNoise(from json: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in json {
            if let song = value as? [String: Any] {
                out[key] = stripNoise(from: song)
            } else if let list = value as? [[String: Any]] {
                out[key] = list.map { stripNoise(from: $0) }
            } else if !noiseKeys.contains(key) {
                out[key] = value
            }
        }
        return out
    }

    private static func largestArray(in json: [String: Any]) -> (String, [[String: Any]])? {
        trimmableArrays
            .compactMap { key -> (String, [[String: Any]])? in
                guard let items = json[key] as? [[String: Any]], !items.isEmpty else { return nil }
                return (key, items)
            }
            .max { $0.1.count < $1.1.count }
    }

    private static func encode(_ json: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}

// MARK: - What Baton adds to a result

extension RemoteAgentResults {
    /// A play count high enough to be worth a remark. Below this it's small
    /// talk; above it, it's something a friend would actually notice.
    static let notablePlayCount = 20

    /// Attach the facts Baton holds and the model can't see, at the moment they
    /// matter.
    ///
    /// Two behaviours the prompt could not buy live here:
    ///
    /// **Having a view.** Told in prose to "push back sometimes", a small model
    /// either never does or invents opinions it can't support. Told, in the
    /// result it is already reading, that this is the 34th play this month, it
    /// says so — grounded, once, in the same breath as doing what was asked.
    /// The remark never blocks: the music plays either way.
    ///
    /// **Offering instead of guessing.** `ask_choice` fired 0–3 times in 109
    /// messages while the prompt quoted the exact sentence that should trigger
    /// it, and a reply-keyword heuristic measured worse. The model is poor at
    /// noticing its own about-to-be-written sentence and reliable at reacting to
    /// a notice in a tool result — so the trigger moves into the result.
    ///
    /// Rate limiting is enforced here, in code, not asked for in the prompt: a
    /// friend mentions the play count once, software mentions it on plays 34,
    /// 35 and 36.
    static func annotate(
        _ result: String,
        tool: String,
        memory: RemoteMemoryStore,
        recentPicks: [RemoteMemoryStore.Pick] = [],
        now: Date = Date()
    ) -> String {
        guard let data = result.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return result }

        var notes: [String] = []

        switch tool {
        case "music_search":
            if let collision = duplicateArtistName(in: json) {
                notes.append(
                    "Two different artists here are both called \"\(collision)\" — genuinely "
                        + "different music. Offer the choice with ask_choice rather than picking one.")
            }

        case "music_play", "music_play_next", "music_queue_add", "music_play_playlist", "music_start_radio":
            if let playing = json["playing"] as? [String: Any] ?? json["now_playing"] as? [String: Any],
               let plays = playing["play_count"] as? Int, plays >= notablePlayCount,
               memory.mayMention("play_count", now: now) {
                memory.recordMention("play_count", now: now)
                let title = playing["title"] as? String ?? "this"
                notes.append(
                    "Worth a mention, once: \"\(title)\" has \(plays) plays — the owner's most "
                        + "worn-in track. Say so in passing; don't refuse or lecture, and don't "
                        + "repeat it in later replies.")
            }
            if let repeated = repeatedPick(json, in: recentPicks),
               memory.mayMention("repeat", now: now) {
                memory.recordMention("repeat", now: now)
                notes.append(
                    "This is at least the second time recently for \"\(repeated)\". Fine to "
                        + "mention lightly and offer something adjacent — but play what was asked.")
            }

        default:
            break
        }

        guard !notes.isEmpty else { return result }
        json["baton_note"] = notes.joined(separator: " ")
        guard let encoded = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8)
        else { return result }
        return text
    }

    /// Two artists whose names differ only by case — DIDO the trance producer
    /// and Dido the singer, in the library this was built against. A person
    /// asking for "dido" means one of them and Baton cannot tell which.
    private static func duplicateArtistName(in json: [String: Any]) -> String? {
        guard let artists = json["artists"] as? [[String: Any]] else { return nil }
        let names = artists.compactMap { $0["name"] as? String }
        var seen: [String: String] = [:]
        for name in names {
            let key = name.lowercased()
            if let first = seen[key], first != name { return name }
            seen[key] = name
        }
        return nil
    }

    private static func repeatedPick(_ json: [String: Any], in picks: [RemoteMemoryStore.Pick]) -> String? {
        guard let playing = json["playing"] as? [String: Any] ?? json["now_playing"] as? [String: Any],
              let title = playing["title"] as? String, !title.isEmpty
        else { return nil }
        return picks.contains { $0.what.localizedCaseInsensitiveContains(title) } ? title : nil
    }
}
