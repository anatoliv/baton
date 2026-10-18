import AVFoundation
import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// The quick Alarm and Timer sheet and its "What to play" picker: the timer's
/// presets, what "Then play" starts as, the alarm form, the pill above the mini player, the
/// picker's selection and preview, and the ringing card's new actions.
@MainActor
final class AlarmQuickSetupTests: XCTestCase {
    private let song = NavidromeSong(id: "s1", title: "Variatio 6", artist: "Bach")
    private let other = NavidromeSong(id: "s2", title: "Aria", artist: "Bach")

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // MARK: Timer presets

    func testPresetsAreFiveTenFifteenThirtyAndAnHour() {
        XCTAssertEqual(AlarmQuickSetup.presetMinutes, [5, 10, 15, 30, 60])
    }

    func testAPresetSelectsAndStartStartsIt() {
        let store = AlarmStore(defaults: ThrowawayDefaults.make("quick.preset"))
        let setup = AlarmQuickSetup(mode: .timer, nowPlaying: .song(song))
        XCTAssertNil(setup.duration, "nothing is selected until a preset is tapped")
        XCTAssertFalse(setup.canStart)

        setup.selectPreset(minutes: 5)
        XCTAssertEqual(setup.duration, 300)
        XCTAssertTrue(setup.isSelected(minutes: 5))
        XCTAssertFalse(setup.isSelected(minutes: 10))
        XCTAssertNil(store.timer, "selecting a preset does not start it")

        let now = date("2026-10-17T10:00:00Z")
        let timer = setup.startTimer(in: store, now: now)
        XCTAssertEqual(timer?.duration, 300)
        XCTAssertEqual(store.timer?.endsAt, now.addingTimeInterval(300))
        XCTAssertEqual(store.timer?.choice, .song(song))
    }

    func testCustomReplacesThePresetAndIsClamped() {
        let setup = AlarmQuickSetup(mode: .timer, nowPlaying: .song(song), lastTimer: 90)
        XCTAssertEqual(setup.customDuration, 90, "the custom picker starts from the last custom timer")
        setup.selectPreset(minutes: 30)
        setup.selectCustom(45)
        XCTAssertTrue(setup.isCustom)
        XCTAssertEqual(setup.duration, 45)
        XCTAssertFalse(setup.isSelected(minutes: 30))
        setup.selectCustom(48 * 3600)
        XCTAssertEqual(setup.duration, BatonTimer.durationRange.upperBound)
        setup.selectPreset(minutes: 60)
        XCTAssertFalse(setup.isCustom)
        XCTAssertEqual(setup.customDuration, BatonTimer.durationRange.upperBound, "kept for switching back")
    }

    func testNothingToPlayMeansNoStart() {
        let store = AlarmStore(defaults: ThrowawayDefaults.make("quick.nothing"))
        let setup = AlarmQuickSetup(mode: .timer)
        setup.selectPreset(minutes: 5)
        XCTAssertNil(setup.thenPlay)
        XCTAssertFalse(setup.canStart)
        XCTAssertNil(setup.startTimer(in: store))
        XCTAssertNil(store.timer)
    }

    func testAnItemStillBeingFetchedHoldsStart() {
        let setup = AlarmQuickSetup(mode: .timer, nowPlaying: .song(song))
        setup.selectPreset(minutes: 10)
        setup.resolving()
        XCTAssertFalse(setup.canStart)
        setup.choose(.song(other))
        XCTAssertTrue(setup.canStart)
        XCTAssertEqual(setup.thenPlay, .song(other))
    }

    // MARK: Then play

    func testThenPlayDefaultsToTheMenuItemThenNowPlayingThenLastPlayed() {
        let menu = AlarmChoice.song(other)
        let playing = AlarmChoice.song(song)
        let last = AlarmChoice(title: "Last", kind: .song, songs: [NavidromeSong(id: "s3", title: "Last")])
        XCTAssertEqual(AlarmQuickSetup.defaultThenPlay(preselected: menu, nowPlaying: playing, lastPlayed: last), menu)
        XCTAssertEqual(AlarmQuickSetup.defaultThenPlay(preselected: nil, nowPlaying: playing, lastPlayed: last), playing)
        XCTAssertEqual(AlarmQuickSetup.defaultThenPlay(preselected: nil, nowPlaying: nil, lastPlayed: last), last,
                       "with nothing playing, the last played item")
        XCTAssertNil(AlarmQuickSetup.defaultThenPlay(preselected: nil, nowPlaying: nil, lastPlayed: nil))
        XCTAssertEqual(AlarmQuickSetup(mode: .alarm, nowPlaying: nil, lastPlayed: last).thenPlay, last)
    }

