import AVFoundation
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// The iPhone's Alarm and Timer: the shared store and
/// center, the system path for when Baton is not running (AlarmKit on iOS 26 and later, a
/// notification before that), the alarm sound (`AlarmClipStore`) and the chime.
@MainActor
@Observable
final class MobileAlarms {
    let store: AlarmStore
    let center: AlarmCenter
    /// The clip of each alarm's track, its sound on both system paths.
    @ObservationIgnored let sounds = AlarmClipStore()
    @ObservationIgnored private var chimePlayer: AVAudioPlayer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var nowPlayingChoice: () -> AlarmChoice? = { nil }
    @ObservationIgnored private weak var model: MobileModel?
    @ObservationIgnored private let ringWindow = AlarmRingWindowController()
    /// Which system path rings alarms on this phone.
    private(set) var systemPath: SystemPath = .none

    enum SystemPath: String { case alarmKit, notifications, none }

    /// Whether the system may ring Baton's alarms, for the Settings row that is all Settings
    /// keeps of Alarm and Timer now.
    enum Permission: Equatable { case allowed, notAsked, denied, unavailable }

    func permission() async -> Permission {
        if #available(iOS 26.0, *), let bridge = center.system as? AlarmKitBridge { return bridge.permission }
        guard center.system is AlarmNotificationBridge else { return .unavailable }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        case .notDetermined: return .notAsked
        @unknown default: return .unavailable
        }
    }

    /// `BATON_DEBUG_ALARM_SYSTEM=off` keeps the system path out of a UI test, so no AlarmKit or
    /// notification prompt covers the screen. Environment only, never launch arguments.
    static var systemSwitchedOff: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BATON_DEBUG_ALARM_SYSTEM"] == "off"
        #else
        false
        #endif
    }

    /// AlarmKit rings the chosen track's clip, else Baton's chime, else its own alarm sound
    /// `BATON_DEBUG_ALARM_SOUND=default` in a DEBUG build gives AlarmKit only its
    /// own sound: the iOS 26.5 simulator's SpringBoard aborts in ToneLibrary when it rings a named
    /// sound, believed to be a simulator fault (the phone check is an internal task), so a simulator
    /// walk that lets an alarm ring sets it.
    /// Environment only.
    static var systemAlarmKitSoundOnly: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BATON_DEBUG_ALARM_SOUND"] == "default"
        #else
        false
        #endif
    }

    init(player: StreamingPlaybackController) {
        store = AlarmStore()
        center = AlarmCenter(store: store, player: player)
    }

    func start(model: MobileModel) {
        guard !started else { return }
        started = true
        self.model = model
        nowPlayingChoice = { [weak model] in model.flatMap(Self.nowPlaying) }
        center.playChime = { [weak self] in self?.playChime() }
        // A radio station chosen to wake to plays through the radio engine.
        center.playRadio = { [weak model] station in
            model?.radio.play(NavidromeRadioStation(id: station.id, name: station.name, streamUrl: station.streamURL))
        }
        center.stopRadio = { [weak model] in model?.radio.stop() }
        center.rampRadio = { [weak model] in model?.radio.engine.startWakeRamp() }
        center.radioIsPlaying = { [weak model] in model?.radio.engine.isPlaying == true }
        // "Keep playing, open player": close whatever sheet is up, then the full player.
        center.showPlayer = { [weak model] in if let model { Self.showFullPlayer(model) } }
        ringWindow.watch(center)
        // A suspended Baton woken for a moment cannot start audio: then the system's alert
        // rings, and the item plays from its Play button or when Baton comes to the front.
        center.canPlayInApp = { [weak model] in
            UIApplication.shared.applicationState == .active || model?.music.isPlaying == true
        }
        // A book plays from wherever it was left by the time the alarm goes off, not where it
        // was when the alarm was set.
        center.resolve = { [weak model] choice in
            if choice.kind == .book, let documentID = choice.source?.id, let model,
               let book = model.shelfBooks.first(where: { $0.documentID == documentID }) {
                let queue = MobileBookShelf.queue(for: book)
                if !queue.songs.isEmpty { return queue }
            }
            return AlarmCenter.dropMissingFiles(choice)
        }
        center.stopChime = { [weak self] in self?.chimePlayer?.stop() }
        AlarmIntentHandler.play = { [weak self] id in self?.center.playFromSystem(id: id) }
        AlarmIntentHandler.stop = { [weak self] id in self?.center.stoppedAtSystem(id: id) }
        if !Self.systemSwitchedOff {
            if #available(iOS 26.0, *) {
                let bridge = AlarmKitBridge()
                if !Self.systemAlarmKitSoundOnly {
                    bridge.soundName = { [sounds] in sounds.soundName(for: $0, gentle: $1) }
                    bridge.prepare = { [sounds] in await sounds.prepare($0) }
                }
                bridge.storeIDs = { [store] in Set(store.alarms.map(\.id) + [store.timer?.id].compactMap { $0 }) }
                bridge.onAlerting = { [weak self] id in self?.center.systemIsAlerting(id: id) }
                // Permission given later, in Settings: schedule what is waiting without an edit.
                bridge.onAuthorizationChange = { [weak self] in self?.center.syncNow() }
                bridge.startWatching()
                center.system = bridge
                systemPath = .alarmKit
            } else {
                let bridge = AlarmNotificationBridge()
                bridge.soundName = { [sounds] in sounds.soundName(for: $0, gentle: $1) }
                bridge.prepare = { [sounds] in await sounds.prepare($0) }
                center.system = bridge
                systemPath = .notifications
                Task { await AlarmNotificationBridge.registerCategories() }
            }
        }
        center.start()
        if let pending = AlarmIntentHandler.pendingPlay {
            AlarmIntentHandler.pendingPlay = nil
            center.playFromSystem(id: pending)
        }
    }

    /// Baton came to the front: answer an alarm the system rang and has not finished (ringing,
    /// or counting down a snooze it took), then play anything else due within the grace, and
    /// bring the system's copies in step (permission may have been given in Settings meanwhile).
    func appBecameActive() {
        if #available(iOS 26.0, *), let bridge = center.system as? AlarmKitBridge {
            for id in bridge.rungStoreIDs(timerID: store.timer?.id) { center.systemIsAlerting(id: id) }
        }
        center.appBecameActive()
        center.syncNow()
    }

    /// One of Baton's notifications was answered (iOS 18 to 25).
    func handle(_ response: AlarmNotificationBridge.Response) {
        AlarmNotificationBridge.handle(response, center: center)
    }

    func choiceForNowPlaying() -> AlarmChoice? { nowPlayingChoice() }

    /// What the quick sheet needs: the defaults for "Then play" and the picker's library.
    var sheetContext: AlarmSheetContext {
        let model = model
        return AlarmSheetContext(
            center: center,
            nowPlaying: { [nowPlayingChoice] in nowPlayingChoice() },
            lastPlayed: { model.flatMap { AlarmQuickSetup.lastPlayed($0.history) } },
            makeSource: {
                guard let model else { return EmptyAlarmPickerSource() }
                return LibraryAlarmPickerSource(library: model.musicLibrary, history: model.history, radio: model.radio) {
                    [weak model] in
                    guard let model, model.documentsSwitch.isOn else { return [] }
                    return model.shelfBooks.compactMap { book in
                        Self.bookChoice(book).map {
                            AlarmPickItem.book(documentID: book.documentID, title: book.title, author: book.author, choice: $0)
                        }
                    }
                }
            },
            makePreview: { model.map { AlarmPreviewPlayer(player: $0.music, radio: $0.radio) } }
        )
    }

    /// A book as an alarm plays it: its chapters from the synced place. At the time the alarm
    /// re-reads the place, so it resumes where the book was left by then.
    static func bookChoice(_ book: MobileBookShelf.Book) -> AlarmChoice? {
        let (songs, start) = MobileBookShelf.queue(for: book)
        guard !songs.isEmpty else { return nil }
        return AlarmChoice(title: book.title, subtitle: book.author, kind: .book, songs: songs, startIndex: start,
                           source: BookTransport.source(documentID: book.documentID, title: book.title))
    }

    /// Closes whatever is presented over the app (Settings, a menu's sheet, the alarm sheet) and
    /// shows the full player, so the person lands where the music is. With the
    /// full player already up, only what is over it closes.
    static func showFullPlayer(_ model: MobileModel) {
        guard let root = appRootController() else {
            model.requestFullPlayer()
            return
        }
        if model.fullPlayerIsUp, let player = root.presentedViewController {
            if player.presentedViewController != nil { player.dismiss(animated: true) }
            return
        }
        if let presented = root.presentedViewController, !presented.isBeingDismissed {
            root.dismiss(animated: true) { Task { @MainActor in model.requestFullPlayer() } }
        } else {
            model.requestFullPlayer()
        }
    }

    /// The app window's root, which every sheet is presented over. Not the ringing window.
    static func appRootController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
            .flatMap(\.windows)
            .filter { !($0 is AlarmRingWindow) }
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
    }

    /// What the player holds now, as an alarm would play it: the current track with the rest of
    /// its queue, or a book from its current chapter.
    static func nowPlaying(_ model: MobileModel) -> AlarmChoice? {
        AlarmChoice.queue(model.music.queue, at: model.music.currentIndex, source: model.music.queueSource,
                          isBook: model.isPlayingBookChapter)
    }

    private func playChime() {
        guard let url = Bundle.main.url(forResource: "BatonAlarmChime", withExtension: "caf") else { return }
        chimePlayer = try? AVAudioPlayer(contentsOf: url)
        chimePlayer?.numberOfLoops = 4
        chimePlayer?.play()
    }
}

