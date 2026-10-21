import AVFoundation
import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import Observation

// The quick Alarm and Timer sheet and its "What to play" picker.
//
// The owner, after TestFlight 1.5.4: setting an alarm or timer has to be a quick operation, it
// has to be able to play anything (not only what is already playing), and when it rings the
// person has to land in the player. These are the rules of the sheet and the picker, kept here
// so both apps share them and they are tested without a screen. The scheduling, AlarmKit,
// notifications and storage underneath are TBX-11171's, unchanged.

/// What the quick sheet is doing: a timer or an alarm, and the item it plays.
@MainActor
@Observable
public final class AlarmQuickSetup {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case timer, alarm
        public var id: String { rawValue }
        public var title: String { self == .timer ? "Timer" : "Alarm" }
    }

    /// The timer's one-tap durations, in minutes.
    public static let presetMinutes = [5, 10, 15, 30, 60]
    /// Where the custom duration starts when nothing was used before.
    public static let defaultCustom: TimeInterval = 20 * 60

    public var mode: Mode

    // MARK: Timer

    /// The duration Start will use: a preset or the custom one. Nil until one is chosen.
    public private(set) var duration: TimeInterval?
    /// Whether the custom duration is the chosen one.
    public private(set) var isCustom = false
    /// The custom duration, kept while a preset is chosen so switching back finds it.
    public private(set) var customDuration: TimeInterval

    // MARK: Then play

    /// What plays when it goes off.
    public private(set) var thenPlay: AlarmChoice?
    /// An item chosen from a menu that is still being fetched (an album's or a playlist's songs).
    public private(set) var isResolvingThenPlay = false

    // MARK: Alarm

    public var hour: Int
    public var minute: Int
    /// `Calendar` weekdays, 1 is Sunday.
    public var repeatDays: Set<Int> = []
    public var label = ""
    public var snooze = true
    /// The alarm being edited, or nil for a new one.
    public private(set) var editingID: UUID?

    public init(mode: Mode, preselected: AlarmChoice? = nil, nowPlaying: AlarmChoice? = nil,
                lastPlayed: AlarmChoice? = nil, lastTimer: TimeInterval? = nil,
                now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        self.mode = mode
        thenPlay = Self.defaultThenPlay(preselected: preselected, nowPlaying: nowPlaying, lastPlayed: lastPlayed)
        let custom = lastTimer.flatMap { BatonTimer.durationRange.contains($0) ? $0 : nil } ?? Self.defaultCustom
        customDuration = custom
        // A new alarm starts at the next whole hour, a sensible place to turn the wheel from.
        let start = calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now
        let parts = calendar.dateComponents([.hour, .minute], from: start)
        hour = parts.hour ?? 7
        minute = parts.minute ?? 0
    }

    /// "Then play" starts as the item chosen from a menu, else what is playing, else what played
    /// last, so an alarm can be set with nothing playing.
    public static func defaultThenPlay(preselected: AlarmChoice?, nowPlaying: AlarmChoice?,
                                       lastPlayed: AlarmChoice?) -> AlarmChoice? {
        preselected ?? nowPlaying ?? lastPlayed
    }

    /// The item that played last, as an alarm would play it.
    public static func lastPlayed(_ history: MusicPlayHistory) -> AlarmChoice? {
        history.recentlyPlayed(limit: 1).first.map(AlarmChoice.song)
    }

    /// The picker chose something, or the sheet was opened for it.
    public func choose(_ choice: AlarmChoice?) {
        thenPlay = choice
        isResolvingThenPlay = false
    }

    /// An item from a menu whose songs are being fetched: "Then play" waits for it.
    public func resolving() { isResolvingThenPlay = true }

    // MARK: Timer

    public func selectPreset(minutes: Int) {
        duration = TimeInterval(minutes * 60)
        isCustom = false
    }

    public func selectCustom(_ seconds: TimeInterval) {
        let clamped = min(max(seconds, BatonTimer.durationRange.lowerBound), BatonTimer.durationRange.upperBound)
        customDuration = clamped
        duration = clamped
        isCustom = true
    }

    public func isSelected(minutes: Int) -> Bool { !isCustom && duration == TimeInterval(minutes * 60) }

    public var canStart: Bool { duration != nil && thenPlay != nil && !isResolvingThenPlay }

    /// Starts the timer. Nil when no duration or nothing to play is chosen.
    @discardableResult
    public func startTimer(in store: AlarmStore, now: Date = Date()) -> BatonTimer? {
        guard canStart, let duration, let thenPlay else { return nil }
        return store.startTimer(duration: duration, label: label, choice: thenPlay, now: now)
    }

    // MARK: Alarm

    /// A one-tap time for the alarm.
    public struct QuickPick: Identifiable, Equatable, Sendable {
        public var title: String
        public var hour: Int
        public var minute: Int
        public var id: String { title }
    }

    /// "7:00 tomorrow", "8:00 tomorrow", "In 1 hour", "In 8 hours" (or "today" for a time still
    /// to come today).
    public static func quickPicks(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> [QuickPick] {
        var picks: [QuickPick] = []
        for (h, m) in [(7, 0), (8, 0)] {
            guard let next = calendar.nextDate(after: now, matching: DateComponents(hour: h, minute: m, second: 0),
                                               matchingPolicy: .nextTime) else { continue }
            let day = calendar.isDate(next, inSameDayAs: now) ? "today" : "tomorrow"
            picks.append(QuickPick(title: "\(timeText(hour: h, minute: m, calendar: calendar)) \(day)", hour: h, minute: m))
        }
        for hours in [1, 8] {
            let date = now.addingTimeInterval(TimeInterval(hours * 3600))
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            picks.append(QuickPick(title: hours == 1 ? "In 1 hour" : "In \(hours) hours",
                                   hour: parts.hour ?? 0, minute: parts.minute ?? 0))
        }
        return picks
    }

    public func apply(_ pick: QuickPick) {
        hour = pick.hour
        minute = pick.minute
    }

    /// Loads an alarm into the form for editing.
    public func edit(_ alarm: BatonAlarm) {
        mode = .alarm
        editingID = alarm.id
        hour = alarm.hour
        minute = alarm.minute
        repeatDays = alarm.repeatDays
        label = alarm.label
        snooze = alarm.snoozeEnabled
        thenPlay = alarm.choice
        isResolvingThenPlay = false
    }

    /// Back to a new alarm, keeping "Then play".
    public func newAlarm() {
        editingID = nil
        repeatDays = []
        label = ""
        snooze = true
    }

    public func toggleDay(_ day: Int) {
        guard (1 ... 7).contains(day) else { return }
        if repeatDays.contains(day) { repeatDays.remove(day) } else { repeatDays.insert(day) }
    }

    public var canSave: Bool { thenPlay != nil && !isResolvingThenPlay }

    /// Saves the alarm (switched on) and returns it. Nil when nothing to play is chosen.
    @discardableResult
    public func saveAlarm(in store: AlarmStore, now: Date = Date()) -> BatonAlarm? {
        guard canSave, let thenPlay else { return nil }
        let alarm = BatonAlarm(id: editingID ?? UUID(), hour: hour, minute: minute, repeatDays: repeatDays,
                               label: label, snoozeEnabled: snooze, isEnabled: true, choice: thenPlay)
        store.save(alarm, now: now)
        editingID = alarm.id
        return alarm
    }

    /// The alarm's time as a date today, for a time wheel.
    public func timeDate(calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    public func setTime(_ date: Date, calendar: Calendar = .autoupdatingCurrent) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        hour = parts.hour ?? hour
        minute = parts.minute ?? minute
    }

    static func timeText(hour: Int, minute: Int, calendar: Calendar) -> String {
        let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .autoupdatingCurrent,
                                     calendar: calendar, timeZone: calendar.timeZone)
        return date.formatted(style)
    }

    /// "5 min", "1 hr", "1 hr 30 min", "45 sec".
    public static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        if h == 0, m == 0 { return "\(s) sec" }
        var parts: [String] = []
        if h > 0 { parts.append("\(h) hr") }
        if m > 0 { parts.append("\(m) min") }
        if h == 0, s > 0 { parts.append("\(s) sec") }
        return parts.joined(separator: " ")
    }
}

