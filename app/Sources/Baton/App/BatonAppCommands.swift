import SwiftUI

/// Baton's app-menu customizations: a custom About panel, the Settings item, an enriched
/// **Audio** menu (equalizer + quick playback toggles), and suppression of the default
/// File → New Window (a music player wants one library window, not a duplicate sharing one
/// transport).
///
/// The Help menu is wired by `HelpMenuCommands` (⌘?), transport by `PlaybackMenuCommands`,
/// and navigation by `GoMenuCommands`.
struct BatonAppCommands: Commands {
    let model: MusicModel
    @Environment(\.openWindow) private var openWindow

    private var player: StreamingPlaybackController { model.music }

    var body: some Commands {
        // Replace the default "About <App>" with our custom panel.
        CommandGroup(replacing: .appInfo) {
            Button("About Baton") {
                openWindow(id: BatonApp.aboutWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // A music player wants a single library window; the default File → New Window (⌘N) opens
        // a second one that shares one transport — confusing. Suppress it. (menu review #1)
        CommandGroup(replacing: .newItem) {}

        // File → Save Reading as Audio…, the export for read aloud. The File menu
        // rather than the speaking HUD, because the HUD is dismissed the moment a reading ends
        // and this is most often wanted just after one. It stays available until the next
        // reading replaces it; the panel decides where the file goes, since readings themselves
        // are never saved (`specs/read-aloud.md`, decision 1).
        CommandGroup(replacing: .saveItem) {
            Button("Save Reading as Audio…") {
                ReadAloudCoordinator.current?.saveLastReading()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(ReadAloudCoordinator.current?.canExport != true)
        }

        // Standard Settings/Preferences slot (⌘,) → the unified Settings window.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: BatonSettingsView.windowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        // Audio menu → the equalizer plus quick toggles for the playback settings that otherwise
        // live only in Settings, so common audio tweaks are one keystroke away. (menu review #5)
        CommandMenu("Audio") {
            Button("Equalizer…") {
                UserDefaults.standard.set(
                    BatonSettingsCategory.equalizer.rawValue,
                    forKey: BatonSettingsView.selectionKey
                )
                openWindow(id: BatonSettingsView.windowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("e", modifiers: [.command, .option])

            Divider()

            // Gapless and crossfade are mutually exclusive (matches Settings + the controller).
            Toggle("Gapless Playback", isOn: Binding(
                get: { player.gaplessEnabled },
                set: { player.gaplessEnabled = $0 }
            ))
            .disabled(player.crossfadeSeconds >= 0.5)

            Toggle("Crossfade", isOn: Binding(
                get: { player.crossfadeSeconds >= 0.5 },
                set: { player.crossfadeSeconds = $0 ? 6 : 0 }
            ))

            Picker("Loudness", selection: Binding(
                get: { player.loudnessMode },
                set: { player.loudnessMode = $0 }
            )) {
                Text("Off").tag(StreamingPlaybackController.LoudnessMode.off)
                Text("Track").tag(StreamingPlaybackController.LoudnessMode.track)
                Text("Album").tag(StreamingPlaybackController.LoudnessMode.album)
            }
        }
    }
}