/// The ringing screen in a window of its own above every other, so it covers whatever is up
/// when it goes off: Settings, a menu's sheet, the full player. In 1.5.4 the
/// card was an overlay on the root, under any sheet, and the owner was left on Settings with
/// the music playing and no way to it.
final class AlarmRingWindow: UIWindow {}

@MainActor
final class AlarmRingWindowController {
    private var window: AlarmRingWindow?
    private weak var center: AlarmCenter?
    private var sceneObserver: NSObjectProtocol?

    func watch(_ center: AlarmCenter) {
        self.center = center
        // An alarm that rings during a cold launch, before the scene is attached, finds no scene
        // to put its window in: try again when one becomes active.
        sceneObserver = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        observe()
    }

    private func observe() {
        guard let center else { return }
        withObservationTracking {
            _ = center.ringing
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.observe()
            }
        }
        sync()
    }

    private func sync() {
        guard let center else { return }
        if center.ringing == nil {
            guard let window else { return }
            window.isHidden = true
            self.window = nil
            MobileAlarms.appRootController()?.view.window?.makeKey()
            return
        }
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.session.role == .windowApplication && $0.activationState != .unattached }) else { return }
        let window = AlarmRingWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: AlarmRingingCard(center: center, fullScreen: true).tint(.batonOrange))
        host.view.backgroundColor = .clear
        // VoiceOver reads the ringing screen, not the app under it.
        host.view.accessibilityViewIsModal = true
        window.rootViewController = host
        let appearance = AppearanceSetting.current
        window.overrideUserInterfaceStyle = switch appearance {
        case .light: .light
        case .dark: .dark
        case .system: .unspecified
        }
        window.makeKeyAndVisible()
        self.window = window
        UIAccessibility.post(notification: .screenChanged, argument: host.view)
    }
}

