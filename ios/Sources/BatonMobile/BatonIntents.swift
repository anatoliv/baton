import AppIntents
import Foundation

/// Siri / Shortcuts entry points. These wrap the same command surface the agent and
/// the UI use, so "Hey Siri" and the chat brain never drift apart. The intents run
/// in-process (the app hosts them), which keeps them bound to the live engine.
///
/// iOS 18 baseline: classic App Intents + App Shortcuts phrases. The iOS 27
/// assistant-schema variants (play-without-naming-the-app, Shelv-style) layer on
/// later without changing these.
struct PlayMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play music"
    static let description = IntentDescription("Resume playback in Baton.")

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.shared?.music.resume()
        return .result()
    }
}

struct PauseMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause music"
    static let description = IntentDescription("Pause playback in Baton.")

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.shared?.music.pause()
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next track"
    static let description = IntentDescription("Skip to the next track in Baton.")

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.shared?.music.next()
        return .result()
    }
}

struct PlaySearchIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play songs matching"
    static let description = IntentDescription("Search your Navidrome library and play the results.")

    @Parameter(title: "What to play")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let services = AppServices.shared else {
            return .result(dialog: "Baton isn't ready yet.")
        }
        await services.musicLibrary.search(query)
        let songs = services.musicLibrary.searchResults.songs
        guard !songs.isEmpty else {
            return .result(dialog: "Nothing in your library matches “\(query)”.")
        }
        services.music.play(songs, source: .init(label: query, kind: .search))
        // A truthful answer, not a promise — the queue is set and playing now.
        return .result(dialog: "Playing \(songs.first?.title ?? "your music").")
    }
}

struct BatonShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // A free-text parameter can't be interpolated into Siri phrases (only
        // AppEntity/AppEnum can) — Siri asks "what do you want to play?" instead.
        // Library-entity phrases arrive with the assistant-schema pass.
        AppShortcut(
            intent: PlaySearchIntent(),
            phrases: [
                "Play something in \(.applicationName)",
                "Play music in \(.applicationName)",
            ],
            shortTitle: "Play music",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: ["Resume \(.applicationName)"],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
    }
}

/// The intents' bridge to the live composition root. Set once at app start; nil only
/// in the brief window before the app body runs (intents answer honestly then).
@MainActor
enum AppServicesHolder {
    static var model: MobileModel?
}

/// Small indirection so intents read naturally.
@MainActor
enum AppServices {
    static var shared: MobileModel? { AppServicesHolder.model }
}
