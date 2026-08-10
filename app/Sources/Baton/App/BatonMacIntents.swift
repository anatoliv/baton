import AppIntents
import Foundation

/// Shortcuts and Siri on the Mac.
///
/// The Mac had none. Every action below already existed and was already reachable — by the
/// MCP tools, by the chat bridges, by the menu bar — from everywhere except the one place
/// macOS asks apps to expose themselves: Shortcuts. So Baton could be driven by an agent
/// over a socket and not by a two-step Shortcut, which is a strange shape for a desktop app
/// to have.
///
/// Kept to the transport plus "play something". The library-entity intents (play *this*
/// album by name, with disambiguation) want `AppEntity` conformances for albums and
/// artists, which is a larger piece of work than the doors this wave is about.
@MainActor
enum MacIntentServices {
    /// Set once at app start, like the phone's `AppServicesHolder`. Nil in previews and
    /// during tests, where an intent has nothing to drive.
    static var model: MusicModel?
}

struct MacPlayMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play music"
    static let description = IntentDescription("Resume playback in Baton.")

    @MainActor
    func perform() async throws -> some IntentResult {
        MacIntentServices.model?.music.resume()
        return .result()
    }
}

struct MacPauseMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause music"
    static let description = IntentDescription("Pause playback in Baton.")

    @MainActor
    func perform() async throws -> some IntentResult {
        MacIntentServices.model?.music.pause()
        return .result()
    }
}

struct MacNextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next track"
    static let description = IntentDescription("Skip to the next track in Baton.")

    @MainActor
    func perform() async throws -> some IntentResult {
        MacIntentServices.model?.music.next()
        return .result()
    }
}

struct MacPreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous track"
    static let description = IntentDescription("Go back a track in Baton.")

    @MainActor
    func perform() async throws -> some IntentResult {
        MacIntentServices.model?.music.previous()
        return .result()
    }
}

struct MacLikeCurrentTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Like the current track"
    static let description = IntentDescription("Like what Baton is playing.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = MacIntentServices.model, let song = model.music.nowPlaying else {
            return .result()
        }
        await model.musicLibrary.toggleLike(song)
        return .result()
    }
}

/// Search-and-play, the one intent that does more than move the transport.
///
/// Mirrors the phone's `PlaySearchIntent` including its honesty rule: the dialog reports
/// what actually happened rather than promising something. "Playing X" after finding
/// nothing is the kind of small lie that makes people stop trusting an assistant.
struct MacPlaySearchIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play songs matching"
    static let description = IntentDescription("Search your library and play the results.")

    @Parameter(title: "Search")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = MacIntentServices.model else {
            return .result(dialog: "Baton isn't ready yet.")
        }
        await model.musicLibrary.search(query)
        let songs = model.musicLibrary.searchResults.songs
        guard !songs.isEmpty else {
            return .result(dialog: "Nothing in your library matches “\(query)”.")
        }
        model.music.play(songs, source: .init(label: query, kind: .search))
        return .result(dialog: "Playing \(songs.first?.title ?? "your music").")
    }
}

struct BatonMacShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: MacPlaySearchIntent(),
            phrases: [
                "Play something in \(.applicationName)",
                "Play music in \(.applicationName)",
            ],
            shortTitle: "Play music",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: MacPlayMusicIntent(),
            phrases: ["Resume \(.applicationName)"],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: MacNextTrackIntent(),
            phrases: ["Skip this track in \(.applicationName)"],
            shortTitle: "Next track",
            systemImageName: "forward.fill"
        )
    }
}
