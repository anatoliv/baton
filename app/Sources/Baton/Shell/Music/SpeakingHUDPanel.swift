import AppKit
import Observation
import SwiftUI

/// The **speaking HUD** as a small, self-contained floating panel.
///
/// A spoken summary is usually triggered by an agent (the `speak_summary` MCP tool) while the
/// user is working in another app, so the old in-app overlay — pinned to the bottom of the main
/// Baton window — was unreachable exactly when it mattered (window closed, minimized, or on
/// another Space). This lifts the pause / resume / stop controls into an independent `NSPanel`
/// that floats over whatever Space/app is active while a summary plays, then hides when it ends.
///
/// Treatment mirrors `MiniPlayerWindowConfigurator`: borderless + transparent so the glass
/// refracts what's behind it, always-on-top, non-activating (clicking a control never steals
/// focus from the user's frontmost app), joins **all Spaces + fullscreen**, and is draggable —
/// its last drop position is remembered across summaries and launches.
///
/// The waiting-to-play `banner` (mode = "banner") deliberately stays in-app (see
/// `SpeechAlertOverlay`): pressing Play there is a "look at Baton" interaction, not a live control.
@MainActor
final class SpeakingHUDPresenter {
    private let model: MusicModel
    private var speech: SpeechPlaybackEngine { model.speech }
    private var panel: FloatingHUDPanel?
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?

    /// Persisted panel frame (size + position) — its "remember last size + position". Stored as an
    /// `NSStringFromRect` string so a fresh install starts at the default, and returning users don't.
    private static let frameDefaultsKey = "BatonSpeakingHUDFrame"

    init(model: MusicModel) {
        self.model = model
        armObservation()
        syncVisibility() // handle the (rare) case where a summary is already speaking at wire-up
    }

    // MARK: - Observation

    /// Re-arming, view-less observation of `speech.isSpeaking` — the panel's visibility is the
    /// only thing driven from AppKit; the SwiftUI content observes the rest of the engine itself.
    private func armObservation() {
        withObservationTracking {
            _ = speech.isSpeaking
            _ = model.summariesWindowIsForeground // hide the HUD while the window shows it inline
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncVisibility()
                self.armObservation()
            }
        }
    }

    /// After a summary finishes, the card lingers this long for Replay before auto-closing.
    private static let autoCloseDelay: Duration = .seconds(60)
    private var autoCloseTask: Task<Void, Never>?
    /// Set by `userClose()` so the finish that `cancel()` triggers can't re-linger the card — the ×
    /// always wins and the window closes. Cleared when the next summary starts speaking.
    private var userClosed = false

    private func syncVisibility() {
        // While the Spoken Summaries window is focused, it plays the summary inline in its detail
        // pane — so the floating HUD keeps out of the way (no redundant card on top of the window).
        let windowShowsInline = model.summariesWindowIsForeground
        if speech.isSpeaking {
            userClosed = false
            autoCloseTask?.cancel()
            autoCloseTask = nil
            if windowShowsInline { panel?.orderOut(nil) } else { show() }
        } else if !userClosed, !windowShowsInline, let panel, panel.isVisible, speech.canReplay {
            // A summary just finished: keep the card up for Replay, then auto-close after a minute.
            scheduleAutoClose()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func scheduleAutoClose() {
        autoCloseTask?.cancel()
        autoCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: SpeakingHUDPresenter.autoCloseDelay)
            guard let self, !Task.isCancelled else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// The card's × button — stop speaking and close the window immediately, and make sure the
    /// linger-for-Replay path can't bring it back (so × reliably closes without more speech). Also
    /// dismisses the in-app "Play" banner for the same summary, so both close together.
    fileprivate func userClose() {
        userClosed = true
        autoCloseTask?.cancel()
        autoCloseTask = nil
        speech.cancel() // stop any audio now (silent close)
        speech.dismissBanner() // close the in-app banner for this summary at the same time
        panel?.orderOut(nil)
    }

    // MARK: - Panel lifecycle

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        restorePosition(panel)
        panel.orderFrontRegardless() // show without activating Baton or stealing key focus
    }

    /// The card's default size and its resize floor — same width as `MiniPlayerWindowView`. The
    /// panel is **user-resizable** (drag any edge); the content fills whatever size you pick, and
    /// the last size + position are remembered.
    static let defaultSize = NSSize(width: 320, height: 230)
    static let minSize = NSSize(width: 260, height: 150)
    /// Corner radius of the card (and the window's content layer, so the shadow follows the shape).
    static let cornerRadius: CGFloat = 16

    private func makePanel() -> FloatingHUDPanel {
        let hosting = NSHostingController(
            rootView: SpeakingHUDContent(
                onClose: { [weak self] in self?.userClose() }
            )
            .environment(model)
            .tint(.batonOrange)
        )

        let panel = FloatingHUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        panel.contentViewController = hosting
        panel.contentMinSize = Self.minSize
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true // drag the HUD body to move it (edges resize)
        panel.acceptsMouseMovedEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Follow the user everywhere, including over other apps in fullscreen (W: all Spaces).
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        // NB: we deliberately do NOT round/clip the window's content layer (no `masksToBounds`).
        // A clipping layer on a live-resizing borderless panel makes the hosted SwiftUI ScrollView
        // blank out mid-resize. The rounded look comes from the SwiftUI `speakingCardSurface`
        // instead, and the window's shadow is derived from that content's (rounded) alpha shape.

        // Remember the last size + position (persist the whole frame on move OR resize).
        let persist: @Sendable (Notification) -> Void = { [weak panel] _ in
            guard let panel else { return }
            MainActor.assumeIsolated {
                panel.invalidateShadow()
                UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameDefaultsKey)
            }
        }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main, using: persist
        )
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main, using: persist
        )
        return panel
    }

    // MARK: - Frame ("remember last size + position", clamped to a live screen)

    private func restorePosition(_ panel: NSPanel) {
        if let frame = savedFrame(), frameIsOnScreen(frame) {
            panel.setFrame(frame, display: false)
        } else {
            positionBottomCenter(panel)
        }
    }

    private func savedFrame() -> NSRect? {
        guard let s = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) else { return nil }
        let r = NSRectFromString(s)
        return r.isEmpty ? nil : r
    }

    /// A remembered frame is only reused if it still lands on a connected display — otherwise a
    /// since-disconnected monitor would strand the HUD off-screen.
    private func frameIsOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    /// First-run default: default size, bottom-center of the **active** display. `NSScreen.main` is
    /// the screen with the active/key window.
    private func positionBottomCenter(_ panel: NSPanel) {
        panel.setContentSize(Self.defaultSize)
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24))
    }
}

