import BatonSubsonicModels
import Foundation
import OSLog

private let lyricsLog = Logger(subsystem: "io.tonebox.baton", category: "Lyrics")

/// Lyrics from LRCLIB, when the server has none.
///
/// Navidrome only serves lyrics that are embedded in the files, so for most libraries the
/// Lyrics panel is permanently empty — a whole feature that exists, works, and shows nothing.
/// LRCLIB is a free, open, no-account lyrics database with a plain HTTP API, and it returns
/// *synced* lyrics often enough to make the panel's scroll-along worth having.
///
/// Two deliberate limits:
///
/// - **Fallback only.** The server is asked first and its answer always wins. A library
///   owner who embedded lyrics in their files chose those, and a remote database has no
///   business overriding them.
/// - **Opt-in.** This sends a track title and artist to a third party. That is a small
///   disclosure and an obvious one for a lyrics feature, but it is still the first time this
///   app talks to anyone other than the user's own server, so it is a setting rather than an
///   assumption. Default off; the Lyrics panel offers it where the absence is felt.
///
/// ## Why there are two lookups
///
/// `/api/get` is an *exact* match on track name, artist name and duration, and real tags
/// almost never match a lyrics database exactly. A file tagged
/// `Wearing My Shoes (Louis Bailar's radio Chillout)` by `Aura feat. Dani Senior` 404s,
/// while LRCLIB holds the same recording as
/// `Wearing My Shoes (Louis Bailar's Chillout Radio Mix)` by `Aura`. A remix suffix and a
/// `feat.` are all it takes, and no amount of retagging fixes it for everyone else's library.
///
/// So the exact hop stays as the confident first answer, and a cleaned-up `/api/search` runs
/// behind it. Search is fuzzy on text, which is the point — but fuzzy is also how the wrong
/// sheet ends up scrolling against the right song, so a search hit is accepted only when the
/// candidate's *duration* is within a few seconds of the track actually playing. That is what
/// separates the 205-second radio mix from the 341-second club mix of the same title.
public enum LRCLIBLyrics {
    public static let enabledKey = "baton.lyrics.lrclib"

    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// How far a search candidate's duration may sit from the playing track's and still be
    /// believed to be the same recording. Tags and lyrics databases round differently, and
    /// LRCLIB stores fractional seconds, so this cannot be zero — but it has to stay small
    /// enough that two different mixes of one song never collide.
    static let durationTolerance: Double = 5

    /// Past this, a track is a set rather than a song: DJ mixes, radio shows, live
    /// recordings of a whole evening. Nobody writes lyrics for those, so looking them up
    /// only spends a request to be told what we already knew.
    static let lyriclessDurationSeconds = 20 * 60

    /// Whether this is the kind of track that has no lyrics to find in the first place.
    /// The panel uses it to say so plainly instead of showing the generic empty state after
    /// a lookup that was never going to succeed.
    public static func isLikelyLyricless(durationSeconds: Int?) -> Bool {
        guard let durationSeconds else { return false }
        return durationSeconds >= lyriclessDurationSeconds
    }

    /// Looks up lyrics by track metadata. Returns nil for anything less than a confident
    /// match — a wrong lyric sheet scrolling against the wrong song is worse than none.
    public static func lyrics(title: String,
                              artist: String?,
                              album: String?,
                              durationSeconds: Int?,
                              session: URLSession = .shared) async -> NavidromeLyrics? {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard !isLikelyLyricless(durationSeconds: durationSeconds) else {
            lyricsLog.debug("lrclib: skipping lookup, track is long enough to be a mix")
            return nil
        }

        if let exact = await exactMatch(title: title, artist: artist, album: album,
                                       durationSeconds: durationSeconds, session: session) {
            return exact
        }
        return await searchMatch(title: title, artist: artist,
                                 durationSeconds: durationSeconds, session: session)
    }

    // MARK: - The two hops

    /// `/api/get` — an exact match on the tags as they are. When it answers, it is right.
    private static func exactMatch(title: String,
                                   artist: String?,
                                   album: String?,
                                   durationSeconds: Int?,
                                   session: URLSession) async -> NavidromeLyrics? {
        var query = [URLQueryItem(name: "track_name", value: title)]
        if let artist, !artist.isEmpty { query.append(URLQueryItem(name: "artist_name", value: artist)) }
        if let album, !album.isEmpty { query.append(URLQueryItem(name: "album_name", value: album)) }
        // Duration lets LRCLIB reject a same-titled different recording. Sending it is the
        // difference between "a song called Bad" and "*this* song called Bad".
        if let durationSeconds, durationSeconds > 0 {
            query.append(URLQueryItem(name: "duration", value: String(durationSeconds)))
        }
        guard let data = await get("https://lrclib.net/api/get", query: query, session: session) else {
            return nil
        }
        return parse(data)
    }

