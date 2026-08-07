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
}

/// Builds the phone's mix catalog from the shared store and play history.
@MainActor
enum MobileMixCatalog {
    /// Art-directed backdrops for specific server-generated playlists, by name — the same
    /// table the Mac uses. Anything absent keeps the generated mesh; this is opt-in per
    /// playlist, not a required asset.
    static let serverArtwork: [String: String] = [
        "Focus · Deep": "MixArtFocusDeep",
        "Focus · Momentum": "MixArtFocusMomentum",
        "Focus · Lift": "MixArtFocusLift",
        "Fresh": "MixArtFresh",
        "Daily Jams": "MixArtDailyJams",
        "Daily Discovery": "MixArtDailyDiscovery",
        "Deep Cuts": "MixArtDeepCuts",
        "Favorites Radio": "MixArtFavoritesRadio",
        "Favorites Inbox": "MixArtFavoritesInbox",
    ]

    /// The six auto-mixes, matching the Mac's set so the two apps offer the same things.
    static func auto(_ model: MobileModel) -> [MobileMix] {
        [
            MobileMix(id: "mostPlayed", title: "Most Played", subtitle: "Your top tracks",
                      icon: "flame.fill", tint: .orange, artwork: "MixArtMostPlayed") {
                model.history.topTracks(since: .distantPast).map(\.song)
            },
            MobileMix(id: "recentlyAdded", title: "Just Added", subtitle: "Newest in your library",
                      icon: "sparkles", tint: .green, artwork: "MixArtJustAdded") {
                await model.musicLibrary.mixSongs(type: "newest")
            },
            MobileMix(id: "topRated", title: "Top Rated", subtitle: "Your highest-rated",
                      icon: "star.fill", tint: .yellow, artwork: "MixArtTopRated") {
                await model.musicLibrary.mixSongs(type: "highest")
            },
            MobileMix(id: "onRepeat", title: "On Repeat", subtitle: "Frequently played",
                      icon: "repeat", tint: .pink, artwork: "MixArtOnRepeat") {
                await model.musicLibrary.mixSongs(type: "frequent")
            },
            MobileMix(id: "forgotten", title: "Forgotten Favorites", subtitle: "Liked, not heard lately",
                      icon: "heart.circle.fill", tint: .red, artwork: "MixArtForgotten") {
                let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
                let recent = Set(model.history.entries.filter { $0.playedAt >= cutoff }.map(\.song.id))
                return MixCatalogRules.forgottenFavorites(
                    liked: model.musicLibrary.starred.songs,
                    recentlyPlayedIDs: recent
                )
            },
            MobileMix(id: "discover", title: "Discover", subtitle: "A random shuffle",
                      icon: "shuffle", tint: .blue, artwork: "MixArtDiscover") {
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
