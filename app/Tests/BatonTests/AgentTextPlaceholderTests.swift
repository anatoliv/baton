import XCTest
@testable import Baton
@testable import BatonAgentKit

/// The two strings the model and the MCP client actually read: `nowPlayingSummary`, which
/// is the body of `music_now_playing`, and `playerContext()`, which is prepended to every
/// natural-language request.
///
/// Both were wrong in 0.16.15 while the views were right, and neither had a test with a
/// track in it — the only existing `playerContext` test asserts the *idle* sentence, which
/// is why `by Optional("Debussy")` survived. The lesson is the coverage, not the strings:
/// a now-playing assertion needs something playing.
@MainActor
final class AgentTextPlaceholderTests: XCTestCase {
    private func song(artist: String?, title: String = "Clair de Lune",
                      album: String? = nil) -> NavidromeSong {
        NavidromeSong(id: "s1", title: title, artist: artist, album: album)
    }

    /// A model whose player holds `song`, and the router that sits next to it — the same
    /// pair the Telegram/Discord path builds. Nothing streams under test; the track is
    /// still selected, which is all these strings read.
    private func makeRouter(playing song: NavidromeSong) -> (RemoteCommandRouter, MusicModel) {
        let settings = RemoteControlSettings(
            environment: .testing,
            defaults: UserDefaults(suiteName: "baton.agenttext.tests.\(UUID().uuidString)")!,
            secrets: InMemorySecretStore()
        )
        let music = MusicModel(environment: .testing)
        let focus = BatonAudioFocusRegistry()
        music.music.play([song])
        let router = RemoteCommandRouter(
            player: music.music,
            tools: MCPToolSurface(music: music, focus: focus),
            settings: settings
        )
        return (router, music)
    }

    // MARK: music_now_playing

    func testSummaryOmitsAPlaceholderArtistInsteadOfSayingIt() {
        let (_, music) = makeRouter(playing: song(artist: "[unknown]"))
        let summary = music.music.nowPlayingSummary
        XCTAssertTrue(summary.contains("Clair de Lune"), "the title must survive: \(summary)")
        XCTAssertFalse(summary.lowercased().contains("unknown"),
                       "the placeholder reached the MCP payload: \(summary)")
    }

    func testSummaryKeepsARealArtist() {
        let (_, music) = makeRouter(playing: song(artist: "Debussy"))
        XCTAssertTrue(music.music.nowPlayingSummary.contains("Debussy — Clair de Lune"),
                      music.music.nowPlayingSummary)
    }

    // MARK: playerContext

    /// The `Optional("…")` leak. `song.artist` is optional and this was interpolated bare,
    /// so every player context the Mac's agent read said `by Optional("Debussy")`.
    func testPlayerContextNeverShowsSwiftOptionalSyntax() {
        let (router, _) = makeRouter(playing: song(artist: "Debussy", album: "Suite bergamasque"))
        let context = router.playerContext()
        XCTAssertFalse(context.contains("Optional("), context)
        XCTAssertTrue(context.contains("by Debussy"), context)
        XCTAssertTrue(context.contains("Suite bergamasque"), context)
    }

    func testPlayerContextDropsTheArtistClauseWhenThereIsNoArtist() {
        let (router, _) = makeRouter(playing: song(artist: "[unknown]", album: "Unknown Album"))
        let context = router.playerContext()
        XCTAssertFalse(context.lowercased().contains("unknown"), context)
        XCTAssertFalse(context.contains(" by "), "an absent artist must not leave 'by': \(context)")
        XCTAssertTrue(context.contains("Clair de Lune"), context)
    }
}
