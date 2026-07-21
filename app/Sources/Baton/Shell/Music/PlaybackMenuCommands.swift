import SwiftUI

/// App-level "Playback" menu — transport, volume, shuffle/repeat for the music
/// player, reachable from anywhere in the app (not just the full-screen hero).
/// Folded into `AuxiliaryWindowCommands` so App.swift's `.commands { … }` builder
/// stays under its 10-child cap. Bindings read live `@Observable` player state, so
/// the labels (Play/Pause, Mute/Unmute, Repeat: …) reflect the current transport.
struct PlaybackMenuCommands: Commands {
    let model: MusicModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var player: StreamingPlaybackController { model.music }

    private var isBarMinimized: Bool { UserDefaults.standard.bool(forKey: "tonebox.music.barCollapsed") }

    private var repeatLabel: String {
        switch player.repeatMode {
        case .off: "Repeat: Off"
        case .all: "Repeat: All"
        case .one: "Repeat: One Track"
        }
    }

    var body: some Commands {
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") {
                player.isPlaying ? player.pause() : player.resume()
            }
            .keyboardShortcut("p", modifiers: [.command, .control])
            .disabled(player.nowPlaying == nil)

            Button("Next") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(player.queue.isEmpty)
            Button("Previous") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(player.queue.isEmpty)

            Divider()

            Button("Volume Up") { player.setVolume(percent: player.volumePercent + 5) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
            Button("Volume Down") { player.setVolume(percent: player.volumePercent - 5) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
            Button(player.isMuted ? "Unmute" : "Mute") { player.toggleMute() }
                .keyboardShortcut("m", modifiers: [.command, .control])

            Divider()

            Button(player.isShuffled ? "Shuffle: On" : "Shuffle: Off") { player.toggleShuffle() }
                .disabled(player.queue.isEmpty)
            Button(repeatLabel) { player.cycleRepeat() }
                .disabled(player.queue.isEmpty)

            Divider()

            Menu("Sleep Timer") {
                ForEach(SleepTimerOptions.minutes, id: \.self) { minutes in
                    Button(SleepTimerOptions.label(minutes)) { player.setSleepTimer(minutes: minutes) }
                }
                Button("End of Track") { player.sleepAtEndOfTrack() }
                if player.sleepTimerArmed {
                    Divider()
                    Button("Turn Off Sleep Timer") { player.cancelSleepTimer() }
                }
            }

            Divider()

            // Spoken-summary controls — enabled only while a summary is speaking, so a long one
            // can be paused/stopped without reaching for the HUD. (mirrors the HUD buttons)
            Button(model.speech.isPaused ? "Resume Speaking" : "Pause Speaking") {
                model.speech.togglePause()
            }
            .disabled(!model.speech.isSpeaking)
            Button("Stop Speaking") { model.speech.cancel() }
                .keyboardShortcut(".", modifiers: [.command, .control])
                .disabled(!model.speech.isSpeaking)

            Divider()

            Button(isBarMinimized ? "Expand Player Bar" : "Minimize Player Bar") {
                UserDefaults.standard.set(!isBarMinimized, forKey: "tonebox.music.barCollapsed")
            }
            .keyboardShortcut("j", modifiers: [.command, .control])

            Button("Mini Player") {
                openWindow(id: MiniPlayerWindowView.windowID)
                dismissWindow(id: MusicWindowView.windowID)
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
        }
    }
}