    /// `/api/search` — fuzzy on cleaned-up text, then filtered back down by duration.
    ///
    /// Requires a duration: without one there is nothing to check a fuzzy hit against, and
    /// an unchecked fuzzy hit is exactly the wrong-sheet failure this whole function is
    /// arranged to avoid.
    private static func searchMatch(title: String,
                                    artist: String?,
                                    durationSeconds: Int?,
                                    session: URLSession) async -> NavidromeLyrics? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        let track = searchableTitle(title)
        guard !track.isEmpty else { return nil }
        let performer = artist.map(searchableArtist) ?? ""

        var query = [URLQueryItem(name: "track_name", value: track)]
        if !performer.isEmpty { query.append(URLQueryItem(name: "artist_name", value: performer)) }
        var results = await search(query, session: session)

        // Nothing under the structured query still leaves the free-text one, which weighs
        // the words together rather than field by field and sometimes finds what the split
        // could not.
        if results.isEmpty {
            let q = performer.isEmpty ? track : "\(track) \(performer)"
            results = await search([URLQueryItem(name: "q", value: q)], session: session)
        }
        return bestMatch(in: results, title: title, artist: artist, durationSeconds: durationSeconds)
    }

    private static func search(_ query: [URLQueryItem], session: URLSession) async -> [SearchResult] {
        guard let data = await get("https://lrclib.net/api/search", query: query, session: session) else {
            return []
        }
        return parseSearchResults(data)
    }

    private static func get(_ endpoint: String, query: [URLQueryItem], session: URLSession) async -> Data? {
        var components = URLComponents(string: endpoint)
        components?.queryItems = query
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        // LRCLIB asks clients to identify themselves; an anonymous flood is how free
        // services stop being free.
        request.setValue("Baton (https://baton.tonebox.io)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            // A lyrics lookup failing is not worth telling anyone about — the panel shows
            // its empty state, which is the same thing it showed a moment ago.
            lyricsLog.debug("lrclib lookup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Choosing among fuzzy hits

    struct SearchResult: Decodable {
        var trackName: String?
        var artistName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    static func parseSearchResults(_ data: Data) -> [SearchResult] {
        (try? JSONDecoder().decode([SearchResult].self, from: data)) ?? []
    }

    /// The closest candidate that agrees with the track on all three of title, artist and
    /// duration. Anything that fails one of those is dropped rather than ranked lower:
    /// second-best here means the wrong song's words.
    static func bestMatch(in results: [SearchResult],
                          title: String,
                          artist: String?,
                          durationSeconds: Int) -> NavidromeLyrics? {
        let wantTitle = normalized(searchableTitle(title))
        let wantArtist = artist.map { normalized(searchableArtist($0)) } ?? ""
        var best: (delta: Double, lyrics: NavidromeLyrics)?

        for result in results {
            // An instrumental record is a real answer — it just isn't lyrics.
            guard result.instrumental != true, let duration = result.duration else { continue }
            let delta = abs(duration - Double(durationSeconds))
            guard delta <= durationTolerance else { continue }
            guard agree(normalized(searchableTitle(result.trackName ?? "")), wantTitle) else { continue }
            if !wantArtist.isEmpty {
                guard agree(normalized(searchableArtist(result.artistName ?? "")), wantArtist) else { continue }
            }
            guard let lyrics = lyrics(synced: result.syncedLyrics, plain: result.plainLyrics) else { continue }
            if best == nil || delta < best!.delta { best = (delta, lyrics) }
        }
        return best?.lyrics
    }

    /// Two names refer to the same thing when one is contained in the other. Both sides are
    /// already stripped of the parts that differ by convention, so what is left is either
    /// the same name or a longer one that includes it — `Nirvana` inside `Nirvana - Nirvana`.
    static func agree(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs.contains(rhs) || rhs.contains(lhs)
    }

    // MARK: - Cleaning tags into something searchable

    /// Keywords that mark a title's tail as a variant rather than part of the name.
    private static let variantKeywords: Set<String> = [
        "mix", "remix", "edit", "version", "remaster", "remastered", "live", "instrumental",
        "radio", "extended", "dub", "bootleg", "rework", "acoustic", "demo", "mono", "stereo",
        "reprise", "cover", "karaoke", "bonus", "explicit", "clean", "single", "album",
    ]

    /// A title with the parts that no lyrics database agrees on removed: the bracketed
    /// remix suffix, the trailing `- Radio Edit`, the `feat.` credit.
    ///
    /// Deliberately conservative about the dash form — `Sgt. Pepper - Reprise` loses its
    /// tail because `reprise` is a known variant word, while `Ashes - Part One` keeps it.
    /// A title cut too short still searches; a title cut wrongly searches for a different song.
    static func searchableTitle(_ raw: String) -> String {
        var text = removingBracketedGroups(raw)
        if let range = text.range(of: " - ") {
            let tail = String(text[range.upperBound...])
            if containsVariantKeyword(tail) { text = String(text[..<range.lowerBound]) }
        }
        text = removingCredits(text)
        let cleaned = collapsed(text)
        // Everything about the title was a variant marker; the raw title is all we have.
        return cleaned.isEmpty ? collapsed(raw) : cleaned
    }

    /// The performing artist without the guest credit — `Aura feat. Dani Senior` is filed
    /// under `Aura`, and searching for the pair finds nothing at all.
    static func searchableArtist(_ raw: String) -> String {
        let cleaned = collapsed(removingCredits(removingBracketedGroups(raw)))
        return cleaned.isEmpty ? collapsed(raw) : cleaned
    }

    private static func containsVariantKeyword(_ text: String) -> Bool {
        let words = normalized(text).split(separator: " ").map(String.init)
        return words.contains { variantKeywords.contains($0) }
    }

    /// Drops `(…)` and `[…]` groups. Nested brackets are not a thing in track titles, so a
    /// depth counter would be ceremony; a simple scan is enough and cannot run away.
    private static func removingBracketedGroups(_ raw: String) -> String {
        var out = ""
        var depth = 0
        for character in raw {
            if character == "(" || character == "[" { depth += 1; continue }
            if character == ")" || character == "]" { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(character) }
        }
        return out
    }

    /// Cuts a `feat.` / `ft.` / `featuring` / `with` credit and everything after it.
    private static func removingCredits(_ raw: String) -> String {
        let words = raw.split(separator: " ", omittingEmptySubsequences: true)
        var kept: [Substring] = []
        for word in words {
            let bare = normalized(String(word))
            if ["feat", "ft", "featuring", "feats"].contains(bare) { break }
            // `with` only reads as a credit once there is a name in front of it; a title
            // that opens with it ("With or Without You") keeps every word.
            if bare == "with", !kept.isEmpty { break }
            kept.append(word)
        }
        return kept.joined(separator: " ")
    }

    /// Lowercased, unaccented, punctuation-free, single-spaced — the form in which two
    /// spellings of one name can actually be compared.
    static func normalized(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX"))
        let stripped = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return collapsed(stripped)
    }

    private static func collapsed(_ raw: String) -> String {
        raw.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" }).joined(separator: " ")
    }

    // MARK: - Parsing

    /// Parses LRCLIB's response, preferring synced lyrics over plain.
    static func parse(_ data: Data) -> NavidromeLyrics? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return lyrics(synced: object["syncedLyrics"] as? String, plain: object["plainLyrics"] as? String)
    }

    static func lyrics(synced: String?, plain: String?) -> NavidromeLyrics? {
        if let synced, !synced.isEmpty, let parsed = parseLRC(synced), !parsed.isEmpty {
            return NavidromeLyrics(synced: true, lines: parsed)
        }
        if let plain, !plain.isEmpty {
            let lines = plain.split(separator: "\n", omittingEmptySubsequences: false)
                .map { NavidromeLyrics.Line(text: String($0)) }
            return NavidromeLyrics(synced: false, lines: lines)
        }
        return nil
    }

    /// `[mm:ss.xx] text` — the LRC format.
    ///
    /// Hand-parsed rather than regex'd because the failure mode matters: a line that does
    /// not match its timestamp should become an untimed line rather than disappear, so a
    /// sheet with one malformed stamp still reads as lyrics.
    static func parseLRC(_ raw: String) -> [NavidromeLyrics.Line]? {
        var out: [NavidromeLyrics.Line] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(.init(text: trimmed)) }
                continue
            }
            let stamp = String(text[text.index(after: text.startIndex) ..< close])
            let body = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            // `[ar: …]`, `[length: …]` and friends are metadata, not lines.
            guard let seconds = seconds(fromLRCStamp: stamp) else { continue }
            out.append(.init(start: seconds, text: body))
        }
        return out.isEmpty ? nil : out
    }

    static func seconds(fromLRCStamp stamp: String) -> Double? {
        let parts = stamp.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]), let rest = Double(parts[1]) else {
            return nil
        }
        return minutes * 60 + rest
    }
}
