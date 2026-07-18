import Foundation

/// Agent-native "build me a mix" tool — the differentiator no plain music player has.
/// An agent says "build me a 40-minute focus mix" and Baton assembles a track set of the
/// requested length from the connected Navidrome library, then queues it or saves it as a
/// playlist.
///
/// The selection math lives in a **pure** `MixBuilder` (no network, no player) so it's unit
/// testable; the tool handler just gathers candidate songs from the client and applies the
/// result. Kept in its own file so the mix logic stays out of the main tool catalog.
@MainActor
enum BatonMCPMixTools {
    // MARK: - Tool definition

    static func definition() -> [String: Any] {
        [
            "name": "music_build_mix",
            "description": """
            Build a mix of a target length from the connected music library and either queue \
            it for immediate playback or save it as a playlist. Agent-native: describe the \
            intent in `prompt` ("upbeat focus mix", "mellow jazz for the evening") and \
            optionally seed it with a specific artist or genre. Baton gathers candidate \
            tracks (matching the prompt/seed, plus your liked songs) and picks a set whose \
            total duration lands near `target_minutes`. Use action="queue" to play it now, \
            or action="playlist" (with `name`) to save it.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "prompt": ["type": "string", "description": "Free-text intent for the mix, e.g. 'upbeat focus mix' or 'mellow evening jazz'. A genre/mood keyword and any number of minutes are parsed from it."],
                    "target_minutes": ["type": "integer", "description": "Desired total length in minutes (default 45)."],
                    "seed_artist": ["type": "string", "description": "Bias the mix toward this artist (used to fetch similar songs / filter candidates)."],
                    "seed_genre": ["type": "string", "description": "Restrict the mix to this genre."],
                    "limit": ["type": "integer", "description": "Max candidate songs to gather before selecting (default 200, max 500)."],
                    "action": ["type": "string", "description": "'queue' (default) to play the mix now, or 'playlist' to save it (requires `name`)."],
                    "name": ["type": "string", "description": "Playlist name when action='playlist'."],
                ],
                "required": ["prompt"],
            ],
        ]
    }

    // MARK: - Handler

    static func run(_ args: [String: Any], _ music: MusicModel) async throws -> String {
        let prompt = try requireString(args, "prompt")
        let action = (optionalString(args, "action") ?? "queue").lowercased()
        let limit = min(max(optionalInt(args, "limit") ?? 200, 10), 500)

        // Prompt parsing is deliberately simple — the agent supplies the structure, Baton
        // just needs a target length and an optional genre/mood hint.
        let parsed = MixBuilder.parsePrompt(prompt)
        let targetMinutes = optionalInt(args, "target_minutes") ?? parsed.minutes ?? 45
        guard targetMinutes > 0 else {
            throw BatonMCPToolError(message: "target_minutes must be a positive number.")
        }
        let targetSeconds = targetMinutes * 60

        let seedArtist = optionalString(args, "seed_artist")
        let seedGenre = optionalString(args, "seed_genre") ?? parsed.genre
        let seed = MixBuilder.Seed(artist: seedArtist, genre: seedGenre, keywords: parsed.keywords)

        let client = try musicClient()
        let candidates = try await gatherCandidates(
            prompt: prompt, seed: seed, limit: limit, client: client
        )
        guard !candidates.isEmpty else {
            throw BatonMCPToolError(message: "Couldn't find any songs to build a mix from. Try a broader prompt or a different seed.")
        }

        let chosen = MixBuilder.buildMix(candidates: candidates, targetSeconds: targetSeconds, seed: seed)
        guard !chosen.isEmpty else {
            throw BatonMCPToolError(message: "No songs matched the seed for this mix.")
        }

        let totalSeconds = chosen.reduce(0) { $0 + ($1.duration ?? 0) }
        let totalMinutes = Int((Double(totalSeconds) / 60.0).rounded())
        let tracklist = chosen.prefix(50).map { song -> String in
            if let artist = song.artist, !artist.isEmpty { return "\(song.title) — \(artist)" }
            return song.title
        }

        switch action {
        case "playlist":
            let name = optionalString(args, "name")
                ?? mixName(seed: seed, minutes: targetMinutes)
            let playlist: NavidromePlaylist
            do {
                playlist = try await client.createPlaylist(name: name, songIDs: chosen.map(\.id))
                await music.musicLibrary.loadPlaylists()
            } catch { throw musicError(error) }
            return jsonText([
                "action": "playlist",
                "playlist_name": playlist.name,
                "playlist_id": playlist.id,
                "track_count": chosen.count,
                "total_minutes": totalMinutes,
                "target_minutes": targetMinutes,
                "tracklist": tracklist,
            ])
        case "queue":
            let label = mixName(seed: seed, minutes: targetMinutes)
            music.music.play(chosen, source: .init(label: label, kind: .radio, id: nil))
            return jsonText([
                "action": "queue",
                "mix": label,
                "track_count": chosen.count,
                "total_minutes": totalMinutes,
                "target_minutes": targetMinutes,
                "now_playing": BatonMCPToolCatalog.songJSON(chosen[0]),
                "tracklist": tracklist,
            ])
        default:
            throw BatonMCPToolError(message: "Unknown action \"\(action)\" — use 'queue' or 'playlist'.")
        }
    }

    // MARK: - Candidate gathering (network — kept out of the pure builder)

    /// Pull a candidate pool from every signal the seed/prompt gives us: an explicit
    /// genre, similar-songs off a seed artist, the free-text prompt search, and the
    /// user's liked songs. De-duplicated by id, capped at `limit`.
    private static func gatherCandidates(
        prompt: String,
        seed: MixBuilder.Seed,
        limit: Int,
        client: NavidromeClient
    ) async throws -> [NavidromeSong] {
        var pool: [NavidromeSong] = []
        var seen = Set<String>()
        func add(_ songs: [NavidromeSong]) {
            for song in songs where song.duration != nil && seen.insert(song.id).inserted {
                pool.append(song)
            }
        }

        do {
            if let genre = seed.genre {
                add(try await client.getSongsByGenre(genre, count: min(limit, 120)))
            }
            if let artist = seed.artist {
                // Seed similar songs off the artist's top search hit.
                if let hit = try await client.search3(query: artist, songCount: 1).songs.first {
                    add(try await client.getSimilarSongs(id: hit.id, count: 60))
                }
                add(try await client.search3(query: artist, songCount: 60).songs)
            }
            // Always fold in a prompt search + liked songs so the pool is never too thin.
            add(try await client.search3(query: prompt, songCount: min(limit, 60)).songs)
            add(try await client.getStarred2().songs)
        } catch {
            // If we already gathered something, work with it; otherwise surface the error.
            if pool.isEmpty { throw musicError(error) }
        }

        return Array(pool.prefix(limit))
    }

    private static func mixName(seed: MixBuilder.Seed, minutes: Int) -> String {
        if let genre = seed.genre { return "\(genre.capitalized) Mix · \(minutes) min" }
        if let artist = seed.artist { return "\(artist) Mix · \(minutes) min" }
        return "Mix · \(minutes) min"
    }

    // MARK: - Shared helpers (mirrors BatonMCPToolCatalog's private ones)

    private static func musicClient() throws -> NavidromeClient {
        do { return try NavidromeConfig.makeClient() } catch {
            throw BatonMCPToolError(message: "No music server is configured. Add one in Settings → Music.")
        }
    }

    private static func musicError(_ error: any Error) -> BatonMCPToolError {
        if let mcp = error as? BatonMCPToolError { return mcp }
        if let nav = error as? NavidromeError {
            return BatonMCPToolError(message: nav.errorDescription ?? "Music server error.")
        }
        return BatonMCPToolError(message: error.localizedDescription)
    }

    private static func requireString(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else {
            throw BatonMCPToolError(message: "Missing required argument '\(key)'.")
        }
        return value
    }

    private static func optionalString(_ args: [String: Any], _ key: String) -> String? {
        guard let value = args[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func optionalInt(_ args: [String: Any], _ key: String) -> Int? {
        if let i = args[key] as? Int { return i }
        if let n = args[key] as? NSNumber { return n.intValue }
        if let s = args[key] as? String { return Int(s) }
        return nil
    }

    private static func jsonText(_ object: [String: Any]) -> String {
        BatonMCPToolCatalog.jsonText(object)
    }
}

// MARK: - Pure mix-selection math (unit-tested, no network / no player)

/// The pure core of `music_build_mix`: prompt parsing + duration-aware track selection.
/// Everything here is deterministic given its inputs (aside from an optional shuffle of
/// equally-good candidates, which is seeded only when needed) so it can be exercised in
/// tests without a server.
enum MixBuilder {
    /// A parsed/explicit steer for the mix.
    struct Seed: Equatable {
        var artist: String?
        var genre: String?
        var keywords: [String] = []

        var isEmpty: Bool { artist == nil && genre == nil && keywords.isEmpty }
    }

    struct ParsedPrompt: Equatable {
        var minutes: Int?
        var genre: String?
        var keywords: [String]
    }

    /// Known genre/mood keywords we recognize in a free-text prompt. The agent normally
    /// supplies `seed_genre` directly; this is a best-effort fallback so a bare prompt
    /// like "build me a jazz mix" still steers.
    static let knownGenres: [String] = [
        "jazz", "rock", "pop", "classical", "hip hop", "hip-hop", "rap", "electronic",
        "house", "techno", "ambient", "folk", "country", "blues", "metal", "punk",
        "reggae", "soul", "funk", "disco", "indie", "r&b", "rnb", "latin", "lofi",
        "lo-fi", "chill", "acoustic", "instrumental", "dance",
    ]

    /// Extract a minute count + an optional genre/mood + residual keywords from a prompt.
    static func parsePrompt(_ prompt: String) -> ParsedPrompt {
        let lower = prompt.lowercased()

        // Minutes: "40 minute", "40-minute", "40 min", "40m", "for 40". Prefer a number
        // directly followed by a minute-ish token; otherwise the first plausible number.
        var minutes: Int?
        for token in tokenizeNumbers(lower) where (5 ... 600).contains(token.value) {
            if minutes == nil { minutes = token.value }
            if token.followedByMinuteToken { minutes = token.value; break }
        }

        let genre = knownGenres.first { lower.contains($0) }

        let keywords = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) && Int($0) == nil }

        return ParsedPrompt(minutes: minutes, genre: genre, keywords: keywords)
    }

    private static let stopwords: Set<String> = [
        "the", "for", "and", "build", "make", "give", "create", "some", "please",
        "mix", "playlist", "song", "songs", "track", "tracks", "minute", "minutes",
        "min", "long", "with", "that", "this", "want", "would", "like",
    ]

    /// Each run of digits in `text`, with a flag for whether a "minute"-ish token follows
    /// (immediately, or after a single space/hyphen) — enough to disambiguate "40 min"
    /// from an incidental number.
    private static func tokenizeNumbers(_ text: String) -> [(value: Int, followedByMinuteToken: Bool)] {
        var out: [(Int, Bool)] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i].isNumber else { i += 1; continue }
            var j = i
            while j < chars.count, chars[j].isNumber { j += 1 }
            let value = Int(String(chars[i ..< j])) ?? 0
            // Skip a single separator, then check for a leading 'm'.
            var k = j
            if k < chars.count, chars[k] == " " || chars[k] == "-" { k += 1 }
            let followed = k < chars.count && (chars[k] == "m" || chars[k] == "M")
            out.append((value, followed))
            i = j
        }
        return out.map { (value: $0.0, followedByMinuteToken: $0.1) }
    }

    /// Select songs whose total duration approximates `targetSeconds`, greedily filling
    /// toward the target without wildly overshooting.
    ///
    /// - Filters candidates by the seed (genre/artist) when one is present and any
    ///   candidate carries the needed metadata; otherwise the seed is a soft preference.
    /// - Adds tracks until adding the next one would overshoot the target by more than a
    ///   tolerance, preferring the arrangement that lands closest to the target.
    static func buildMix(
        candidates: [NavidromeSong],
        targetSeconds: Int,
        seed: Seed
    ) -> [NavidromeSong] {
        let usable = candidates.filter { ($0.duration ?? 0) > 0 }
        guard !usable.isEmpty, targetSeconds > 0 else { return [] }

        let filtered = applySeed(usable, seed: seed)
        let pool = filtered.isEmpty ? usable : filtered

        // De-dup by id (defensive; caller usually de-dups) and greedily fill.
        var seen = Set<String>()
        let ordered = pool.filter { seen.insert($0.id).inserted }

        // Overshooting by up to one average-track-length past the target is acceptable;
        // that lets the last track push us over the line rather than always stopping short.
        let avg = ordered.reduce(0) { $0 + ($1.duration ?? 0) } / max(ordered.count, 1)
        let overshootTolerance = max(avg, 30)

        var chosen: [NavidromeSong] = []
        var total = 0
        for song in ordered {
            let d = song.duration ?? 0
            if total >= targetSeconds { break }
            // Take the track if it fits, or if the running total is still short enough that
            // this track lands us closest to the target (within tolerance).
            if total + d <= targetSeconds + overshootTolerance {
                chosen.append(song)
                total += d
            }
            if total >= targetSeconds { break }
        }

        // Guarantee at least one track when the target is smaller than the shortest song.
        if chosen.isEmpty, let first = ordered.first { chosen.append(first) }
        return chosen
    }

    /// Restrict to songs matching the seed's genre/artist when the metadata allows it.
    /// If nothing matches (server didn't return genre on songs, say), returns empty so the
    /// caller falls back to the full pool.
    private static func applySeed(_ songs: [NavidromeSong], seed: Seed) -> [NavidromeSong] {
        guard !seed.isEmpty else { return songs }
        // Only the artist seed is a hard filter here — genre isn't carried on
        // NavidromeSong, so a genre seed is honored upstream at fetch time
        // (getSongsByGenre) rather than filtered on the song list.
        guard let artist = seed.artist?.lowercased() else { return songs }
        return songs.filter { $0.artist?.lowercased().contains(artist) ?? false }
    }
}