    func testLastPlayedIsTheNewestListen() {
        let history = MusicPlayHistory(defaults: ThrowawayDefaults.make("quick.history"),
                                       directory: FileManager.default.temporaryDirectory
                                           .appendingPathComponent("quick-history-\(UUID().uuidString)"))
        XCTAssertNil(AlarmQuickSetup.lastPlayed(history))
        history.record(other, playedAt: date("2026-10-16T08:00:00Z"))
        history.record(song, playedAt: date("2026-10-17T08:00:00Z"))
        XCTAssertEqual(AlarmQuickSetup.lastPlayed(history), .song(song))
    }

    // MARK: Alarm

    func testQuickPicksSayTodayOrTomorrowAndCountHours() {
        let evening = date("2026-10-17T21:30:00Z")
        let picks = AlarmQuickSetup.quickPicks(now: evening, calendar: utc)
        // The formatter puts a narrow no-break space before AM; compare words.
        func plain(_ text: String?) -> String? { text?.replacingOccurrences(of: "\u{202F}", with: " ") }
        XCTAssertEqual(picks.map { plain($0.title)! }, ["7:00 AM tomorrow", "8:00 AM tomorrow", "In 1 hour", "In 8 hours"])
        XCTAssertEqual(picks[2].hour, 22)
        XCTAssertEqual(picks[3].hour, 5)
        XCTAssertEqual(picks[3].minute, 30)
        let dawn = date("2026-10-17T06:10:00Z")
        XCTAssertEqual(plain(AlarmQuickSetup.quickPicks(now: dawn, calendar: utc).first?.title), "7:00 AM today")
    }

    func testSaveMakesAnAlarmAndEditKeepsItsIdentity() {
        let store = AlarmStore(defaults: ThrowawayDefaults.make("quick.alarm"), calendar: { [utc] in utc })
        let now = date("2026-10-17T21:30:00Z")
        let setup = AlarmQuickSetup(mode: .alarm, nowPlaying: .song(song), now: now, calendar: utc)
        XCTAssertEqual(setup.hour, 22, "a new alarm starts at the next whole hour")
        setup.apply(AlarmQuickSetup.quickPicks(now: now, calendar: utc)[0])
        setup.toggleDay(2)
        setup.toggleDay(4)
        setup.toggleDay(4)
        setup.label = "Wake"
        setup.snooze = false
        let saved = try! XCTUnwrap(setup.saveAlarm(in: store, now: now))
        XCTAssertEqual(store.alarms.count, 1)
        XCTAssertEqual(saved.hour, 7)
        XCTAssertEqual(saved.minute, 0)
        XCTAssertEqual(saved.repeatDays, [2])
        XCTAssertEqual(saved.label, "Wake")
        XCTAssertFalse(saved.snoozeEnabled)
        XCTAssertEqual(saved.choice, .song(song))

        let editor = AlarmQuickSetup(mode: .timer, nowPlaying: nil, now: now, calendar: utc)
        editor.edit(saved)
        XCTAssertEqual(editor.mode, .alarm)
        XCTAssertEqual(editor.thenPlay, .song(song))
        editor.hour = 6
        editor.saveAlarm(in: store, now: now)
        XCTAssertEqual(store.alarms.count, 1, "editing replaces, not adds")
        XCTAssertEqual(store.alarms.first?.hour, 6)
        XCTAssertEqual(store.alarms.first?.id, saved.id)

        editor.newAlarm()
        XCTAssertNil(editor.editingID)
        XCTAssertEqual(editor.thenPlay, .song(song), "a new alarm keeps Then play")
        editor.saveAlarm(in: store, now: now)
        XCTAssertEqual(store.alarms.count, 2)
    }

    // MARK: The pill

