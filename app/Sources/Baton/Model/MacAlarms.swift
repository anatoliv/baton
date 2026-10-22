import AppKit
import BatonPlaybackKit
import BatonSubsonicKit
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
    /// Lent by a view that is always drawn (the menu bar label, the main window), so the ringing
    /// card can bring the Baton window forward.
    @ObservationIgnored var openWindow: OpenWindowAction?
    @ObservationIgnored weak var router: BatonCommandRouter?
    @ObservationIgnored private weak var model: MusicModel?
    @ObservationIgnored private var chime: NSSound?
    /// Where a chime comes from: the bundled sound, or a test's silent one.
    @ObservationIgnored var makeChime: () -> NSSound? = {
        Bundle.main.url(forResource: "BatonAlarmChime", withExtension: "caf")
            .flatMap { NSSound(contentsOf: $0, byReference: true) }
    }
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
        self.model = model
        center.playChime = { [weak self] in self?.playChime() }
        // A radio station chosen to wake to plays through the radio engine.
        center.playRadio = { [weak model] station in
            model?.internetRadio.play(NavidromeRadioStation(id: station.id, name: station.name, streamUrl: station.streamURL))
        }
        center.stopRadio = { [weak model] in model?.internetRadio.stop() }
        center.rampRadio = { [weak model] in model?.internetRadio.engine.startWakeRamp() }
        center.radioIsPlaying = { [weak model] in model?.internetRadio.engine.isPlaying == true }
        center.showPlayer = { [weak self] in self?.showPlayer() }
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
    /// A probe's timer, set at launch: `BATON_DEBUG_ALARM_PROBE_TIMER=<seconds>|<file URL>[|<label>]`
    /// starts a timer that plays that file, so an isolated probe can be watched going off with no
    /// clicks. The label defaults to "Probe timer".
    private func seedProbeTimer() {
        guard let spec = ProcessInfo.processInfo.environment["BATON_DEBUG_ALARM_PROBE_TIMER"] else { return }
        let parts = spec.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let seconds = Double(parts[0]),
              let url = URL(string: parts[1]), url.isFileURL else { return }
        let label = parts.count > 2 && !parts[2].isEmpty ? parts[2] : "Probe timer"
        let song = NavidromeSong(id: url.absoluteString, title: url.deletingPathExtension().lastPathComponent, artist: "Probe")
        store.startTimer(duration: seconds, label: label, choice: .song(song))
    }
    #endif

    /// What the player holds now, as an alarm would play it.
    static func nowPlaying(_ model: MusicModel) -> AlarmChoice? {
        let player = model.music
        let isBook = player.nowPlaying.flatMap { model.clippings.item(forSongID: $0.id)?.clipping.isBookChapter } ?? false
        return AlarmChoice.queue(player.queue, at: player.currentIndex, source: player.queueSource, isBook: isBook)
    }

    /// "Keep playing, open player": Baton forward, its window open, the full-screen player up.
    func showPlayer() {
        NSApp.activate(ignoringOtherApps: true)
        let open = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix(MusicWindowView.windowID) == true }
        if !open { openWindow?(id: MusicWindowView.windowID) }
        router?.showNowPlayingToken += 1
        // A window opened just now was not there to see the first request.
        if !open {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.router?.showNowPlayingToken += 1
            }
        }
    }

    /// What the quick sheet needs: the defaults for "Then play" and the picker's library.
    var sheetContext: AlarmSheetContext {
        let model = model
        return AlarmSheetContext(
            center: center,
            nowPlaying: { model.flatMap(Self.nowPlaying) },
            lastPlayed: { model.flatMap { AlarmQuickSetup.lastPlayed($0.musicHistory) } },
            makeSource: {
                guard let model else { return MacEmptyPickerSource() }
                return LibraryAlarmPickerSource(library: model.musicLibrary, history: model.musicHistory,
                                                radio: model.internetRadio) { [weak model] in
                    guard let model, model.documentsSwitch.isOn else { return [] }
                    return model.documents.shelf.compactMap { book in
                        Self.bookChoice(book).map {
                            AlarmPickItem.book(documentID: book.documentID, title: book.title, author: book.author, choice: $0)
                        }
                    }
                }
            },
            makePreview: { model.map { AlarmPreviewPlayer(player: $0.music, radio: $0.internetRadio) } }
        )
    }

    /// A book as an alarm plays it, from where it was left.
    static func bookChoice(_ book: BookShelf.Book) -> AlarmChoice? {
        let (songs, start) = BookPlayback.queue(for: book)
        guard !songs.isEmpty else { return nil }
        return AlarmChoice(title: book.title, subtitle: book.author, kind: .book, songs: songs, startIndex: start,
                           source: BookTransport.source(documentID: book.documentID, title: book.title))
    }

    private func playChime() {
        guard let sound = makeChime() else { return }
        sound.loops = true
        // A second chime (an alarm and a timer together) replaces the first: stop it, or Stop
        // reaches only the newest and the first keeps looping.
        chime?.stop()
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
        // A fresh card for each ringing, and the panel exactly its size: the card is a fixed width
        // and as tall as its words, so nothing is cut off. The hosting view's
        // default sizing options keep the panel there while it is up.
        let host = NSHostingView(rootView: AlarmRingingCard(center: center).padding(8).tint(.batonOrange))
        // No title bar inset: the panel's title bar is hidden and transparent, and its safe area
        // would put an empty band about 33 pt tall above the card.
        host.safeAreaRegions = []
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        // The frame, not the content size: with a full-size content view the card fills the whole
        // frame, and `setContentSize` would add a title bar's height of empty panel.
        let size = host.fittingSize
        var origin = panel.frame.origin
        if let screen = NSScreen.main {
            origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 40)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: AlarmRingingCard.floatingWidth + 16, height: 420),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        return panel
    }
}

