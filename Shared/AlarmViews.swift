import BatonPlaybackKit
import BatonSubsonicKit
import BatonSubsonicModels
import SwiftUI

// Alarm and Timer screens, one set for both apps (TBX-11171, rebuilt for TBX-1000000112).
//
// The owner, after TestFlight 1.5.4: Settings was the wrong place, setting one has to be quick,
// it has to be able to play anything, and when it rings the person has to land in the player.
// So there is one quick sheet (a popover on the Mac) with a Timer / Alarm switch, opened from
// the player's clock button, from any song, album, playlist or book menu, and from the pill
// above the mini player. Its "Then play" row opens a "What to play" picker that needs nothing
// playing. The rules behind these screens are `AlarmQuickSetup` and `AlarmPickerModel`
// (BatonPlaybackKit), tested there.

/// What the alarm sheet was opened for.
public enum AlarmRequest: Identifiable, Equatable {
    /// The Alarm tab, with this item (or the default) as "Then play".
    case newAlarm(AlarmChoice?)
    case editAlarm(UUID)
    /// The Timer tab, with this item (or the default) as "Then play".
    case timer(AlarmChoice?)
    /// A menu item whose songs are fetched once the sheet is up (an album, a playlist).
    case pick(AlarmQuickSetup.Mode, AlarmPickItem)
    /// Whatever is most useful now: the running timer, else the alarms if any (the pill).
    case list

    public var id: String {
        switch self {
        case .newAlarm: "new-alarm"
        case let .editAlarm(id): "edit-\(id.uuidString)"
        case .timer: "timer"
        case let .pick(mode, item): "pick-\(mode.rawValue)-\(item.id)"
        case .list: "list"
        }
    }
}

/// What the sheet needs from its app.
@MainActor
struct AlarmSheetContext {
    let center: AlarmCenter
    /// What the player holds now, as an alarm would play it.
    let nowPlaying: () -> AlarmChoice?
    /// The item that played last, for "Then play" with nothing in the player.
    let lastPlayed: () -> AlarmChoice?
    let makeSource: () -> AlarmPickerSource
    let makePreview: () -> AlarmPreviewing?
}

private enum AlarmSheetRoute: Hashable {
    case picker
    case section(AlarmPickerModel.Section)
}

// MARK: - The quick sheet

/// The quick sheet: Timer presets or an Alarm, "Then play", and the alarms list.
struct AlarmQuickSheet: View {
    let context: AlarmSheetContext
    let onDone: () -> Void
    private let request: AlarmRequest
    @State private var setup: AlarmQuickSetup
    @State private var picker: AlarmPickerModel
    @State private var path: [AlarmSheetRoute] = []
    @State private var authorizationNote: String?
    @State private var saving = false
    private var center: AlarmCenter { context.center }
    private var store: AlarmStore { context.center.store }

    static let lastTimerKey = "baton.timer.lastSeconds"

