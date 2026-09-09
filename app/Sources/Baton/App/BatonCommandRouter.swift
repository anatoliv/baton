import BatonSubsonicKit
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
    /// Bumped by **Show Queue** (⌘U): open the now-playing bar's queue popover.
    var showQueueToken = 0
    /// Bumped by **Refresh Library** (⌘R): refetch all collections + radio/podcast stores.
    var refreshLibraryToken = 0
    /// A "Playing from" deep link raised by the full-screen player: navigate to the current
    /// queue's source (album / playlist / artist). `MusicView` resolves it to the matching
    /// section + detail view, then clears it.
    var pendingSourceNavigation: StreamingPlaybackController.QueueSource?
}

/// The **Go** menu: jump to any left-rail section (⌘1…⌘8), Find (⌘F → Search + focus),
/// Now Playing (⌘0), and Toggle Sidebar (⌃⌘S). Navigation that used to be sidebar-only.
/// (menu review #2 + #3)
struct GoMenuCommands: Commands {
    let router: BatonCommandRouter
    /// Same key `MusicView` binds, so toggling here collapses/expands its rail.
    @AppStorage("tonebox.music.railCollapsed", store: BatonStorage.defaults)
    private var railCollapsed = false

    /// Every section the menu lists, in the same order the left rail draws them.
    ///
    /// This was a hand-written list of twelve while `MusicTab` had fourteen cases, so Clippings
    /// and Folders had no menu entry at all. That is not cosmetic: `MusicView`'s own comment
    /// promises that "hidden sections stay reachable from the Go menu", and right-click → Hide
    /// removes the rail row, which was the only other route. Two sections could be hidden and
    /// then not found again. Driving both the rail and the menu from `allCases` is the same
    /// "when something exists in more than one place, put it in one" rule the rail already
    /// follows.
    static let sections = MusicView.MusicTab.allCases

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(Self.sections) { section in
                Button(section.label) { router.pendingTab = section }
                    .keyboardShortcut(section.goShortcut.map { KeyboardShortcut($0, modifiers: .command) })
            }

            Divider()

            Button("Find…") {
                router.pendingTab = .search
                router.focusSearchToken += 1
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Now Playing") { router.showNowPlayingToken += 1 }
                .keyboardShortcut("0", modifiers: .command)

            Button("Refresh Library") { router.refreshLibraryToken += 1 }
                .keyboardShortcut("r", modifiers: .command)

            Divider()

            // Its own window, so it opens rather than navigating. ⌘⇧F because ⌘F is Find and
            // a conversation is a place you go to, not a tab you switch to.
            OpenMusicFriendButton()

            Divider()

            Button(railCollapsed ? "Show Sidebar" : "Hide Sidebar") { railCollapsed.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }
}

/// Opens the Music Friend window from the Go menu.
///
/// A view rather than an inline `Button` because `openWindow` is an environment value, and
/// `Commands` bodies are not views — reading it needs somewhere with an environment.
private struct OpenMusicFriendButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Music Friend") { openWindow(id: MacMusicFriendView.windowID) }
            .keyboardShortcut("f", modifiers: [.command, .shift])
    }
}