/// "Set Alarm…" and "Start Timer…" for a Mac menu: the quick sheet in its own small window, with
/// `choice` (or an album's or playlist's `item`, fetched in the sheet) as "Then play". A menu
/// cannot anchor a popover, so menus open the window; the player's clock opens the popover.
struct MacAlarmMenuItems: View {
    let model: MusicModel
    var choice: AlarmChoice?
    var item: AlarmPickItem?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Set Alarm…", systemImage: "alarm") {
            open(item.map { .pick(.alarm, $0) } ?? .newAlarm(choice ?? MacAlarms.nowPlaying(model)))
        }
        Button("Start Timer…", systemImage: "timer") {
            open(item.map { .pick(.timer, $0) } ?? .timer(choice ?? MacAlarms.nowPlaying(model)))
        }
    }

    private func open(_ request: AlarmRequest) {
        model.alarms.request = request
        openWindow(id: MacAlarms.editorWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The window the menus open: the quick sheet for what was asked, or the alarms on their own.
struct MacAlarmWindow: View {
    @Environment(MusicModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let request = model.alarms.request ?? .list
        AlarmQuickSheet(request: request, context: model.alarms.sheetContext) {
            dismissWindow(id: MacAlarms.editorWindowID)
        }
        .id(request.id)
        .frame(minWidth: 400, idealWidth: 420, minHeight: 520, idealHeight: 600)
        .onDisappear { model.alarms.request = nil }
        .alarmWindowOpener(model.alarms)
    }
}

/// The player's clock: the quick sheet as a popover. While a timer runs or an
/// alarm is due within a day, the pill stands beside it with the countdown and a ✕.
struct MacAlarmClockButton: View {

    @Environment(MusicModel.self) private var model
    var font: Font = .body
    var tint: Color = .secondary
    var showsPill = true
    @State private var showsSheet = false
    /// The clock opens Timer; the pill opens on what it shows.
    @State private var request: AlarmRequest = .timer(nil)
    /// The scheme where the clock sits: dark in the full-screen player, the app's elsewhere.
    @Environment(\.colorScheme) private var anchorScheme

    var body: some View {
        HStack(spacing: 6) {
            if showsPill {
                AlarmPill(center: model.alarms.center, open: { request = $0.request; showsSheet = true }, compact: true)
            }
            Button {
                request = .timer(nil)
                showsSheet = true
            } label: {
                Image(systemName: "alarm")
                    .font(font)
                    .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .help("Alarm and Timer")
            .accessibilityLabel("Alarm and Timer")
            .accessibilityIdentifier("player-alarm-clock")
        }
        .popover(isPresented: $showsSheet, arrowEdge: .top) {
            MacAlarmPopoverContent(scheme: anchorScheme) {
                AlarmQuickSheet(request: request, context: model.alarms.sheetContext) { showsSheet = false }
            }
        }
    }
}

/// The popover's content in the colour scheme of where the clock sits, on a background of that
/// scheme, with the ordinary label colour (the full-screen player's header otherwise passes its
/// white foreground into the popover, white text on a light popover).
private struct MacAlarmPopoverContent<Content: View>: View {
    let scheme: ColorScheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .scrollContentBackground(.hidden)
            .frame(width: 400, height: 580)
            .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.96))
            .tint(.batonOrange)
            // The full-screen player's header draws its controls white, and a popover's content
            // inherits that foreground style; the sheet's text is the ordinary label colour.
            .foregroundStyle(Color.primary)
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
    }
}

extension View {
    /// Lends this view's `openWindow` to the alarms, for the ringing card's "open player".
    func alarmWindowOpener(_ alarms: MacAlarms) -> some View {
        modifier(AlarmWindowOpener(alarms: alarms))
    }
}

private struct AlarmWindowOpener: ViewModifier {
    let alarms: MacAlarms
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { alarms.openWindow = openWindow }
    }
}

@MainActor
private final class MacEmptyPickerSource: AlarmPickerSource {
    func recent() -> [AlarmPickItem] { [] }
    func browse(_ section: AlarmPickerModel.Section) async -> [AlarmPickItem] { [] }
    func search(_ query: String) async -> [AlarmPickItem] { [] }
    func choice(for item: AlarmPickItem) async -> AlarmChoice? { nil }
    func previewURL(for choice: AlarmChoice) -> URL? { nil }
}