/// A notice over a screen (an alarm missed, or nothing left to play). Both the root and the
/// full player carry it, since the full player is a sheet over the root and would hide the
/// root's. The ringing itself is `AlarmRingWindowController`'s.
private struct AlarmNoticeOverlay: ViewModifier {
    let center: AlarmCenter

    func body(content: Content) -> some View {
        content.overlay {
            if center.ringing == nil, let notice = center.notice {
                VStack {
                    HStack(alignment: .top) {
                        Image(systemName: "alarm")
                        Text(notice).font(.subheadline)
                        Spacer(minLength: 8)
                        Button { center.dismissNotice() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Dismiss")
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)
                    Spacer()
                }
                .accessibilityIdentifier("alarm-notice")
            }
        }
    }
}

/// Presents the quick sheet from anywhere: a menu, the player's clock, the pill. One presenter
/// per sheet level, as with sharing (`songSharePresenter`).
private struct AlarmSheetPresenter: ViewModifier {
    let alarms: MobileAlarms
    @State private var request: AlarmRequest?

    func body(content: Content) -> some View {
        content
            .environment(\.presentAlarmSheet, { request = $0 })
            .sheet(item: $request) { request in
                AlarmQuickSheet(request: request, context: alarms.sheetContext) { self.request = nil }
                    .presentationDetents([.fraction(0.62), .large])
                    .presentationDragIndicator(.visible)
                    .tint(.batonOrange)
            }
    }
}

private struct AlarmSheetPresentationKey: EnvironmentKey {
    static var defaultValue: (@MainActor (AlarmRequest) -> Void)? { nil }
}

extension EnvironmentValues {
    var presentAlarmSheet: (@MainActor (AlarmRequest) -> Void)? {
        get { self[AlarmSheetPresentationKey.self] }
        set { self[AlarmSheetPresentationKey.self] = newValue }
    }
}

extension View {
    func alarmRingingOverlay(_ alarms: MobileAlarms) -> some View {
        modifier(AlarmNoticeOverlay(center: alarms.center))
    }

