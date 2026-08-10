import SwiftUI

/// The six auto-mix cards, as the user sees them.
///
/// Title, subtitle, icon, tint and artwork were written out twice — once in `MusicMix.swift`
/// and once in `MixCatalog.swift` — about ninety lines of user-visible copy kept in step by
/// hand. Nothing enforced that, and this is the copy people read: rename "Forgotten
/// Favorites" on one platform and the two apps quietly stop offering the same thing.
///
/// Only the presentation lives here. What each mix *contains* stays per-app, because the
/// bodies close over different model types — and that is a real difference, not drift.
// `MixCardSpec`, not `MixCard`: the phone already has a `MixCard` *view*, and the view had
// the name first — a card that draws itself has more claim to it than a row of constants.
public struct MixCardSpec: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let icon: String
    public let tint: Color
    /// Asset-catalog name in `Shared/MixArt.xcassets`, which both apps already compile.
    public let artwork: String
}

public enum MixCards {
    /// In display order. The Mixes tab and the Home shelf both read this, on both apps.
    public static let auto: [MixCardSpec] = [
        MixCardSpec(id: "mostPlayed", title: "Most Played", subtitle: "Your top tracks",
                icon: "flame.fill", tint: .orange, artwork: "MixArtMostPlayed"),
        MixCardSpec(id: "recentlyAdded", title: "Just Added", subtitle: "Newest in your library",
                icon: "sparkles", tint: .green, artwork: "MixArtJustAdded"),
        MixCardSpec(id: "topRated", title: "Top Rated", subtitle: "Your highest-rated",
                icon: "star.fill", tint: .yellow, artwork: "MixArtTopRated"),
        MixCardSpec(id: "onRepeat", title: "On Repeat", subtitle: "Frequently played",
                icon: "repeat", tint: .pink, artwork: "MixArtOnRepeat"),
        MixCardSpec(id: "forgotten", title: "Forgotten Favorites", subtitle: "Liked, not heard lately",
                icon: "heart.circle.fill", tint: .red, artwork: "MixArtForgotten"),
        MixCardSpec(id: "discover", title: "Discover", subtitle: "A random shuffle",
                icon: "shuffle", tint: .blue, artwork: "MixArtDiscover"),
    ]

    public static func card(_ id: String) -> MixCardSpec {
        auto.first { $0.id == id } ?? auto[0]
    }

    /// Art-directed backdrops for server-generated playlists, by name. Opt-in per playlist:
    /// anything absent keeps the generated mesh.
    public static let serverArtwork: [String: String] = [
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
}