    func testThePillShowsARunningTimerAndAnAlarmWithinADay() {
        let store = AlarmStore(defaults: ThrowawayDefaults.make("quick.pill"), calendar: { [utc] in utc })
        let now = date("2026-10-17T21:30:00Z")
        XCTAssertNil(AlarmPillState.current(store, now: now, calendar: utc))

        // An alarm more than a day away (next Tuesday): no pill.
        store.save(BatonAlarm(hour: 7, minute: 0, repeatDays: [3], choice: .song(song)), now: now)
        XCTAssertNil(AlarmPillState.current(store, now: now, calendar: utc))

        // One tomorrow at 7:00: the pill.
        store.save(BatonAlarm(hour: 7, minute: 0, choice: .song(other)), now: now)
        let alarmPill = try! XCTUnwrap(AlarmPillState.current(store, now: now, calendar: utc))
        XCTAssertEqual(alarmPill.kind, .alarm)
        XCTAssertTrue(alarmPill.text.hasPrefix("Alarm 7:00"), alarmPill.text)
        XCTAssertTrue(alarmPill.text.hasSuffix(" · then Aria"), alarmPill.text)

        // A timer takes the pill, with its countdown.
        store.startTimer(duration: 12 * 60 + 34, choice: .song(song), now: now)
        let timerPill = try! XCTUnwrap(AlarmPillState.current(store, now: now, calendar: utc))
        XCTAssertEqual(timerPill.text, "Timer 12:34 · then Variatio 6")
        XCTAssertEqual(AlarmPillState.current(store, now: now.addingTimeInterval(34), calendar: utc)?.lead, "Timer 12:00")

        // Its ✕ cancels the timer; the alarm's switches the alarm off.
        timerPill.cancel(in: store)
        XCTAssertNil(store.timer)
        AlarmPillState.current(store, now: now, calendar: utc)?.cancel(in: store)
        XCTAssertEqual(store.alarms.filter(\.isEnabled).count, 1)
        XCTAssertNil(AlarmPillState.current(store, now: now, calendar: utc))
    }

    // MARK: The picker

    func testPickingARowResolvesItForThenPlay() async {
        let source = FakeSource()
        let picker = AlarmPickerModel(source: source, preview: nil)
        picker.load()
        XCTAssertEqual(picker.recent.map(\.title), ["Aria"])

        let album = AlarmPickItem(kind: .album, id: "al1", title: "Goldberg", subtitle: "Bach", ref: .album(id: "al1"))
        let choice = await picker.select(album)
        XCTAssertEqual(choice?.kind, .album)
        XCTAssertEqual(choice?.songs.map(\.id), ["s1", "s2"])
        XCTAssertEqual(choice?.source?.id, "al1")
        XCTAssertNil(picker.resolving)

        let setup = AlarmQuickSetup(mode: .timer)
        setup.choose(choice)
        XCTAssertEqual(setup.thenPlay?.title, "Goldberg")

        let empty = AlarmPickItem(kind: .playlist, id: "p0", title: "Empty", ref: .playlist(id: "p0"))
        let none = await picker.select(empty)
        XCTAssertNil(none)
        XCTAssertEqual(picker.failure, "Empty has nothing Baton can play.")
    }

    func testSearchFillsResultsAndAnEmptyQueryClearsThem() async {
        let picker = AlarmPickerModel(source: FakeSource(), preview: nil)
        picker.query = "variatio"
        await picker.search()
        XCTAssertEqual(picker.results.map(\.title), ["Variatio 6"])
        picker.query = "  "
        await picker.search()
        XCTAssertTrue(picker.results.isEmpty)
    }

    func testAPreviewStopsAfterItsLengthOnCloseAndOnSelect() async throws {
        let preview = FakePreview()
        let picker = AlarmPickerModel(source: FakeSource(), preview: preview, previewLength: 0.2)
        let row = AlarmPickItem.song(song)

        await picker.togglePreview(row)
        XCTAssertEqual(picker.previewing, row.id)
        XCTAssertEqual(preview.played, [URL(string: "file:///s1")!])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(picker.previewing, "a preview stops by itself")
        XCTAssertEqual(preview.stops, 1)

        await picker.togglePreview(row)
        picker.close()
        XCTAssertNil(picker.previewing, "closing the picker stops the preview")
        XCTAssertEqual(preview.stops, 2)

        await picker.togglePreview(row)
        _ = await picker.select(AlarmPickItem.song(other))
        XCTAssertNil(picker.previewing, "choosing a row stops the preview")
        XCTAssertEqual(preview.stops, 3)

        await picker.togglePreview(row)
        await picker.togglePreview(row)
        XCTAssertNil(picker.previewing, "tapping the previewing row again stops it")
        XCTAssertEqual(preview.stops, 4)
    }

    func testClosingThePickerDuringAFetchStartsNothing() async throws {
        let source = FakeSource()
        source.delay = .milliseconds(300)
        let preview = FakePreview()
        let picker = AlarmPickerModel(source: source, preview: preview)
        let album = AlarmPickItem(kind: .album, id: "al1", title: "Goldberg", ref: .album(id: "al1"))

        let previewing = Task { await picker.togglePreview(album) }
        try await Task.sleep(for: .milliseconds(50))
        picker.close()
        await previewing.value
        XCTAssertTrue(preview.played.isEmpty, "a preview whose fetch outlived the picker never plays")
        XCTAssertNil(picker.previewing)

        let selecting = Task { await picker.select(album) }
        try await Task.sleep(for: .milliseconds(50))
        picker.close()
        let chosen = await selecting.value
        XCTAssertNil(chosen, "a choice whose fetch outlived the picker is dropped")
        XCTAssertNil(picker.resolving)
        XCTAssertNil(picker.failure, "an overtaken fetch is not a failure")
    }