    func alarmSheetPresenter(_ alarms: MobileAlarms) -> some View {
        modifier(AlarmSheetPresenter(alarms: alarms))
    }
}

/// "Set Alarm…" and "Start Timer…" for a menu: the quick sheet with `choice` (or, for an album
/// or a playlist, `item`, fetched once the sheet is up) as "Then play".
struct AlarmMenuItems: View {
    var choice: AlarmChoice?
    var item: AlarmPickItem?
    @Environment(\.presentAlarmSheet) private var present

    var body: some View {
        if let present {
            Button {
                present(item.map { .pick(.alarm, $0) } ?? .newAlarm(choice))
            } label: { Label("Set Alarm…", systemImage: "alarm") }
            Button {
                present(item.map { .pick(.timer, $0) } ?? .timer(choice))
            } label: { Label("Start Timer…", systemImage: "timer") }
        }
    }
}

/// The player's clock button, beside the sleep moon: the quick sheet on Timer (the running one,
/// when there is one); the pill opens it on whatever it shows.
struct AlarmClockButton<Label: View>: View {
    @Environment(\.presentAlarmSheet) private var present
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button { present?(.timer(nil)) } label: { label() }
            .accessibilityLabel("Alarm and Timer")
            .accessibilityIdentifier("player-alarm-clock")
    }
}

/// The pill above the mini player, presenting the sheet from where it sits. With a timer and an
/// alarm both set, two pills, one above the other.
///
/// Each as wide as the mini player under it, and capped at 620pt on the iPad as
/// its bar is.
struct MobileAlarmPill: View {
    let alarms: MobileAlarms
    @Environment(\.presentAlarmSheet) private var present

    var body: some View {
        AlarmPill(center: alarms.center, open: { present?($0.request) }, fillsWidth: true)
            .padding(.horizontal, BottomChrome.floatingInset)
            .readableWidth(620)
            .padding(.bottom, 6)
    }
}

/// A picker with nothing behind it, before the app has started.
@MainActor
private final class EmptyAlarmPickerSource: AlarmPickerSource {
    func recent() -> [AlarmPickItem] { [] }
    func browse(_ section: AlarmPickerModel.Section) async -> [AlarmPickItem] { [] }
    func search(_ query: String) async -> [AlarmPickItem] { [] }
    func choice(for item: AlarmPickItem) async -> AlarmChoice? { nil }
    func previewURL(for choice: AlarmChoice) -> URL? { nil }
}