    init(request: AlarmRequest, context: AlarmSheetContext, onDone: @escaping () -> Void) {
        self.request = request
        self.context = context
        self.onDone = onDone
        let store = context.center.store
        let lastTimer = (BatonStorage.defaults.object(forKey: Self.lastTimerKey) as? Int).map(TimeInterval.init)
        var mode: AlarmQuickSetup.Mode
        var preselected: AlarmChoice?
        switch request {
        case let .newAlarm(choice): mode = .alarm; preselected = choice
        case let .timer(choice): mode = .timer; preselected = choice
        case .editAlarm: mode = .alarm
        case let .pick(pickMode, _): mode = pickMode
        case .list: mode = store.timer != nil || store.alarms.isEmpty ? .timer : .alarm
        }
        let setup = AlarmQuickSetup(mode: mode, preselected: preselected, nowPlaying: context.nowPlaying(),
                                    lastPlayed: context.lastPlayed(), lastTimer: lastTimer)
        if case let .editAlarm(id) = request, let alarm = store.alarm(id: id) { setup.edit(alarm) }
        if case .pick = request { setup.resolving() }
        #if DEBUG
        // AlarmKitWalkUITests: a new alarm set a minute or so ahead, since a UI test cannot read
        // the clock to turn the wheel to it. Environment only.
        if setup.editingID == nil, let lead = ProcessInfo.processInfo.environment["uitestAlarmLeadSeconds"].flatMap(Double.init) {
            setup.setTime(Date().addingTimeInterval(lead + 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)))
        }
        #endif
        _setup = State(initialValue: setup)
        _picker = State(initialValue: AlarmPickerModel(source: context.makeSource(), preview: context.makePreview()))
    }

    var body: some View {
        @Bindable var setup = setup
        NavigationStack(path: $path) {
            Form {
                Section {
                    Picker("Mode", selection: $setup.mode) {
                        ForEach(AlarmQuickSetup.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("alarm-mode")
                }
                if setup.mode == .timer { timerSections } else { alarmSections }
            }
            .formStyle(.grouped)
            .navigationTitle(setup.mode == .timer ? "Timer" : (setup.editingID == nil ? "Alarm" : "Edit Alarm"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDone() }.accessibilityIdentifier("alarm-sheet-done")
                }
                // Start or Save where the eye goes first, always on screen in a half-height sheet.
                ToolbarItem(placement: .confirmationAction) {
                    if setup.mode == .timer {
                        if store.timer == nil {
                            Button("Start") { start() }
                                .fontWeight(.semibold)
                                .disabled(!setup.canStart)
                                .accessibilityIdentifier("timer-start")
                        }
                    } else {
                        Button(setup.editingID == nil ? "Save" : "Save Changes") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(!setup.canSave || saving)
                            .accessibilityIdentifier("alarm-save")
                    }
                }
            }
            .navigationDestination(for: AlarmSheetRoute.self) { route in
                switch route {
                case .picker: AlarmPickerView(model: picker, onPick: pick)
                case let .section(section): AlarmPickerSectionView(model: picker, section: section, onPick: pick)
                }
            }
        }
        .onChange(of: path) { _, now in if now.isEmpty { picker.close() } }
        .onDisappear { picker.close() }
        .task {
            guard case let .pick(_, item) = request else { return }
            // Nothing to play from the menu's item (an empty playlist, no server): Then play is
            // left empty with the reason, rather than quietly becoming something else. A fetch the
            // person overtook (they chose another row, or left the picker) changes nothing.
            let resolved = await picker.select(item)
            if resolved != nil || picker.failure != nil {
                setup.choose(resolved)
            } else if setup.isResolvingThenPlay {
                setup.choose(setup.thenPlay)
            }
        }
    }

    private func pick(_ choice: AlarmChoice) {
        setup.choose(choice)
        path = []
    }

    // MARK: Timer

    @ViewBuilder
    private var timerSections: some View {
        if store.timer != nil {
            Section {
                TimerRunningView(center: center)
            } header: {
                Text("Running")
            } footer: {
                Text("One timer at a time, as in Clock. Cancel it to set another.")
            }
        } else {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(AlarmQuickSetup.presetMinutes, id: \.self) { minutes in
                        PresetButton(title: minutes == 60 ? "1 hr" : "\(minutes) min",
                                     selected: setup.isSelected(minutes: minutes)) {
                            setup.selectPreset(minutes: minutes)
                        }
                        .accessibilityIdentifier("timer-preset-\(minutes)")
                    }
                    PresetButton(title: "Custom", selected: setup.isCustom) {
                        setup.selectCustom(setup.customDuration)
                    }
                    .accessibilityIdentifier("timer-preset-custom")
                }
                .padding(.vertical, 4)
                if setup.isCustom {
                    CustomDurationPicker(seconds: Binding(get: { setup.customDuration },
                                                          set: { setup.selectCustom($0) }))
                }
            } header: {
                Text("Start a timer")
            }
            Section {
                ThenPlayRow(setup: setup, note: picker.failure)
            } footer: {
                if setup.thenPlay == nil { Text("Choose what to play first.") }
            }
            #if os(macOS)
            // A popover has no toolbar, so the Mac keeps the button in the sheet.
            Section {
                Button { start() } label: {
                    Text(setup.duration.map { "Start \(AlarmQuickSetup.durationText($0))" } ?? "Start").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!setup.canStart)
                .accessibilityIdentifier("timer-start-button")
            }
            #endif
        }
    }

    private func start() {
        if setup.isCustom, let duration = setup.duration {
            BatonStorage.defaults.set(Int(duration), forKey: Self.lastTimerKey)
        }
        #if DEBUG
        // A UI test cannot wait five minutes: `uitestTimerSeconds` makes Start count that many
        // seconds instead, whatever preset was tapped. Environment only.
        if let seconds = ProcessInfo.processInfo.environment["uitestTimerSeconds"].flatMap(Double.init),
           let choice = setup.thenPlay, setup.canStart {
            store.startTimer(duration: seconds, label: setup.label, choice: choice)
            Task { await center.requestPermission() }
            onDone()
            return
        }
        #endif
        guard setup.startTimer(in: store) != nil else { return }
        Task { await center.requestPermission() }
        onDone()
    }

    // MARK: Alarm

    @ViewBuilder
    private var alarmSections: some View {
        @Bindable var setup = setup
        Section {
            DatePicker("Time", selection: Binding(get: { setup.timeDate() }, set: { setup.setTime($0) }),
                       displayedComponents: .hourAndMinute)
                #if os(iOS)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                #else
                .datePickerStyle(.stepperField)
                #endif
                .accessibilityIdentifier("alarm-time")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AlarmQuickSetup.quickPicks()) { pick in
                        Button(pick.title) { setup.apply(pick) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                    }
                }
            }
            .accessibilityIdentifier("alarm-quick-picks")
        }
        Section("Repeat") {
            RepeatDayToggles(days: $setup.repeatDays)
        }
        Section {
            TextField("Label", text: $setup.label, prompt: Text(BatonAlarm.defaultLabel))
                .accessibilityIdentifier("alarm-label")
            Toggle("Snooze", isOn: $setup.snooze)
            ThenPlayRow(setup: setup, note: picker.failure)
        }
        #if os(macOS)
        Section {
            Button { Task { await save() } } label: {
                Text(setup.editingID == nil ? "Save Alarm" : "Save Changes").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!setup.canSave || saving)
            .accessibilityIdentifier("alarm-save-button")
        }
        #endif
        if setup.editingID != nil || authorizationNote != nil {
            Section {
                if setup.editingID != nil {
                    Button("New Alarm Instead") { setup.newAlarm() }
                        .frame(maxWidth: .infinity)
                }
            } footer: {
                if let authorizationNote { Text(authorizationNote) }
            }
        }
        Section {
            if store.alarms.isEmpty {
                Text("No alarms yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            ForEach(store.alarms) { alarm in
                AlarmRow(alarm: alarm, store: store) { setup.edit(alarm) }
                    .contextMenu {
                        Button("Edit") { setup.edit(alarm) }
                        Button("Delete", role: .destructive) { delete(alarm.id) }
                    }
            }
            .onDelete { offsets in
                offsets.map { store.alarms[$0].id }.forEach(delete)
            }
        } header: {
            Text("Your Alarms")
        } footer: {
            Text(Self.footer)
        }
    }

    private func delete(_ id: UUID) {
        store.delete(id: id)
        if setup.editingID == id { setup.newAlarm() }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        guard setup.saveAlarm(in: store) != nil else { return }
        if center.system != nil, await !center.requestPermission() {
            authorizationNote = AlarmFormat.deniedNote
            try? await Task.sleep(for: .seconds(2))
        }
        onDone()
    }

    #if os(iOS)
    static let footer = "At the time, Baton plays what you chose. With the iPhone locked, the alarm rings and Play starts it; if Baton is already playing, it switches by itself."
    #else
    static let footer = "Baton plays what you chose at the time, as long as it is running (it stays in the menu bar). If Baton is not running, a notification opens it."
    #endif
}