/// A borderless panel that can still become key so the HUD's buttons are clickable — a plain
/// borderless `NSWindow` cannot. Combined with `.nonactivatingPanel`, clicking a control acts on
/// the HUD without activating Baton or pulling focus from the user's frontmost app.
final class FloatingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The HUD body: the shared `SpeakingPlayerView` (transcript · scrubber · ∓10s / Play-Pause-Replay
/// transport) wrapped in the glass card that mirrors `MiniPlayerWindowView` — same width, corner
/// radius, glass surface, and a forced dark scheme. A history glyph in the top-left corner opens the
/// full "Spoken Summaries" window, and an × in the top-right corner stops & closes. Reads live state
/// from `model.speech`; the same player is embedded, chrome-less, in that window's detail pane.
private struct SpeakingHUDContent: View {
    @Environment(\.openWindow) private var openWindow
    /// × button — stop speaking and dismiss (wired to the presenter's `userClose()`).
    var onClose: () -> Void

    var body: some View {
        SpeakingPlayerView()
            .padding(14)
            // Fill whatever size the (resizable) window is — the transcript takes the slack, so
            // there's never a forced gap; resize the window to taste.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // History glyph top-left / × top-right — two small secondary controls in the card's
            // top corners (the transcript is inset from both to clear them).
            .overlay(alignment: .topLeading) { historyButton.padding(7) }
            .overlay(alignment: .topTrailing) { closeButton.padding(7) }
            .speakingCardSurface(cornerRadius: SpeakingHUDPresenter.cornerRadius)
            .preferredColorScheme(.dark)
    }

    /// Opens the "Spoken Summaries" window to replay any past summary — the HUD is the surface
    /// you're actually looking at when one plays, so it doubles as the entry to the full history.
    private var historyButton: some View {
        Button {
            openWindow(id: SpeechHistoryView.windowID)
            NSApp.activate(ignoringOtherApps: true) // bring the (non-activating) HUD's app forward
        } label: {
            Image(systemName: "list.bullet")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Recent summaries")
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Stop & close")
    }
}
