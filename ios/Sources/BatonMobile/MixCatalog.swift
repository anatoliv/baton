import SwiftUI

/// One auto-generated mix — a card with a title, icon and gradient, plus a closure that
/// fetches its tracks on tap. The phone's counterpart to the Mac's `MusicMix`, drawing
/// its *decisions* from the shared `MixCatalogRules` so both devices offer the same
/// mixes from the same library.
///
/// The tracks are a closure rather than an array because a mix is a question, not a
/// snapshot: "Discover" should be a different shuffle every time you open it, and
/// "Most Played" should reflect the play you finished a minute ago.
struct MobileMix: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    /// Art-directed backdrop from `Shared/MixArt.xcassets`, or `nil` for the generated
    /// mesh. Names match the Mac's exactly — the assets and the art direction are shared.
    var artwork: String?
    let songs: @MainActor () async -> [NavidromeSong]

    // Identity is the stable id — the closure isn't Hashable, and navigation only needs
    // to know which card was tapped.
    static func == (lhs: MobileMix, rhs: MobileMix) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Built from the shared card, so the six titles and subtitles have one home.
    init(card: MixCardSpec, songs: @escaping @MainActor () async -> [NavidromeSong]) {
        self.id = card.id
        self.title = card.title
        self.subtitle = card.subtitle
        self.icon = card.icon
        self.tint = card.tint
        self.artwork = card.artwork
        self.songs = songs
    }

    /// The literal form, for the genre and server-playlist mixes built from library data.
    init(id: String, title: String, subtitle: String, icon: String, tint: Color,
         artwork: String? = nil, songs: @escaping @MainActor () async -> [NavidromeSong]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.artwork = artwork
        self.songs = songs
    }
}

/// Builds the phone's mix catalog from the shared store and play history.
@MainActor
enum MobileMixCatalog {
    /// Server-playlist backdrops live in `MixCards.serverArtwork` (Shared/) — the Mac
    /// had the identical table, and an art direction that exists on one platform is a
    /// half-finished art direction.
    static var serverArtwork: [String: String] { MixCards.serverArtwork }


    /// The six auto-mixes, matching the Mac's set so the two apps offer the same things.
    static func auto(_ model: MobileModel) -> [MobileMix] {
        [
            MobileMix(card: MixCards.card("mostPlayed")) {
                model.history.topTracks(since: .distantPast).map(\.song)
            },
            MobileMix(card: MixCards.card("recentlyAdded")) {
                await model.musicLibrary.mixSongs(type: "newest")
            },
            MobileMix(card: MixCards.card("topRated")) {
                await model.musicLibrary.mixSongs(type: "highest")
            },
            MobileMix(card: MixCards.card("onRepeat")) {
                await model.musicLibrary.mixSongs(type: "frequent")
            },
            MobileMix(card: MixCards.card("forgotten")) {
                let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
                let recent = Set(model.history.entries.filter { $0.playedAt >= cutoff }.map(\.song.id))
                return MixCatalogRules.forgottenFavorites(
                    liked: model.musicLibrary.starred.songs,
                    recentlyPlayedIDs: recent
                )
            },
            MobileMix(card: MixCards.card("discover")) {
                // A fresh shuffle each open, spread so it never stacks one artist.
                MixCatalogRules.spreadArtists(await model.musicLibrary.mixSongs(type: "random").shuffled())
            },
        ]
    }

    /// Per-genre "Daily Mix" cards — the library's most distinctive genres, filtered by
    /// the shared usefulness rule so a library that tags everything "Music" doesn't get a
    /// card offering itself.
    static func genres(_ model: MobileModel) -> [MobileMix] {
        let palette: [Color] = [.purple, .teal, .indigo, .mint, .brown, .cyan, .orange, .pink]
        let all = model.musicLibrary.genres
        let total = all.reduce(0) { $0 + ($1.songCount ?? 0) }
        return all
            .filter { MixCatalogRules.isUsefulGenre(name: $0.name, songCount: $0.songCount ?? 0, librarySongCount: total) }
            .sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
            .prefix(12)
            .enumerated()
            .map { index, genre in
                MobileMix(id: "genre-\(genre.name)", title: genre.name,
                          subtitle: "\(genre.songCount ?? 0) songs",
                          icon: MixCatalogRules.symbol(forGenre: genre.name),
                          tint: palette[index % palette.count]) {
                    MixCatalogRules.spreadArtists(await model.musicLibrary.songsByGenre(genre.name).shuffled())
                }
            }
    }

    /// Playlists the *server* generated (a nightly job, a smart playlist). Kept separate
    /// from the auto mixes because the mechanism genuinely differs — these are fetched,
    /// not computed here — and presenting a fetch as a computation would misrepresent it.
    static func server(_ model: MobileModel) -> [MobileMix] {
        let palette: [Color] = [.indigo, .teal, .purple, .mint, .cyan, .brown]
        return model.musicLibrary.playlists
            .filter { MixCatalogRules.isServerGenerated($0.name) }
            .sorted { $0.name < $1.name }
            .enumerated()
            .map { index, playlist in
                MobileMix(id: "server-\(playlist.id)", title: playlist.name,
                          subtitle: "Generated on your server",
                          icon: "sparkles.rectangle.stack",
                          tint: palette[index % palette.count],
                          artwork: serverArtwork[playlist.name]) {
                    await model.musicLibrary.playlist(id: playlist.id)?.songs ?? []
                }
            }
    }
}