// MARK: - The pill above the mini player

/// The line above the mini player while a timer runs or an alarm is due within a day:
/// "Timer 12:34 · then Variatio 6" or "Alarm 7:00 · then Morning".
public struct AlarmPillState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case timer(paused: Bool), alarm }
    public var kind: Kind
    public var id: UUID
    /// "Timer 12:34" or "Alarm 7:00".
    public var lead: String
    public var thenPlay: String
    public var symbol: String { if case .timer = kind { "timer" } else { "alarm" } }

    public var text: String { "\(lead) · then \(thenPlay)" }

    /// How far ahead an alarm shows in the pill.
    public static let alarmHorizon: TimeInterval = 24 * 3600

    /// The first pill: the timer when one runs, else the soonest alarm within a day.
    @MainActor
    public static func current(_ store: AlarmStore, now: Date = Date(),
                               calendar: Calendar = .autoupdatingCurrent) -> AlarmPillState? {
        all(store, now: now, calendar: calendar).first
    }

    /// Every pill to show: the timer, then the soonest alarm due within a day. A timer and an
    /// alarm are independent, so with both set both show, one above the other, each with its own
    /// ✕ (owner, 2026-10-21, TBX-1000000410: "I should be able to setup timer and alarm at the
    /// same time"). Until then the timer's pill hid the alarm's.
    @MainActor
    public static func all(_ store: AlarmStore, now: Date = Date(),
                           calendar: Calendar = .autoupdatingCurrent) -> [AlarmPillState] {
        var pills: [AlarmPillState] = []
        if let timer = store.timer {
            let face = BatonTimer.clockFace(timer.remaining(at: now))
            pills.append(AlarmPillState(kind: .timer(paused: timer.isPaused), id: timer.id,
                                        lead: timer.isPaused ? "Timer paused \(face)" : "Timer \(face)",
                                        thenPlay: timer.choice.title))
        }
        let soonest = store.alarms
            .compactMap { alarm in alarm.nextFire(after: now, calendar: calendar).map { (alarm, $0) } }
            .filter { $0.1.timeIntervalSince(now) <= alarmHorizon }
            .min { $0.1 < $1.1 }
        if let (alarm, fire) = soonest {
            let style = Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone)
            pills.append(AlarmPillState(kind: .alarm, id: alarm.id, lead: "Alarm \(fire.formatted(style))",
                                        thenPlay: alarm.choice.title))
        }
        return pills
    }

    public var isTimer: Bool { if case .timer = kind { true } else { false } }

    /// The pill's ✕: cancels the timer, or switches the alarm off.
    @MainActor
    public func cancel(in store: AlarmStore) {
        switch kind {
        case .timer: store.cancelTimer()
        case .alarm: store.setEnabled(false, id: id)
        }
    }
}

