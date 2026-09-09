import BatonSubsonicModels
import Foundation

/// A tiny music library bundled inside the app, so Baton is usable with no server.
///
/// This exists for two audiences. App Review is the urgent one: a reviewer opens
/// Baton, sees "Connect to Navidrome", has no server, and rejects it under
/// Guideline 2.1 — the same way a missing demo account bounced receipt-sync.
/// The second is anyone who installs Baton before setting Navidrome up, who
/// currently meets a wall instead of an app.
///
/// The audio and artwork are synthesized (see `ios/scripts/make-demo-audio.py`)
/// rather than sourced. Creative Commons music is usually NonCommercial —
/// including the netBloc catalogue on Navidrome's own demo server — so it cannot
/// ship inside a paid App Store binary.
///
/// Demo tracks are ordinary local files, so they take the same path a downloaded
/// track takes: the engine plays a file URL directly. Real gapless, real EQ, real
/// now-playing, real scrobble suppression. Nothing here is a mock player.
@MainActor
enum DemoLibrary {
    static let albumID = "demo-album-baton"
    // Real music, not synthesized tones. Kimiko Ishizaka's recording of the Goldberg
    // Variations was released into the public domain under CC0 by the Open Goldberg
    // Variations project — which makes it the rare thing this app can legitimately carry:
    // a paid App Store binary *and* a public MIT repo, with no attribution obligation to
    // pass on to anyone who forks it. Provenance in ios/Resources/Demo/CREDITS.md.
    static let albumName = "Goldberg Variations"
    static let artist = "Kimiko Ishizaka"

    private struct Track {
        let resource: String
        let title: String
        let seconds: Int
    }

    private static let tracks: [Track] = [
        .init(resource: "demo-1", title: "Variatio 4", seconds: 69),
        .init(resource: "demo-2", title: "Variatio 5", seconds: 75),
        .init(resource: "demo-3", title: "Variatio 6, Canone alla Seconda", seconds: 75),
        .init(resource: "demo-4", title: "Variatio 10, Fughetta", seconds: 75),
    ]

    /// True when the bundle actually carries the audio. A build that dropped the
    /// resources should hide the demo button rather than offer a dead end.
    static var isAvailable: Bool {
        tracks.allSatisfy { Bundle.main.url(forResource: $0.resource, withExtension: "m4a") != nil }
    }

    private static func audioURL(_ resource: String) -> URL? {
        Bundle.main.url(forResource: resource, withExtension: "m4a")
    }

    static var songs: [NavidromeSong] {
        tracks.enumerated().compactMap { index, track in
            guard let url = audioURL(track.resource) else { return nil }
            let coverID = "\(track.resource)-cover"
            // The id IS the file URL. The playback engine resolves a file URL to the
            // file itself and streams nothing, which is what lets demo mode work
            // with no server and no download step.
            return NavidromeSong(
                id: url.absoluteString,
                title: track.title,
                artist: artist,
                album: albumName,
                albumID: albumID,
                duration: track.seconds,
                coverArtID: coverID,
                // Set directly as well as via `coverArtID`, because the lock screen and
                // Control Center read `artworkURL` first and can't ask a server.
                artworkURL: Bundle.main.url(forResource: coverID, withExtension: "png"),
                track: index + 1,
                year: 2026,
                genre: "Ambient",
                genres: ["Ambient"],
                bitRate: 96,
                suffix: "m4a",
                contentType: "audio/mp4"
            )
        }
    }

    static var album: NavidromeAlbum {
        NavidromeAlbum(
            id: albumID,
            name: albumName,
            artist: artist,
            songCount: tracks.count,
            duration: tracks.reduce(0) { $0 + $1.seconds },
            coverArtID: "\(tracks[0].resource)-cover",
            year: 2026,
            genre: "Ambient"
        )
    }

    /// Cover art keyed by the id each view asks `coverArtURL` for.
    private static var artwork: [String: URL] {
        var map: [String: URL] = [:]
        for track in tracks {
            let key = "\(track.resource)-cover"
            if let url = Bundle.main.url(forResource: key, withExtension: "png") {
                map[key] = url
            }
        }
        return map
    }

    /// Artist-only rows with no songs or albums behind them, so the A–Z rail has enough
    /// letters to earn its threshold against the bundled library. The curated demo
    /// (Goldberg Variations, one artist) is what App Store reviewers and everyday users
    /// see; this only appears when `-baton.demoRailFixture` opts in, which only a test
    /// does (TBX-5327 — the bundled library otherwise carries a single artist, which can
    /// never clear a positive rail threshold, so the rail test had to reach out to
    /// `demo.navidrome.org` and skip whenever that server was unreachable).
    /// Names span distinct first letters on purpose, since a rail needs letters, not rows.
    static let railFixtureArtistNames = [
        "Ava Bloom", "Bruno Castillo", "Delphine Estrada", "Elias Fontaine",
        "Greta Halvorsen", "Ines Jorgensen", "Kaspar Lindqvist", "Marisol Nakamura",
        "Oskar Petrov", "Quiana Reyes", "Sana Takahashi", "Viktor Ulrich",
    ]

    static var railFixtureArtists: [NavidromeArtist] {
        railFixtureArtistNames.map { NavidromeArtist(id: "demo-rail-\($0)", name: $0) }
    }

    /// Puts the app into demo mode: the library is the bundle, and playback
    /// resolves to local files.
    static func activate(_ model: MobileModel) {
        let catalogue = songs
        // Was `-baton.demoRailFixture` in `app.launchArguments` (TBX-5336: XCUIApplication
        // drops a whole `-key value` group about one launch in four); now `app.launchEnvironment`.
        let wantsRailFixture = ProcessInfo.processInfo.environment["baton.demoRailFixture"] != nil
        model.musicLibrary.seedDemo(
            songs: catalogue,
            albums: [album],
            // A couple of tracks pre-liked, so the Liked screen shows the feature
            // working rather than an empty state on a library of four songs.
            liked: Array(catalogue.prefix(2)).map { var s = $0; s.isLiked = true; return s },
            artwork: artwork,
            extraArtists: wantsRailFixture ? railFixtureArtists : []
        )
        model.isDemoMode = true
    }

    /// Leaves demo mode — used when the user connects a real server.
    static func deactivate(_ model: MobileModel) {
        model.musicLibrary.exitDemo()
        model.isDemoMode = false
    }
}
