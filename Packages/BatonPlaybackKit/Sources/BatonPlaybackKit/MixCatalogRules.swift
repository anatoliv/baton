import Foundation
import BatonSubsonicModels

/// The decision-making behind auto-mixes, with no UI attached: which genres are worth
/// offering, what a genre looks like, which playlists a server generated, and how to
/// order a pool so it doesn't clump.
///
/// This lives in the shared package because the Mac and the phone must agree. A genre
/// that is "uninformative" on one is uninformative on the other; a mix that spreads
/// artists on the desktop shouldn't stack them on the phone. Every rule here was
/// learned from a real library (see the Mac's MixCatalogTests) and the cost of the two
/// platforms drifting is that the same library produces different mixes depending on
/// which device you picked up.
///
/// Pure and synchronous throughout — no store, no model, no I/O — so it is testable and
/// callable from either app's view layer.
public enum MixCatalogRules {
    // MARK: - Genres worth offering

    /// Genre names that carry no information. A YouTube-sourced library tags essentially
    /// every file "Music" or "People & Blogs", which produced a "Daily Mix" card offering
    /// the entire library under one meaningless heading.
    public static let uninformativeGenres: Set<String> = [
        "music", "people & blogs", "entertainment", "unknown", "other", "misc",
        "miscellaneous", "gaming", "education", "news & politics", "film & animation",
    ]

    /// Fraction of the library above which a single genre is treated as a non-distinction.
    public static let genreDominanceCeiling = 0.35

    /// Whether a genre is distinct enough to be worth its own mix card. A genre that
    /// covers most of the library isn't a genre.
    public static func isUsefulGenre(name: String, songCount: Int, librarySongCount: Int) -> Bool {
        guard songCount > 0 else { return false }
        if uninformativeGenres.contains(name.trimmingCharacters(in: .whitespaces).lowercased()) {
            return false
        }
        guard librarySongCount > 0 else { return true }
        return Double(songCount) / Double(librarySongCount) <= genreDominanceCeiling
    }

    /// An SF Symbol that suits a genre.
    ///
    /// Every genre card previously showed `guitars.fill`, which put a guitar on Trance,
    /// House, Electronic and Pop — twelve identical guitars did more to make the row look
    /// monotonous than the backdrops did. Matching is on substrings so related genres
    /// ("Hard Trance", "Vocal Trance") share a symbol without needing an entry each, and
    /// anything unrecognised keeps a neutral default rather than guessing.
    public static func symbol(forGenre name: String) -> String {
        let g = name.lowercased()
        let rules: [(String, String)] = [
            ("trance", "waveform.path.ecg"), ("techno", "waveform.path.ecg"),
            ("house", "square.stack.3d.down.right.fill"), ("electronic", "waveform"),
            ("edm", "waveform"), ("dance", "figure.dance"), ("eurodance", "figure.dance"),
            ("disco", "circle.circle.fill"), ("funk", "circle.circle.fill"),
            ("ambient", "cloud.fill"), ("chill", "cloud.fill"), ("new age", "cloud.fill"),
            ("synthwave", "sunset.fill"), ("cyberpunk", "bolt.horizontal.fill"),
            ("darkwave", "moon.stars.fill"), ("gothic", "moon.stars.fill"),
            ("new wave", "antenna.radiowaves.left.and.right"),
            ("metal", "flame.fill"), ("hard rock", "flame.fill"), ("punk", "flame.fill"),
            ("rock", "guitars.fill"), ("blues", "guitars.fill"), ("folk", "guitars.fill"),
            ("country", "guitars.fill"),
            ("jazz", "pianokeys"), ("classical", "pianokeys"), ("piano", "pianokeys"),
            ("hip", "mic.fill"), ("rap", "mic.fill"), ("r&b", "mic.fill"), ("soul", "mic.fill"),
            ("pop", "star.fill"), ("k-pop", "star.fill"),
            ("workout", "figure.run"), ("big beat", "speaker.wave.3.fill"),
            ("drum", "speaker.wave.3.fill"), ("dubstep", "speaker.wave.3.fill"),
            ("reggae", "leaf.fill"), ("latin", "sun.max.fill"),
            ("soundtrack", "film.fill"), ("video game", "gamecontroller.fill"),
            ("castlevania", "gamecontroller.fill"), ("audiobook", "book.fill"),
            ("podcast", "mic.circle.fill"), ("trip", "moon.haze.fill"),
        ]
        for (needle, icon) in rules where g.contains(needle) {
            return icon
        }
        return "music.note"
    }

    // MARK: - Server-generated playlists

    /// Names that indicate a playlist is produced by a generator rather than curated by
    /// hand. Deliberately a small, explicit list: guessing wrong pulls someone's carefully
    /// built playlist out of the sidebar they expect to find it in.
    public static let serverGeneratedNames: Set<String> = [
        "Daily Jams", "Daily Discovery", "Deep Cuts", "Fresh",
        "Focus · Deep", "Focus · Momentum", "Focus · Lift",
        "Favorites Radio", "Favorites Inbox",
    ]

    /// True when `name` looks generated. Matches the explicit set, plus anything under a
    /// "Focus · " prefix so new focus contexts appear without a code change.
    public static func isServerGenerated(_ name: String) -> Bool {
        serverGeneratedNames.contains(name) || name.hasPrefix("Focus · ")
    }

    // MARK: - Ordering a pool

    /// Interleave so no two adjacent tracks share an artist when the pool allows it (i.e.
    /// as long as no single artist owns more than half the set). Greedy
    /// largest-remaining-bucket with a "not the same artist as the last emitted"
    /// constraint — the standard optimal de-clumping. Order-preserving for an already
    /// diverse list (every artist distinct ⇒ identity).
    public static func spreadArtists(_ songs: [NavidromeSong]) -> [NavidromeSong] {
        guard songs.count > 2 else { return songs }
        // Buckets in first-appearance order, each keeping its songs in incoming order.
        var order: [String] = []
        var buckets: [String: [NavidromeSong]] = [:]
        for song in songs {
            // Songs with no artist are each their own bucket: they're unrelated to one
            // another, so grouping them would invent a clump that isn't there.
            let artist = (song.artist?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "\u{0}\(song.id)"
            if buckets[artist] == nil { order.append(artist) }
            buckets[artist, default: []].append(song)
        }
        guard order.count > 1 else { return songs }

        var result: [NavidromeSong] = []
        result.reserveCapacity(songs.count)
        var lastArtist: String?
        while result.count < songs.count {
            // Largest remaining bucket that isn't the one we just emitted from.
            let candidate = order
                .filter { !(buckets[$0]?.isEmpty ?? true) && $0 != lastArtist }
                .max { (buckets[$0]?.count ?? 0) < (buckets[$1]?.count ?? 0) }
                // Everything left belongs to the last artist — emit it rather than stall.
                ?? order.first { !(buckets[$0]?.isEmpty ?? true) }
            guard let artist = candidate, var bucket = buckets[artist], !bucket.isEmpty else { break }
            result.append(bucket.removeFirst())
            buckets[artist] = bucket
            lastArtist = artist
        }
        return result
    }

    /// Liked songs the play history hasn't seen recently, spread so the shuffle doesn't
    /// clump — the "Forgotten Favorites" mix.
    public static func forgottenFavorites(
        liked: [NavidromeSong],
        recentlyPlayedIDs: Set<String>
    ) -> [NavidromeSong] {
        spreadArtists(liked.filter { !recentlyPlayedIDs.contains($0.id) }.shuffled())
    }
}