    // MARK: The ringing card's actions

    func testTimerSnoozeStartsNineMinutesAndOpenPlayerKeepsPlaying() {
        let player = StreamingPlaybackController(streamURLProvider: { URL(string: $0)! }, coverArtURLProvider: { _ in nil },
                                                 defaults: UserDefaults(suiteName: ThrowawayDefaults.name("quick.center"))!,
                                                 systemNowPlaying: false)
        defer { player.stop() }
        let store = AlarmStore(defaults: ThrowawayDefaults.make("quick.center.store"))
        let center = AlarmCenter(store: store, player: player)
        var shown = 0
        center.showPlayer = { shown += 1 }
        let now = date("2026-10-17T10:00:00Z")
        center.now = { now }
        let fire = AlarmFire(kind: .timer, alarmID: UUID(), occurrence: now, label: "Tea",
                             choice: .song(song), snoozeEnabled: false, isLate: false)
        XCTAssertTrue(AlarmCenter.offersSnooze(fire), "a timer's ringing card offers Snooze too")

        center.handle([fire], fromSystem: false)
        center.snoozeRinging()
        XCTAssertNil(center.ringing)
        XCTAssertEqual(store.timer?.endsAt, now.addingTimeInterval(9 * 60))
        XCTAssertEqual(store.timer?.label, "Tea")

        center.handle([fire], fromSystem: false)
        center.keepPlayingAndShowPlayer()
        XCTAssertNil(center.ringing)
        XCTAssertEqual(shown, 1, "Keep playing, open player brings the player forward")
    }

    func testARadioChoiceTunesInAndStopTakesItOff() {
        let player = StreamingPlaybackController(streamURLProvider: { URL(string: $0)! }, coverArtURLProvider: { _ in nil },
                                                 defaults: UserDefaults(suiteName: ThrowawayDefaults.name("quick.radio"))!,
                                                 systemNowPlaying: false)
        let store = AlarmStore(defaults: ThrowawayDefaults.make("quick.radio.store"))
        let center = AlarmCenter(store: store, player: player)
        var tuned: [String] = []
        var stopped = 0
        center.playRadio = { tuned.append($0.name) }
        center.stopRadio = { stopped += 1 }
        let station = AlarmChoice.Station(id: "r1", name: "Morning FM", streamURL: "https://radio.example/stream")
        let choice = AlarmChoice.radio(station)
        XCTAssertEqual(choice.symbol, "dot.radiowaves.left.and.right")
        let fire = AlarmFire(kind: .alarm, alarmID: UUID(), occurrence: Date(), label: "Alarm",
                             choice: choice, snoozeEnabled: true, isLate: false)
        center.handle([fire], fromSystem: false)
        XCTAssertEqual(tuned, ["Morning FM"])
        XCTAssertNotNil(center.ringing)
        center.stopRinging()
        XCTAssertEqual(stopped, 1)

        // Stored and read back, a radio alarm keeps its station.
        let data = try! JSONEncoder().encode(choice)
        XCTAssertEqual(try! JSONDecoder().decode(AlarmChoice.self, from: data), choice)
    }
}

@MainActor
private final class FakeSource: AlarmPickerSource {
    var delay: Duration = .zero
    let songs = [NavidromeSong(id: "s1", title: "Variatio 6"), NavidromeSong(id: "s2", title: "Aria")]

    func recent() -> [AlarmPickItem] { [.song(songs[1])] }

    func browse(_ section: AlarmPickerModel.Section) async -> [AlarmPickItem] { [] }

    func search(_ query: String) async -> [AlarmPickItem] {
        songs.filter { $0.title.lowercased().contains(query.lowercased()) }.map(AlarmPickItem.song)
    }

    func choice(for item: AlarmPickItem) async -> AlarmChoice? {
        if delay != .zero { try? await Task.sleep(for: delay) }
        switch item.ref {
        case let .song(song): return .song(song)
        case let .album(id) where id == "al1":
            return AlarmChoice(title: item.title, kind: .album, songs: songs, source: .init(label: item.title, kind: .album, id: id))
        default: return nil
        }
    }

    func previewURL(for choice: AlarmChoice) -> URL? { choice.songs.first.map { URL(string: "file:///\($0.id)")! } }
}

@MainActor
private final class FakePreview: AlarmPreviewing {
    var played: [URL] = []
    var stops = 0
    func play(_ url: URL) { played.append(url) }
    func stop() { stops += 1 }
}