// MARK: - What to play

/// One row of the "What to play" picker.
public struct AlarmPickItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case song, album, playlist, book, radio }

    /// How the row becomes something to play.
    public enum Ref: Equatable, Sendable {
        case song(NavidromeSong)
        case album(id: String)
        case playlist(id: String)
        case radio(AlarmChoice.Station)
        /// Already playable (a book's chapters from its place).
        case ready(AlarmChoice)
    }

    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var coverArtID: String?
    public var ref: Ref
    public var id: String

    public init(kind: Kind, id: String, title: String, subtitle: String? = nil, coverArtID: String? = nil, ref: Ref) {
        self.kind = kind
        self.id = "\(kind.rawValue):\(id)"
        self.title = title
        self.subtitle = subtitle
        self.coverArtID = coverArtID
        self.ref = ref
    }

    public var symbol: String {
        switch kind {
        case .song: "music.note"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        case .book: "book"
        case .radio: "dot.radiowaves.left.and.right"
        }
    }

    public static func song(_ song: NavidromeSong) -> AlarmPickItem {
        AlarmPickItem(kind: .song, id: song.id, title: song.title, subtitle: song.artist,
                      coverArtID: song.coverArtID, ref: .song(song))
    }

    public static func album(_ album: NavidromeAlbum) -> AlarmPickItem {
        AlarmPickItem(kind: .album, id: album.id, title: album.name, subtitle: album.artist,
                      coverArtID: album.coverArtID, ref: .album(id: album.id))
    }

    public static func playlist(_ playlist: NavidromePlaylist) -> AlarmPickItem {
        AlarmPickItem(kind: .playlist, id: playlist.id, title: playlist.name,
                      subtitle: playlist.songCount == 1 ? "1 song" : "\(playlist.songCount) songs",
                      coverArtID: playlist.coverArtID, ref: .playlist(id: playlist.id))
    }

    public static func station(_ station: NavidromeRadioStation) -> AlarmPickItem {
        let stored = AlarmChoice.Station(id: station.id, name: station.name, streamURL: station.streamUrl)
        return AlarmPickItem(kind: .radio, id: station.id, title: station.name, subtitle: station.streamURL?.host,
                             ref: .radio(stored))
    }

    public static func book(documentID: String, title: String, author: String?, choice: AlarmChoice) -> AlarmPickItem {
        AlarmPickItem(kind: .book, id: documentID, title: title, subtitle: author, ref: .ready(choice))
    }
}

