import SwiftUI

/// Baton's app-menu customizations. Replaces the standard "About" menu item with
/// one that opens our custom `BatonAboutView` panel (a dedicated utility window,
/// declared in `BatonApp`), and adds a Help item that points at the About panel
/// as a lightweight "what is this" affordance.
///
/// `PlaybackMenuCommands` (the Playback menu) stays wired separately in `BatonApp`.
struct BatonAppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Replace the default "About <App>" with our custom panel.
        CommandGroup(replacing: .appInfo) {
            Button("About Baton") {
                openWindow(id: BatonApp.aboutWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // A minimal Help menu entry (SwiftUI keeps the standard Help placeholder
        // otherwise-empty; give it something that explains the product).
        CommandGroup(replacing: .help) {
            Button("About Baton") {
                openWindow(id: BatonApp.aboutWindowID)
                NSApp.activate(ignoringOtherApps: true)
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

        // Audio menu → the equalizer, which now lives in Settings. Pre-select the
        // Equalizer pane, then open Settings so ⌥⌘E lands the user right on the EQ.
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
        }
    }
}
