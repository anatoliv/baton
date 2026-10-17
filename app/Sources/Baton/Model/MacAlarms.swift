import AppKit
import BatonPlaybackKit
import Foundation
import SwiftUI

/// The Mac's Alarm and Timer (TBX-11171, specs/alarm-and-timer.md). macOS has no AlarmKit for
/// apps, so Baton's own clock is the alarm while it runs (it lives in the menu bar), and a
/// scheduled notification stands in for when it does not. The ringing card floats over every
/// Space, as the speaking HUD does.
@MainActor
@Observable
final class MacAlarms {
    let store: AlarmStore
    let center: AlarmCenter
    /// What the alarm window shows: set by a menu, then the window is opened.
    var request: AlarmRequest?
    @ObservationIgnored private var chime: NSSound?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var started = false

    static let editorWindowID = "baton-alarm"

    init(player: StreamingPlaybackController, defaults: UserDefaults = BatonStorage.defaults) {
        store = AlarmStore(defaults: defaults)
        center = AlarmCenter(store: store, player: player)
    }

    /// Starts the clock. `systemNotifications` is off in tests, which must not schedule real
    /// notifications.
    func start(model: MusicModel, systemNotifications: Bool = true) {
        guard !started else { return }
        started = true
        center.playChime = { [weak self] in self?.playChime() }
        center.stopChime = { [weak self] in self?.chime?.stop() }
        center.notify = { [weak model] text in model?.music.postToast(text, symbol: "alarm", seconds: 6) }
        if systemNotifications, !Self.systemSwitchedOff {
            center.system = AlarmNotificationBridge()
            Task { await AlarmNotificationBridge.registerCategories() }
        }
        center.start()
        observeRinging()
        #if DEBUG
        seedProbeTimer()
        #endif
    }

    /// `BATON_DEBUG_ALARM_SYSTEM=off` keeps a probe from scheduling real notifications (and from
    /// asking for permission on the owner's screen). Environment only.
    static var systemSwitchedOff: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BATON_DEBUG_ALARM_SYSTEM"] == "off"
        #else
        false
        #endif
    }

    #if DEBUG
    /// A probe's timer, set at launch: `BATON_DEBUG_ALARM_PROBE_TIMER=<seconds>|<file URL>` starts a
    /// timer that plays that file, so an isolated probe can be watched going off with no clicks.
    private func seedProbeTimer() {
        guard let spec = ProcessInfo.processInfo.environment["BATON_DEBUG_ALARM_PROBE_TIMER"],
              let bar = spec.firstIndex(of: "|"), let seconds = Double(spec[..<bar]),
              let url = URL(string: String(spec[spec.index(after: bar)...])), url.isFileURL else { return }
        let song = NavidromeSong(id: url.absoluteString, title: url.deletingPathExtension().lastPathComponent, artist: "Probe")
        store.startTimer(duration: seconds, label: "Probe timer", choice: .song(song))
    }
    #endif

    /// What the player holds now, as an alarm would play it.
    static func nowPlaying(_ model: MusicModel) -> AlarmChoice? {
        let player = model.music
        let isBook = player.nowPlaying.flatMap { model.clippings.item(forSongID: $0.id)?.clipping.isBookChapter } ?? false
        return AlarmChoice.queue(player.queue, at: player.currentIndex, source: player.queueSource, isBook: isBook)
    }

    private func playChime() {
        guard let url = Bundle.main.url(forResource: "BatonAlarmChime", withExtension: "caf"),
              let sound = NSSound(contentsOf: url, byReference: true) else { return }
        sound.loops = true
        chime = sound
        sound.play()
    }

    // MARK: The ringing card

    private func observeRinging() {
        withObservationTracking {
            _ = center.ringing
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncPanel()
                self.observeRinging()
            }
        }
    }

    private func syncPanel() {
        guard center.ringing != nil else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                                         y: screen.visibleFrame.maxY - size.height - 40))
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 330),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: AlarmRingingCard(center: center).padding(8).tint(.batonOrange))
        return panel
    }
}

/// "Set Alarm…" and "Start Timer…" for a Mac menu, for `choice` (or what is playing).
struct MacAlarmMenuItems: View {
    let model: MusicModel
    let choice: AlarmChoice?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Set Alarm…", systemImage: "alarm") { open(.newAlarm(choice ?? MacAlarms.nowPlaying(model))) }
        Button("Start Timer…", systemImage: "timer") { open(.timer(choice ?? MacAlarms.nowPlaying(model))) }
    }

    private func open(_ request: AlarmRequest) {
        model.alarms.request = request
        openWindow(id: MacAlarms.editorWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The window the menus open: the editor or the timer, or the list when opened on its own.
struct MacAlarmWindow: View {
    @Environment(MusicModel.self) private var model

    var body: some View {
        let request = model.alarms.request ?? .list
        AlarmSheet(request: request, center: model.alarms.center, nowPlaying: { MacAlarms.nowPlaying(model) })
            .id(request.id)
            .onDisappear { model.alarms.request = nil }
    }
}

/// Settings > Alarms & Timer: Clock's list, in a pane.
struct BatonAlarmsPane: View {
    @Environment(MusicModel.self) private var model

    var body: some View {
        NavigationStack {
            AlarmsHomeView(center: model.alarms.center, nowPlaying: { MacAlarms.nowPlaying(model) })
        }
    }
}