/// Where the picker's rows come from. Each app has one over its own library, history, radio and
/// books; tests have a fake.
@MainActor
public protocol AlarmPickerSource: AnyObject {
    /// Recently played, newest first.
    func recent() -> [AlarmPickItem]
    func browse(_ section: AlarmPickerModel.Section) async -> [AlarmPickItem]
    func search(_ query: String) async -> [AlarmPickItem]
    /// What the row plays. Nil when it has nothing (an empty playlist, a failed fetch).
    func choice(for item: AlarmPickItem) async -> AlarmChoice?
    /// A URL to preview the choice from (its first song, or the station).
    func previewURL(for choice: AlarmChoice) -> URL?
}

/// Plays a preview. The picker decides when it stops.
@MainActor
public protocol AlarmPreviewing: AnyObject {
    func play(_ url: URL)
    func stop()
}

/// The "What to play" picker: search, Recently played, then Browse, with a short preview per row
/// that stops when the picker closes. Works with nothing playing.
@MainActor
@Observable
public final class AlarmPickerModel {
    public enum Section: String, CaseIterable, Identifiable, Sendable {
        case playlists = "Playlists", albums = "Albums", books = "Books", radio = "Radio"
        public var id: String { rawValue }
        public var symbol: String {
            switch self {
            case .playlists: "music.note.list"
            case .albums: "square.stack"
            case .books: "book"
            case .radio: "dot.radiowaves.left.and.right"
            }
        }
    }

    /// How long a preview plays.
    public static let previewLength: TimeInterval = 10
    /// How many tracks Recently played lists (owner, 2026-10-21: "the last 50 played").
    public static let recentLimit = 50

    public var query = ""
    public private(set) var results: [AlarmPickItem] = []
    public private(set) var isSearching = false
    public private(set) var recent: [AlarmPickItem] = []
    /// The row whose choice is being fetched after a tap.
    public private(set) var resolving: String?
    /// The row previewing now.
    public private(set) var previewing: String?
    /// Said when a row has nothing to play.
    public private(set) var failure: String?
    /// Said when a row has nothing to preview (kept apart, so "Then play" never shows it).
    public private(set) var previewFailure: String?

