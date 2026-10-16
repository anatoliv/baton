import BatonSubsonicKit
import SwiftUI
import UniformTypeIdentifiers

/// Baton's app-menu customizations: a custom About panel, the Settings item, an enriched
/// **Audio** menu (equalizer + quick playback toggles), and suppression of the default
/// File → New Window (a music player wants one library window, not a duplicate sharing one
/// transport).
///
/// The Help menu is wired by `HelpMenuCommands` (⌘?), transport by `PlaybackMenuCommands`,
/// and navigation by `GoMenuCommands`.
struct BatonAppCommands: Commands {
    let model: MusicModel
    let router: BatonCommandRouter
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

            // Keeping it in Baton rather than exporting it to a folder. Same audio, different
            // owner: this copy lives in Clippings, plays through the ordinary player, and is
            // managed from there.
            Button("Keep Reading in Clippings") {
                ReadAloudCoordinator.current?.keepLastReadingAsClipping()
            }
            .disabled(ReadAloudCoordinator.current?.canExport != true)

            // Resume an article you stopped part-way. A menu rather than the Later
            // tab: that tab's items are server entities that play through the music controller,
            // and a reading is neither. See `UnfinishedReadings`.
            Menu("Resume Reading") {
                let unfinished = ReadAloudCoordinator.current?.unfinished
                let entries = unfinished?.entries ?? []
                if entries.isEmpty {
                    Text("Nothing to resume")
                } else {
                    ForEach(entries) { entry in
                        Button(entry.menuTitle) {
                            ReadAloudCoordinator.current?.resume(entry)
                        }
                    }
                    Divider()
                    Button("Forget Saved Readings") { unfinished?.clear() }
                }
            }

            // A file in, a narrated book out (document clippings). Shown unless Settings → Speech →
            // Documents is off; the sheet opens over Books, where the book will appear.
            // Read live: the items come and go with the switch, no relaunch.
            if model.documentsSwitch.isOn {
                Divider()
                Button("Import Document…") { chooseDocument() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Import Link…") { chooseLink() }
            }
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
                BatonStorage.defaults.set(
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

    /// Ask for a web address, offering the one on the clipboard, and hand it to Clippings.
    private func chooseLink() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://"
        if let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: copied), DocumentLibrary.isWebLink(url) {
            field.stringValue = copied
        }
        let alert = NSAlert()
        alert.messageText = "Import Link"
        alert.informativeText = "Baton reads the article on the page and makes it a narrated book in Books."
        alert.accessoryView = field
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              DocumentLibrary.isWebLink(url) else { return }
        router.pendingTab = .books
        router.pendingDocumentImport = url
    }

    /// Pick a file and hand it to Books, which shows what was found before anything is made.
    private func chooseDocument() {
        let panel = NSOpenPanel()
        panel.title = "Import Document"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DocumentLibrary.importableTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        router.pendingTab = .books
        router.pendingDocumentImport = url
    }
}
