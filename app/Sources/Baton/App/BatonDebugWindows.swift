import SwiftUI

#if DEBUG
import AppKit

/// Opens and closes Baton's own windows from launch arguments, so an unattended probe can
/// photograph a window without touching the screen. DEBUG builds only.
///
/// Why this exists. Screenshots are owed on several cards because a probe build cannot reach
/// the window it has to photograph. The owner's Baton runs on this same Mac with real data, so
/// two obvious routes are both barred: `System Events` resolves the name "Baton" to the owner's
/// process rather than to the probe's pid, and a click at screen coordinates inside a
/// pid-verified window has already landed on a different process's window when the z-order
/// moved between the check and the click. Posting key events is pid-scoped but still
/// depends on which window is key. These flags remove input from the problem: the probe opens
/// the window inside its own process, from its own launch arguments.
///
///     Baton.app/Contents/MacOS/Baton -baton.defaultsSuite probe-1 \
///         -baton.debugCloseMainWindow -baton.debugOpenWindow settings
///
/// `-baton.debugOpenWindow` takes one of `settings`, `help`, `miniPlayer`, `main`.
/// `-baton.debugCloseMainWindow` closes the main library window first, which is what a card
/// about a pane being empty with the main window closed needs. Both are applied once, after
/// launch, on the main actor. Neither is compiled into a release build.
@MainActor
enum BatonDebugWindows {
    static let openFlag = "-baton.debugOpenWindow"
    static let closeMainFlag = "-baton.debugCloseMainWindow"

    /// SwiftUI hands `openWindow` out only to views, so the first view that renders lends the
    /// app one. Registering is idempotent and applying happens once.
    private static var open: OpenWindowAction?
    private static var applied = false

    /// The scene id named by `-baton.debugOpenWindow <name>`, or nil when the flag is absent
    /// or names something unknown.
    static func requestedWindowID(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let flag = arguments.firstIndex(of: openFlag), arguments.indices.contains(flag + 1) else { return nil }
        switch arguments[flag + 1] {
        case "settings": return BatonSettingsView.windowID
        case "help": return BatonHelpView.windowID
        case "miniPlayer": return MiniPlayerWindowView.windowID
        case "main": return MusicWindowView.windowID
        default: return nil
        }
    }

    static func closesMainWindow(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(closeMainFlag)
    }

    static func register(_ action: OpenWindowAction) {
        guard open == nil else { return }
        open = action
        apply()
    }

    private static func apply() {
        guard !applied, let open else { return }
        let windowID = requestedWindowID()
        guard windowID != nil || closesMainWindow() else { return }
        applied = true
        Task { @MainActor in
            if closesMainWindow() {
                closeMainWindow()
                // One turn for AppKit to actually tear the window down, so a screenshot taken
                // straight afterwards does not catch it on its way out.
                try? await Task.sleep(for: .milliseconds(400))
            }
            if let windowID { open(id: windowID) }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static func closeMainWindow() {
        for window in NSApp.windows where isMainLibraryWindow(window) {
            window.close()
        }
    }

    /// The main window carries a hidden title bar, so match on the scene id SwiftUI puts in the
    /// window identifier and fall back to the title AppKit still holds for it.
    private static func isMainLibraryWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue.contains(MusicWindowView.windowID) == true { return true }
        return window.title == "Baton"
    }
}

/// Lends `BatonDebugWindows` an `openWindow` from whatever view renders first.
private struct BatonDebugWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task { BatonDebugWindows.register(openWindow) }
    }
}
#endif

extension View {
    /// Lends this view's `openWindow` to the DEBUG-only `-baton.debugOpenWindow` launch flag.
    /// Nothing at all in a release build.
    func batonDebugWindowOpener() -> some View {
        #if DEBUG
        return modifier(BatonDebugWindowOpener())
        #else
        return self
        #endif
    }
}