    @ObservationIgnored private let source: AlarmPickerSource
    @ObservationIgnored private let preview: AlarmPreviewing?
    @ObservationIgnored private let previewLength: TimeInterval
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var browsed: [Section: [AlarmPickItem]] = [:]
    /// Bumped by every select, preview and close, so a fetch that finishes after the person has
    /// moved on (left the picker, chose another row) does nothing (TBX-1000000112 review).
    @ObservationIgnored private var generation = 0

    public init(source: AlarmPickerSource, preview: AlarmPreviewing?, previewLength: TimeInterval = AlarmPickerModel.previewLength) {
        self.source = source
        self.preview = preview
        self.previewLength = previewLength
    }

    public func load() { recent = Array(source.recent().prefix(Self.recentLimit)) }

    /// Runs the search for `query` (the view debounces). An empty query clears it.
    public func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        let found = await source.search(text)
        guard query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
        results = found
        isSearching = false
    }

    public func items(in section: Section) async -> [AlarmPickItem] {
        if let cached = browsed[section], !cached.isEmpty { return cached }
        let items = await source.browse(section)
        browsed[section] = items
        return items
    }

    /// The person chose a row: its choice, for "Then play". Stops any preview.
    public func select(_ item: AlarmPickItem) async -> AlarmChoice? {
        stopPreview()
        generation += 1
        let mine = generation
        failure = nil
        resolving = item.id
        let choice = await source.choice(for: item)
        guard mine == generation else { return nil }
        resolving = nil
        guard let choice else {
            failure = "\(item.title) has nothing Baton can play."
            return nil
        }
        return choice
    }

    /// Plays ten seconds of the row, or stops it when it is the one previewing.
    public func togglePreview(_ item: AlarmPickItem) async {
        if previewing == item.id {
            stopPreview()
            return
        }
        stopPreview()
        generation += 1
        let mine = generation
        previewFailure = nil
        let choice = await source.choice(for: item)
        // The picker closed, or another row was tapped, while the songs were fetched.
        guard mine == generation else { return }
        guard let preview, let choice, let url = source.previewURL(for: choice) else {
            previewFailure = "No preview for \(item.title)."
            return
        }
        previewing = item.id
        preview.play(url)
        let length = previewLength
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(length))
            guard !Task.isCancelled, let self, self.previewing == item.id else { return }
            self.stopPreview()
        }
    }

    public func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        if previewing != nil { preview?.stop() }
        previewing = nil
    }

    /// The picker closed: nothing keeps playing, and nothing still being fetched starts.
    public func close() {
        generation += 1
        resolving = nil
        stopPreview()
    }
}

/// The picker over Baton's own library: the library store's search and browse, play history,
/// the radio stations, and the app's books. Both apps use it; only books differ.
@MainActor
public final class LibraryAlarmPickerSource: AlarmPickerSource {
    private let library: MusicLibraryStore
    private let history: MusicPlayHistory
    private let radio: InternetRadioStore
    private let books: @MainActor () -> [AlarmPickItem]

    public init(library: MusicLibraryStore, history: MusicPlayHistory, radio: InternetRadioStore,
                books: @escaping @MainActor () -> [AlarmPickItem]) {
        self.library = library
        self.history = history
        self.radio = radio
        self.books = books
    }

    /// The last 50 tracks played, newest first, each once. From the play
    /// history (`MusicPlayHistory`), the durable record of what was listened to; the in-memory
    /// `PlaybackEventLog` forgets everything at quit.
    public func recent() -> [AlarmPickItem] {
        history.recentlyPlayed(limit: AlarmPickerModel.recentLimit).map(AlarmPickItem.song)
    }

