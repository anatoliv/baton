import SwiftUI

/// Bridges menu-bar commands — which live outside the SwiftUI view tree — into the main music
/// window's local state. A command raises an intent here; `MusicView` (and the search view)
/// observe it and act, clearing single-shot intents so they don't re-fire. `BatonApp` creates
/// it, injects it into the window's environment, and hands it to the command structs.
@MainActor
@Observable
final class BatonCommandRouter {
    /// A left-rail section the Go menu asked to switch to. `MusicView` consumes + clears it.
    var pendingTab: MusicView.MusicTab?
    /// Bumped by **Find** (⌘F): switch to Search and focus its field.
    var focusSearchToken = 0
    /// Bumped by **Now Playing** (⌘0): open the full-screen hero.
    var showNowPlayingToken = 0
}

/// The **Go** menu: jump to any left-rail section (⌘1…⌘8), Find (⌘F → Search + focus),
/// Now Playing (⌘0), and Toggle Sidebar (⌃⌘S). Navigation that used to be sidebar-only.
/// (menu review #2 + #3)
struct GoMenuCommands: Commands {
    let router: BatonCommandRouter
    /// Same key `MusicView` binds, so toggling here collapses/expands its rail.
    @AppStorage("tonebox.music.railCollapsed") private var railCollapsed = false

    var body: some Commands {
        CommandMenu("Go") {
            Button("Home") { router.pendingTab = .home }.keyboardShortcut("1", modifiers: .command)
            Button("Search") { router.pendingTab = .search }.keyboardShortcut("2", modifiers: .command)
            Button("Mixes") { router.pendingTab = .mixes }.keyboardShortcut("3", modifiers: .command)
            Button("Albums") { router.pendingTab = .albums }.keyboardShortcut("4", modifiers: .command)
            Button("Artists") { router.pendingTab = .artists }.keyboardShortcut("5", modifiers: .command)
            Button("Playlists") { router.pendingTab = .playlists }.keyboardShortcut("6", modifiers: .command)
            Button("Liked") { router.pendingTab = .starred }.keyboardShortcut("7", modifiers: .command)
            Button("History") { router.pendingTab = .history }.keyboardShortcut("8", modifiers: .command)

            Divider()

            Button("Find…") {
                router.pendingTab = .search
                router.focusSearchToken += 1
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Now Playing") { router.showNowPlayingToken += 1 }
                .keyboardShortcut("0", modifiers: .command)

            Divider()

            Button(railCollapsed ? "Show Sidebar" : "Hide Sidebar") { railCollapsed.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }
}
