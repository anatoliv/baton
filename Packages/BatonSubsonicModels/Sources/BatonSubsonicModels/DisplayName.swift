import Foundation

/// Whether a piece of metadata is worth putting on screen.
///
/// A library assembled from imports is full of values that are technically present and carry
/// no information: an artist tagged `Unknown`, an album called `YT Mix`, a genre of `Music`,
/// a playlist owner of `Default`. Rendering them is worse than rendering nothing, because a
/// blank space reads as "this track has no artist" while the word *Unknown* reads as "this
/// app does not know", which is a claim about the app.
///
/// **This exists because the rule was already written three times and applied nowhere near
/// widely enough.** `BatonMenuBarExtra` dropped "Unknown" from the Mac's menu-bar header,
/// `MixCatalogRules` filtered uninformative genres, and `MusicArtistsBrowser` caught YT
/// auto-imports — while 54 other places rendered `song.artist ?? ""` straight through, which
/// is why the iPhone's full-screen player showed a large centred **Unknown** under the title.
/// The agent had a fourth spelling of its own and said "by [unknown]" out loud.
///
/// Lives in the models package rather than `Shared/` so the agent and playback layers can
/// reach it too; `Shared/` is compiled into the two apps only.
public enum DisplayName {
    /// Values that are never information, whatever the library.
    ///
    /// Deliberately short, and deliberately not a heuristic. Everything here is a literal
    /// placeholder some importer wrote when it had nothing to say. **"Various" and "Various
    /// Artists" are absent on purpose**: on a compilation that is the true answer, and
    /// hiding it would lose real information rather than noise.
    static let placeholders: Set<String> = [
        "unknown", "unknown artist", "unknown album", "[unknown]", "(unknown)",
        "untitled", "n/a", "none", "default", "no artist", "no album",
    ]

    /// Characters a downloader substituted because the real ones are illegal in filenames.
    ///
    /// `yt-dlp` and friends cannot put `"`, `|`, `/`, `:` or `?` in a filename, so they swap
    /// in fullwidth Unicode lookalikes. Those filenames then become tags, and the lookalikes
    /// arrive here — which is why a title reads `＂Jjos＂` instead of `"Jjos"`, why every YT
    /// import is full of `｜` where a `|` belongs, and why an artist is `RIKO & GUGGA， BRK`
    /// with a fullwidth comma.
    ///
    /// Restoring them is lossless and unambiguous: nobody types U+FF02 on purpose in a song
    /// title, and each of these has exactly one plain-ASCII original. This is the one part of
    /// tidying that is a fact rather than a taste, which is why it happens here and things
    /// like stripping emoji or marketing padding do not.
    static let filenameSafeSubstitutions: [Character: Character] = [
        "＂": "\"",   // U+FF02 fullwidth quotation mark
        "｜": "|",    // U+FF5C fullwidth vertical line
        "⧸": "/",     // U+29F8 big solidus
        "⧵": "\\",    // U+29F5 reverse solidus operator
        "：": ":",    // U+FF1A fullwidth colon
        "？": "?",    // U+FF1F fullwidth question mark
        "＊": "*",    // U+FF0A fullwidth asterisk
        "＜": "<", "＞": ">",  // U+FF1C / U+FF1E
        "，": ",",    // U+FF0C fullwidth comma
    ]

    /// Undo the downloader's filename escaping, and collapse the whitespace it leaves.
    ///
    /// Applied to everything on its way to the screen. Does not remove anything a person
    /// might have meant — no emoji stripping, no truncation, no title-casing.
    public static func tidy(_ value: String) -> String {
        let restored = String(value.map { filenameSafeSubstitutions[$0] ?? $0 })
        // Collapse runs of space that the substitution can expose, without touching newlines
        // inside a value that legitimately has them.
        return restored
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The value to show, or nil when there is nothing worth showing.
    ///
    /// Returns an optional rather than an empty string so callers are pushed toward *not
    /// laying out the line at all*. A blank `Text("")` still occupies its frame and its
    /// spacing, which on the phone's player left a gap where the placeholder had been.
    public static func shown(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = tidy(value)
        guard !cleaned.isEmpty else { return nil }
        guard !placeholders.contains(cleaned.lowercased()) else { return nil }
        return cleaned
    }

    /// A title, tidied. Titles are never hidden — a track with no title still has to be
    /// selectable — so this returns the cleaned string rather than an optional.
    public static func title(_ value: String) -> String {
        let cleaned = tidy(value)
        return cleaned.isEmpty ? value : cleaned
    }

    /// Whether this value would be hidden. For callers that need the question rather than
    /// the answer — a filter predicate, say.
    public static func isPlaceholder(_ value: String?) -> Bool { shown(value) == nil }

    /// The artist to show for a track, or nil.
    ///
    /// Named separately from `shown` because artist is the field this problem shows up in
    /// most, and a call site reading `DisplayName.artist(song.artist)` says what it means.
    public static func artist(_ value: String?) -> String? { shown(value) }

    /// A one-line "Title by Artist", collapsing to just the title when the artist is a
    /// placeholder. What speech and chat replies should use: "Clair de Lune is paused" is a
    /// sentence; "Clair de Lune by [unknown] is paused" makes the app sound confused about
    /// its own library.
    public static func titleWithArtist(title: String, artist: String?) -> String {
        guard let artist = shown(artist) else { return title }
        return "\(title) by \(artist)"
    }
}