private struct PresetButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .tint(selected ? Color.accentColor : .secondary)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Hours, minutes and seconds for a custom timer.
private struct CustomDurationPicker: View {
    @Binding var seconds: TimeInterval

    private var h: Int { Int(seconds) / 3600 }
    private var m: Int { Int(seconds) / 60 % 60 }
    private var s: Int { Int(seconds) % 60 }

    private func set(h: Int? = nil, m: Int? = nil, s: Int? = nil) {
        let total = (h ?? self.h) * 3600 + (m ?? self.m) * 60 + (s ?? self.s)
        seconds = TimeInterval(max(1, total))
    }

    var body: some View {
        HStack(spacing: 0) {
            wheel(h, range: 0 ..< 24, unit: "hr", id: "timer-hours") { set(h: $0) }
            wheel(m, range: 0 ..< 60, unit: "min", id: "timer-minutes") { set(m: $0) }
            wheel(s, range: 0 ..< 60, unit: "sec", id: "timer-seconds") { set(s: $0) }
        }
    }

    private func wheel(_ value: Int, range: Range<Int>, unit: String, id: String, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Picker(unit, selection: Binding(get: { value }, set: set)) {
                ForEach(range, id: \.self) { Text("\($0)").tag($0) }
            }
            #if os(iOS)
            .pickerStyle(.wheel)
            .frame(maxWidth: 70, maxHeight: 130)
            .clipped()
            #else
            .pickerStyle(.menu)
            #endif
            .labelsHidden()
            .accessibilityIdentifier(id)
            Text(unit).font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Seven day buttons in the locale's week order, Clock's repeat in one row.
private struct RepeatDayToggles: View {
    @Binding var days: Set<Int>
    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(AlarmRepeat.ordered(calendar), id: \.self) { day in
                    let on = days.contains(day)
                    Button {
                        if on { days.remove(day) } else { days.insert(day) }
                    } label: {
                        Text(calendar.veryShortWeekdaySymbols[day - 1])
                            .font(.callout.weight(.semibold))
                            .frame(width: 34, height: 34)
                            .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
                            .foregroundStyle(on ? Color.white : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(calendar.weekdaySymbols[day - 1])
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("alarm-day-\(day)")
                }
            }
            .frame(maxWidth: .infinity)
            Text(AlarmRepeat.summary(days)).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// "Then play": what plays when it goes off. Opens the picker.
private struct ThenPlayRow: View {
    let setup: AlarmQuickSetup
    var note: String?

    var body: some View {
        if setup.thenPlay == nil, let note {
            Text(note).font(.footnote).foregroundStyle(.secondary)
        }
        NavigationLink(value: AlarmSheetRoute.picker) {
            LabeledContent {
                if setup.isResolvingThenPlay {
                    ProgressView().controlSize(.small)
                } else if let choice = setup.thenPlay {
                    Label(choice.summary, systemImage: choice.symbol)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                } else {
                    Text("Choose…").foregroundStyle(.secondary)
                }
            } label: {
                Text("Then play")
            }
        }
        .accessibilityIdentifier("alarm-then-play")
    }
}

// MARK: - What to play

/// Search, Browse, then Recently played (the last 50 tracks). Needs nothing playing.
struct AlarmPickerView: View {
    let model: AlarmPickerModel
    let onPick: (AlarmChoice) -> Void

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                TextField("Songs, albums, playlists, books, radio", text: $model.query)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("alarm-picker-search")
            } header: {
                Label("Search", systemImage: "magnifyingglass")
            }
            if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section("Results") {
                    if model.isSearching && model.results.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if model.results.isEmpty {
                        Text("Nothing found").foregroundStyle(.secondary)
                    }
                    ForEach(model.results) { AlarmPickRow(item: $0, model: model, onPick: onPick) }
                }
            } else {
                // Browse sits above Recently played, which lists up to 50 tracks and would
                // otherwise push it a long scroll down.
                Section("Browse") {
                    ForEach(AlarmPickerModel.Section.allCases) { section in
                        NavigationLink(value: AlarmSheetRoute.section(section)) {
                            Label(section.rawValue, systemImage: section.symbol)
                        }
                    }
                }
                if !model.recent.isEmpty {
                    Section("Recently Played") {
                        ForEach(model.recent) { AlarmPickRow(item: $0, model: model, onPick: onPick) }
                    }
                }
            }
            if let failure = model.failure ?? model.previewFailure {
                Section { Text(failure).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("What to Play")
        .onAppear { model.load() }
        .task(id: model.query) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await model.search()
        }
    }
}

struct AlarmPickerSectionView: View {
    let model: AlarmPickerModel
    let section: AlarmPickerModel.Section
    let onPick: (AlarmChoice) -> Void
    @State private var items: [AlarmPickItem]?

    var body: some View {
        List {
            if let items {
                if items.isEmpty {
                    Text(section == .books ? "No books on this device." : "Nothing here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { AlarmPickRow(item: $0, model: model, onPick: onPick) }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let failure = model.failure ?? model.previewFailure {
                Section { Text(failure).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(section.rawValue)
        .task { items = await model.items(in: section) }
    }
}

/// One row: tap to choose it, the round button to hear ten seconds of it.
private struct AlarmPickRow: View {
    let item: AlarmPickItem
    let model: AlarmPickerModel
    let onPick: (AlarmChoice) -> Void

    var body: some View {
        let previewing = model.previewing == item.id
        HStack(spacing: 10) {
            Button {
                Task { if let choice = await model.select(item) { onPick(choice) } }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: item.symbol)
                        .frame(width: 24)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).lineLimit(1)
                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if model.resolving == item.id { ProgressView().controlSize(.small) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("alarm-pick-row")
            Button {
                Task { await model.togglePreview(item) }
            } label: {
                Image(systemName: previewing ? "stop.circle.fill" : "play.circle")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(previewing ? "Stop preview" : "Preview \(item.title)")
            .accessibilityIdentifier("alarm-pick-preview")
        }
    }
}

// MARK: - Rows and the running timer

struct AlarmRow: View {
    let alarm: BatonAlarm
    let store: AlarmStore
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AlarmFormat.time(hour: alarm.hour, minute: alarm.minute))
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .monospacedDigit()
                    Text(AlarmFormat.subtitle(alarm))
                        .font(.subheadline)
                    Label(alarm.choice.summary, systemImage: alarm.choice.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(alarm.isEnabled ? .primary : .secondary)
            Toggle("", isOn: Binding(get: { alarm.isEnabled }, set: { store.setEnabled($0, id: alarm.id) }))
                .labelsHidden()
                .accessibilityLabel("Alarm \(AlarmFormat.time(hour: alarm.hour, minute: alarm.minute))")
        }
        .accessibilityIdentifier("alarm-row")
    }
}

/// The running timer: Clock's countdown with Pause or Resume, and Cancel.
struct TimerRunningView: View {
    let center: AlarmCenter

    var body: some View {
        if let timer = center.store.timer {
            VStack(alignment: .leading, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Text(BatonTimer.clockFace(timer.remaining(at: context.date)))
                        .font(.system(size: 48, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .accessibilityIdentifier("timer-remaining")
                }
                Text(timer.displayLabel).font(.subheadline)
                Label("Then plays \(timer.choice.summary)", systemImage: timer.choice.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack {
                    Button("Cancel", role: .destructive) { center.store.cancelTimer() }
                        .accessibilityIdentifier("timer-cancel")
                    Spacer()
                    if timer.isPaused {
                        Button("Resume") { center.store.resumeTimer() }
                            .accessibilityIdentifier("timer-resume")
                    } else {
                        Button("Pause") { center.store.pauseTimer() }
                            .accessibilityIdentifier("timer-pause")
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - The pill

/// "Timer 12:34 · then X" above the mini player while a timer runs, and "Alarm 7:00 · then Y"
/// while an alarm is due within a day. With both set both show: stacked one above the other on
/// the iPhone, each as wide as the mini player (TBX-1000000410, after TBX-1000000140), side by side
/// in the Mac's player bar. Tapping one opens the sheet on it; its ✕ cancels only that one.
struct AlarmPill: View {
    let center: AlarmCenter
    let open: (AlarmPillState) -> Void
    var compact = false
    /// Spans the width it is given, text at the leading end and the ✕ at the trailing one, so
    /// on the iPhone it lines up with the mini player under it. Sized to its text, a long
    /// "then <title>" ran nearly edge to edge while a short one sat as a stub.
    /// Filling pills stack; compact ones sit in a row.
    var fillsWidth = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let pills = AlarmPillState.all(center.store, now: context.date)
            if !pills.isEmpty {
                if fillsWidth {
                    VStack(spacing: 6) { ForEach(pills, id: \.id) { capsule($0) } }
                } else {
                    HStack(spacing: 6) { ForEach(pills, id: \.id) { capsule($0) } }
                }
            }
        }
    }

    private func capsule(_ pill: AlarmPillState) -> some View {
        HStack(spacing: 8) {
            Button { open(pill) } label: {
                HStack(spacing: 6) {
                    Image(systemName: pill.symbol).foregroundStyle(Color.accentColor)
                    Text(compact ? pill.lead : pill.text)
                        .font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pill.text)
            .accessibilityHint("Opens Alarm and Timer")
            .accessibilityIdentifier("alarm-pill")
            Button {
                pill.cancel(in: center.store)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pill.kind == .alarm ? "Turn off this alarm" : "Cancel timer")
            .accessibilityIdentifier("alarm-pill-cancel")
        }
        .padding(.horizontal, compact ? 8 : 14)
        .padding(.vertical, compact ? 4 : 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        // The capsule itself, for a test to measure against the mini player.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alarm-pill-capsule")
    }
}

extension AlarmPillState {
    /// What tapping this pill opens: the timer's sheet, or the alarm to edit.
    var request: AlarmRequest { isTimer ? .list : .editAlarm(id) }
}

// MARK: - Going off

/// What went off, what is playing, and the three answers: Keep playing and open the player,
/// Snooze for nine minutes, or Stop. Full screen on the iPhone, a floating card on the Mac.
struct AlarmRingingCard: View {
    let center: AlarmCenter
    var fullScreen = false

    var body: some View {
        if let fire = center.ringing {
            VStack(spacing: fullScreen ? 18 : 12) {
                if fullScreen { Spacer(minLength: 20) }
                Image(systemName: fire.kind == .timer ? "timer" : "alarm.fill")
                    .font(fullScreen ? .system(size: 54) : .largeTitle)
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.bounce, options: .repeating)
                Text(fire.label).font(fullScreen ? .title.weight(.semibold) : .title2.weight(.semibold))
                Text(AlarmCenter.timeString(fire.occurrence))
                    .font(.system(size: fullScreen ? 76 : 40, weight: .light, design: .rounded))
                    .monospacedDigit()
                Label(fire.choice.summary, systemImage: fire.choice.symbol)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("alarm-ringing-choice")
                if fullScreen { Spacer(minLength: 20) }
                VStack(spacing: 10) {
                    Button {
                        center.keepPlayingAndShowPlayer()
                    } label: {
                        Label("Keep playing, open player", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("alarm-open-player")
                    if AlarmCenter.offersSnooze(fire) {
                        Button {
                            center.snoozeRinging()
                        } label: {
                            Label("Snooze 9 min", systemImage: "zzz").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("alarm-snooze")
                    }
                    Button(role: .destructive) {
                        center.stopRinging()
                    } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("alarm-stop")
                }
                .controlSize(.large)
                .frame(maxWidth: 420)
            }
            .padding(fullScreen ? 28 : 20)
            .frame(maxWidth: fullScreen ? .infinity : 360, maxHeight: fullScreen ? .infinity : nil)
            .background {
                if fullScreen {
                    Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
                } else {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial)
                }
            }
            .shadow(radius: fullScreen ? 0 : 18)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("alarm-ringing")
        }
    }
}

enum AlarmFormat {
    static func time(hour: Int, minute: Int) -> String {
        let date = Calendar.autoupdatingCurrent.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// "Alarm" or "Alarm, Weekdays", Clock's line under the time.
    static func subtitle(_ alarm: BatonAlarm) -> String {
        if let snoozed = alarm.snoozedUntil, snoozed > Date() {
            return "\(alarm.displayLabel), snoozed until \(snoozed.formatted(date: .omitted, time: .shortened))"
        }
        return alarm.repeats ? "\(alarm.displayLabel), \(AlarmRepeat.summary(alarm.repeatDays))" : alarm.displayLabel
    }

    #if os(iOS)
    static let deniedNote = "Alarms are turned off for Baton in Settings, so this one rings only while Baton is running. Turn them on in Settings > Apps > Baton."
    #else
    static let deniedNote = "Notifications are off for Baton, so this alarm works only while Baton is running."
    #endif
}