    public func browse(_ section: AlarmPickerModel.Section) async -> [AlarmPickItem] {
        switch section {
        case .playlists:
            if library.playlists.isEmpty, !library.isDemo { await library.loadPlaylists() }
            return library.playlists.map(AlarmPickItem.playlist)
        case .albums:
            if library.albums.isEmpty, !library.isDemo { await library.loadAlbums() }
            return library.albums.map(AlarmPickItem.album)
        case .books:
            return books()
        case .radio:
            if library.isDemo { return [] }
            await radio.loadIfNeeded()
            return radio.stations.map(AlarmPickItem.station)
        }
    }

    public func search(_ query: String) async -> [AlarmPickItem] {
        // Playlists and stations are matched by name from their lists, so load them first: a
        // search for a station on a fresh launch found nothing (TBX-1000000112 review).
        if !library.isDemo {
            if library.playlists.isEmpty { await library.loadPlaylists() }
            await radio.loadIfNeeded()
        }
        let found = await library.searchResults(for: query)
        let needle = NavidromeClient.foldedForSearch(query).lowercased()
        func matches(_ text: String?) -> Bool {
            guard let text else { return false }
            return NavidromeClient.foldedForSearch(text).lowercased().contains(needle)
        }
        let playlists = library.playlists.filter { matches($0.name) }.map(AlarmPickItem.playlist)
        let shelf = books().filter { matches($0.title) || matches($0.subtitle) }
        let stations = radio.stations.filter { matches($0.name) }.map(AlarmPickItem.station)
        return found.songs.map(AlarmPickItem.song) + found.albums.map(AlarmPickItem.album) + playlists + shelf + stations
    }

    public func choice(for item: AlarmPickItem) async -> AlarmChoice? {
        switch item.ref {
        case let .song(song):
            return .song(song)
        case let .album(id):
            let songs = await library.albumSongs(id: id)
            guard !songs.isEmpty else { return nil }
            return AlarmChoice(title: item.title, subtitle: item.subtitle, kind: .album, songs: songs,
                               source: .init(label: item.title, kind: .album, id: id))
        case let .playlist(id):
            let songs = await library.playlist(id: id)?.songs ?? []
            guard !songs.isEmpty else { return nil }
            return AlarmChoice(title: item.title, subtitle: item.subtitle, kind: .playlist, songs: songs,
                               source: .init(label: item.title, kind: .playlist, id: id))
        case let .radio(station):
            return .radio(station)
        case let .ready(choice):
            return choice
        }
    }

    public func previewURL(for choice: AlarmChoice) -> URL? {
        if let station = choice.station { return URL(string: station.streamURL.trimmingCharacters(in: .whitespaces)) }
        guard choice.songs.indices.contains(choice.startIndex) else { return nil }
        return try? StreamingPlaybackController.resolveStreamURL(songID: choice.songs[choice.startIndex].id)
    }
}

/// The picker's ten-second preview: its own AVPlayer, pausing the main player while it plays
/// and letting it carry on afterwards.
@MainActor
public final class AlarmPreviewPlayer: AlarmPreviewing {
    private let player: StreamingPlaybackController
    private let radio: InternetRadioStore?
    private var avPlayer: AVPlayer?
    private var pausedMain = false
    private var stoppedStation: NavidromeRadioStation?

    public init(player: StreamingPlaybackController, radio: InternetRadioStore? = nil) {
        self.player = player
        self.radio = radio
    }

    public func play(_ url: URL) {
        avPlayer?.pause()
        if player.isPlaying {
            player.pause()
            pausedMain = true
        }
        // A station on the air stops for the preview and is tuned in again after it.
        if let radio, let station = radio.onAirStation, radio.isPlaying(station) {
            radio.stop()
            stoppedStation = station
        }
        let preview = AVPlayer(url: url)
        preview.play()
        avPlayer = preview
    }

    public func stop() {
        avPlayer?.pause()
        avPlayer = nil
        if pausedMain {
            pausedMain = false
            player.resume()
        }
        if let station = stoppedStation {
            stoppedStation = nil
            radio?.play(station)
        }
    }
}
