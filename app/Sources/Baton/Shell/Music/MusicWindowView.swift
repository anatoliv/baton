import AppKit
import SwiftUI

/// Pop-out full music player. Hosts the same `MusicView` used inline; the queue,
/// playback, and library state are shared `@Observable` state on `AppModel`, so
/// controlling music here and in the status-bar mini pill stay in sync.
///
/// Opened via `openWindow(id: MusicWindowView.windowID)`; the scene is declared in
/// `App.swift`.
struct MusicWindowView: View {
    static let windowID = "tonebox-music"

    @Environment(MusicModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    // Shared with MusicView's rail: when the rail is collapsed it's too narrow for the
    // three traffic lights, so we hide them and the rail shows a single red close button.
    @AppStorage("tonebox.music.railCollapsed") private var railCollapsed = false

    var body: some View {
        MusicView()
            .frame(minWidth: 560, minHeight: 520)
            // Inject the close action so the rail's custom close button (collapsed only)
            // appears in the pop-out, not inline.
            .environment(\.musicWindowClose, { dismissWindow(id: MusicWindowView.windowID) })
            .ignoresSafeArea(.container, edges: .top)
            .background(MusicWindowConfigurator(showTrafficLights: !railCollapsed))
    }
}

/// A close action injected into the windowed `MusicView` so its rail can show a single
/// custom close button. `nil` inline (main-window Music view has no window to close).
private struct MusicWindowCloseKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}

extension EnvironmentValues {
    var musicWindowClose: (@MainActor @Sendable () -> Void)? {
        get { self[MusicWindowCloseKey.self] }
        set { self[MusicWindowCloseKey.self] = newValue }
    }
}

/// Removes the title bar. The traffic-light window controls are shown when the rail is
/// expanded and hidden when it's collapsed (too narrow for them — the rail shows a single
/// red close button then). Stays a normal **titled** window so it keeps resizing and can
/// become key (it browses text-searchable lists); the title bar is just transparent +
/// hidden and content fills the full height. Dragging works from any empty background area
/// via `isMovableByWindowBackground`.
///
/// A one-shot setup isn't enough: when the window resigns key/main, AppKit re-draws
/// the (now inactive) title bar as a grey band and SwiftUI resets some of these
/// properties. A `Coordinator` re-asserts the chromeless config on every key/main
/// transition so the bar never reappears.
private struct MusicWindowConfigurator: NSViewRepresentable {
    /// Expanded rail → show the three traffic lights; collapsed → hide them (the rail
    /// shows a single red close button instead).
    var showTrafficLights: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        let show = showTrafficLights
        DispatchQueue.main.async { MainActor.assumeIsolated { coordinator.attach(to: view.window, showTrafficLights: show) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        let show = showTrafficLights
        DispatchQueue.main.async { MainActor.assumeIsolated { coordinator.attach(to: nsView.window, showTrafficLights: show) } }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var showTrafficLights = true
        private let observers = ObserverBag()

        func attach(to window: NSWindow?, showTrafficLights: Bool) {
            self.showTrafficLights = showTrafficLights
            guard let window else { return }
            if self.window !== window {
                observers.clear()
                self.window = window
                // Any state change that makes AppKit redraw the title bar → re-assert.
                let names: [NSNotification.Name] = [
                    NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                    NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                ]
                for name in names {
                    let obs = NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.apply() }
                    }
                    observers.tokens.append(obs)
                }
            }
            apply()
        }

        private func apply() {
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            // Expanded rail has room for the traffic lights; collapsed doesn't, so hide
            // them (the rail's single red close button takes over). ⌘W always closes.
            for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = !showTrafficLights
            }
        }
    }
}

/// Holds NotificationCenter block-observer tokens. A plain (non-isolated) class so its
/// `deinit` can unregister them — a `@MainActor` type's nonisolated deinit can't touch
/// the non-Sendable token array.
private final class ObserverBag {
    var tokens: [any NSObjectProtocol] = []
    func clear() {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens.removeAll()
    }
    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}
