import AVFoundation
import BatonPlaybackKit
import Foundation
import SwiftUI
import UIKit

/// The iPhone's Alarm and Timer (TBX-11171, specs/alarm-and-timer.md): the shared store and
/// center, the system path for when Baton is not running (AlarmKit on iOS 26 and later, a
/// notification before that), the alarm sound and the chime.
@MainActor
@Observable
final class MobileAlarms {
    let store: AlarmStore
    let center: AlarmCenter
    @ObservationIgnored private let sounds = AlarmSounds()
    @ObservationIgnored private var chimePlayer: AVAudioPlayer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var nowPlayingChoice: () -> AlarmChoice? = { nil }
    /// Which system path rings alarms on this phone.
    private(set) var systemPath: SystemPath = .none

    enum SystemPath: String { case alarmKit, notifications, none }

    /// `BATON_DEBUG_ALARM_SYSTEM=off` keeps the system path out of a UI test, so no AlarmKit or
    /// notification prompt covers the screen. Environment only, never launch arguments.
    static var systemSwitchedOff: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BATON_DEBUG_ALARM_SYSTEM"] == "off"
        #else
        false
        #endif
    }

    /// AlarmKit rings its own alarm sound. Baton's clip of the track, or its chime, is used only
    /// with `BATON_DEBUG_ALARM_SOUND=clip` in a DEBUG build, until a physical iPhone has rung both
    /// (the iOS 26.5 simulator's SpringBoard aborted in ToneLibrary on the clip; TBX-11171 review).
    /// The notification path (iOS 18 to 25) keeps Baton's sounds. Environment only.
    static var customAlarmKitSound: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BATON_DEBUG_ALARM_SOUND"] == "clip"
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
        nowPlayingChoice = { [weak model] in model.flatMap(Self.nowPlaying) }
        center.playChime = { [weak self] in self?.playChime() }
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
                if Self.customAlarmKitSound {
                    bridge.soundName = { [sounds] in sounds.soundName(for: $0) }
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
                bridge.soundName = { [sounds] in sounds.soundName(for: $0) }
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

/// The ringing card and any notice over a screen. Both the root and the full player carry it,
/// since the full player is a sheet over the root and would hide the root's.
private struct AlarmRingingOverlay: ViewModifier {
    let center: AlarmCenter

    func body(content: Content) -> some View {
        content.overlay {
            if center.ringing != nil {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    AlarmRingingCard(center: center).padding(24)
                }
                .transition(.opacity)
            } else if let notice = center.notice {
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
        .animation(.default, value: center.ringing?.id)
    }
}

/// Presents the alarm editor and the timer from anywhere: a song's menu, the player's moon
/// menu, Settings. One presenter per sheet level, as with sharing (`songSharePresenter`).
private struct AlarmSheetPresenter: ViewModifier {
    let alarms: MobileAlarms
    @State private var request: AlarmRequest?

    func body(content: Content) -> some View {
        content
            .environment(\.presentAlarmSheet, { request = $0 })
            .sheet(item: $request) { request in
                AlarmSheet(request: request, center: alarms.center, nowPlaying: { alarms.choiceForNowPlaying() })
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
        modifier(AlarmRingingOverlay(center: alarms.center))
    }

    func alarmSheetPresenter(_ alarms: MobileAlarms) -> some View {
        modifier(AlarmSheetPresenter(alarms: alarms))
    }
}

/// "Set Alarm…" and "Start Timer…" for a menu, for `choice` or what is playing.
struct AlarmMenuItems: View {
    let choice: AlarmChoice?
    @Environment(\.presentAlarmSheet) private var present

    var body: some View {
        if let present {
            Button { present(.newAlarm(choice)) } label: { Label("Set Alarm…", systemImage: "alarm") }
            Button { present(.timer(choice)) } label: { Label("Start Timer…", systemImage: "timer") }
        }
    }
}
