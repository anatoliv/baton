import BatonPlaybackKit
import BatonSubsonicModels
import SwiftUI

// Alarm and Timer screens, one set for both apps (TBX-11171, specs/alarm-and-timer.md).
//
// Laid out the way Clock lays them out: a list of alarms with big times and a switch each, an
// editor with the time, Repeat, Label, what plays and Snooze, and a timer of hours, minutes and
// seconds with "When Timer Ends". Where Clock has a ringtone, Baton has the item that plays.

/// What the alarm sheet was opened for.
public enum AlarmRequest: Identifiable, Equatable {
    case newAlarm(AlarmChoice?)
    case editAlarm(UUID)
    case timer(AlarmChoice?)
    /// The list itself (the Mac opens it as a window, the phone pushes it from Settings).
    case list

    public var id: String {
        switch self {
        case .newAlarm: "new-alarm"
        case let .editAlarm(id): "edit-\(id.uuidString)"
        case .timer: "timer"
        case .list: "list"
        }
    }
}

/// The list: the timer, then the alarms, as Clock's Alarms tab.
struct AlarmsHomeView: View {
    let center: AlarmCenter
    /// What the player holds now, offered as the default for a new alarm or timer.
    let nowPlaying: () -> AlarmChoice?
    @State private var request: AlarmRequest?
    private var store: AlarmStore { center.store }

    var body: some View {
        List {
            Section {
                if store.timer != nil {
                    TimerRunningView(center: center)
                } else {
                    Button {
                        request = .timer(nowPlaying())
                    } label: {
                        Label("Start Timer…", systemImage: "timer")
                    }
                    .accessibilityIdentifier("alarms-start-timer")
                }
            } header: {
                Text("Timer")
            }

            Section {
                if store.alarms.isEmpty {
                    Text("No Alarms")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                }
                ForEach(store.alarms) { alarm in
                    AlarmRow(alarm: alarm, store: store) { request = .editAlarm(alarm.id) }
                        .contextMenu {
                            Button("Edit…") { request = .editAlarm(alarm.id) }
                            Button("Delete", role: .destructive) { store.delete(id: alarm.id) }
                        }
                }
                .onDelete { offsets in
                    offsets.map { store.alarms[$0].id }.forEach(store.delete(id:))
                }
            } header: {
                Text("Alarms")
            } footer: {
                Text(Self.footer)
            }
        }
        .navigationTitle("Alarms & Timer")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    request = .newAlarm(nowPlaying())
                } label: {
                    Label("Add Alarm", systemImage: "plus")
                }
                .accessibilityIdentifier("alarms-add")
            }
        }
        .sheet(item: $request) { request in
            AlarmSheet(request: request, center: center, nowPlaying: nowPlaying)
        }
    }

    #if os(iOS)
    static let footer = "At the time, Baton plays what you chose. With the iPhone locked, the alarm rings and Play starts it; if Baton is already playing, it switches by itself."
    #else
    static let footer = "Baton plays what you chose at the time, as long as it is running (it stays in the menu bar). If Baton is not running, a notification opens it."
    #endif
}

private struct AlarmRow: View {
    let alarm: BatonAlarm
    let store: AlarmStore
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AlarmFormat.time(hour: alarm.hour, minute: alarm.minute))
                        .font(.system(size: 44, weight: .light, design: .rounded))
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

/// The editor or the timer, in a sheet of its own.
struct AlarmSheet: View {
    let request: AlarmRequest
    let center: AlarmCenter
    let nowPlaying: () -> AlarmChoice?

    var body: some View {
        NavigationStack {
            switch request {
            case let .newAlarm(choice):
                AlarmEditorView(center: center, editing: nil, choice: choice ?? nowPlaying(), nowPlaying: nowPlaying)
            case let .editAlarm(id):
                AlarmEditorView(center: center, editing: center.store.alarm(id: id),
                                choice: center.store.alarm(id: id)?.choice ?? nowPlaying(), nowPlaying: nowPlaying)
            case let .timer(choice):
                if center.store.timer != nil {
                    TimerRunningSheet(center: center)
                } else {
                    TimerSetupView(center: center, choice: choice ?? nowPlaying(), nowPlaying: nowPlaying)
                }
            case .list:
                AlarmsHomeView(center: center, nowPlaying: nowPlaying)
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }
}

// MARK: - Alarm editor

struct AlarmEditorView: View {
    let center: AlarmCenter
    let editing: BatonAlarm?
    let nowPlaying: () -> AlarmChoice?
    @Environment(\.dismiss) private var dismiss
    @State private var time: Date
    @State private var repeatDays: Set<Int>
    @State private var label: String
    @State private var snooze: Bool
    @State private var choice: AlarmChoice?
    @State private var authorizationNote: String?

    init(center: AlarmCenter, editing: BatonAlarm?, choice: AlarmChoice?, nowPlaying: @escaping () -> AlarmChoice?) {
        self.center = center
        self.editing = editing
        self.nowPlaying = nowPlaying
        let calendar = Calendar.autoupdatingCurrent
        var start = editing.flatMap { calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: Date()) }
            ?? Self.nextRoundTime(calendar: calendar)
        #if DEBUG
        // AlarmKitWalkUITests: a new alarm set a minute or so ahead, since a UI test cannot read
        // the clock to turn the wheels to it. Environment only.
        if editing == nil, let lead = ProcessInfo.processInfo.environment["uitestAlarmLeadSeconds"].flatMap(Double.init),
           let soon = calendar.nextDate(after: Date().addingTimeInterval(lead), matching: DateComponents(second: 0),
                                        matchingPolicy: .nextTime) {
            start = soon
        }
        #endif
        _time = State(initialValue: start)
        _repeatDays = State(initialValue: editing?.repeatDays ?? [])
        _label = State(initialValue: editing?.label ?? "")
        _snooze = State(initialValue: editing?.snoozeEnabled ?? true)
        _choice = State(initialValue: choice)
    }

    /// A new alarm starts at the next whole hour, a sensible place to turn the wheels from.
    static func nextRoundTime(calendar: Calendar) -> Date {
        calendar.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
    }

    var body: some View {
        Form {
            Section {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    #if os(iOS)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    #else
                    .datePickerStyle(.stepperField)
                    #endif
                    .accessibilityIdentifier("alarm-time")
            }
            Section {
                NavigationLink {
                    RepeatDaysView(days: $repeatDays)
                } label: {
                    LabeledContent("Repeat", value: AlarmRepeat.summary(repeatDays))
                }
                TextField("Label", text: $label, prompt: Text(BatonAlarm.defaultLabel))
                    .accessibilityIdentifier("alarm-label")
                PlayChoiceRow(choice: $choice, nowPlaying: nowPlaying)
                Toggle("Snooze", isOn: $snooze)
            } footer: {
                if let authorizationNote { Text(authorizationNote) }
            }
            if let editing {
                Section {
                    Button("Delete Alarm", role: .destructive) {
                        center.store.delete(id: editing.id)
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(editing == nil ? "Add Alarm" : "Edit Alarm")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(choice == nil)
                    .accessibilityIdentifier("alarm-save")
            }
        }
    }

    private func save() async {
        guard let choice else { return }
        let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: time)
        let alarm = BatonAlarm(id: editing?.id ?? UUID(), hour: parts.hour ?? 7, minute: parts.minute ?? 0,
                               repeatDays: repeatDays, label: label, snoozeEnabled: snooze, isEnabled: true, choice: choice)
        center.store.save(alarm)
        if center.system != nil, await !center.requestPermission() {
            authorizationNote = AlarmFormat.deniedNote
            try? await Task.sleep(for: .seconds(2))
        }
        dismiss()
    }
}

private struct RepeatDaysView: View {
    @Binding var days: Set<Int>
    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        List {
            ForEach(AlarmRepeat.ordered(calendar), id: \.self) { day in
                Button {
                    if days.contains(day) { days.remove(day) } else { days.insert(day) }
                } label: {
                    HStack {
                        Text("Every \(calendar.weekdaySymbols[day - 1])")
                        Spacer()
                        if days.contains(day) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Repeat")
    }
}

/// Clock's "Sound" row, which in Baton is what plays.
private struct PlayChoiceRow: View {
    @Binding var choice: AlarmChoice?
    let nowPlaying: () -> AlarmChoice?

    var body: some View {
        let current = nowPlaying()
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Play") {
                if let choice {
                    Label(choice.summary, systemImage: choice.symbol)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                } else {
                    Text("Nothing chosen").foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("alarm-play-choice")
            if let current, current != choice {
                Button("Use What's Playing Now") { choice = current }
                    .font(.footnote)
            }
            if choice == nil {
                Text("Choose a song from its menu (Set Alarm…), or start something playing first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Timer

struct TimerSetupView: View {
    let center: AlarmCenter
    let nowPlaying: () -> AlarmChoice?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("baton.timer.lastSeconds") private var lastSeconds = 15 * 60
    @State private var hours = 0
    @State private var minutes = 15
    @State private var seconds = 0
    @State private var label = ""
    @State private var choice: AlarmChoice?
    @State private var loaded = false

    init(center: AlarmCenter, choice: AlarmChoice?, nowPlaying: @escaping () -> AlarmChoice?) {
        self.center = center
        self.nowPlaying = nowPlaying
        _choice = State(initialValue: choice)
    }

    private var total: Int { hours * 3600 + minutes * 60 + seconds }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 0) {
                    wheel($hours, range: 0 ..< 24, unit: "hours", id: "timer-hours")
                    wheel($minutes, range: 0 ..< 60, unit: "min", id: "timer-minutes")
                    wheel($seconds, range: 0 ..< 60, unit: "sec", id: "timer-seconds")
                }
            }
            Section {
                TextField("Label", text: $label, prompt: Text(BatonTimer.defaultLabel))
                PlayChoiceRow(choice: $choice, nowPlaying: nowPlaying)
            } header: {
                Text("When Timer Ends")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Timer")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            guard !loaded else { return }
            loaded = true
            hours = lastSeconds / 3600
            minutes = lastSeconds / 60 % 60
            seconds = lastSeconds % 60
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") {
                    guard let choice, total > 0 else { return }
                    lastSeconds = total
                    center.store.startTimer(duration: TimeInterval(total), label: label, choice: choice)
                    Task { await center.requestPermission() }
                    dismiss()
                }
                .disabled(choice == nil || total == 0)
                .accessibilityIdentifier("timer-start")
            }
        }
    }

    private func wheel(_ value: Binding<Int>, range: Range<Int>, unit: String, id: String) -> some View {
        HStack(spacing: 4) {
            Picker(unit, selection: value) {
                ForEach(range, id: \.self) { Text("\($0)").tag($0) }
            }
            #if os(iOS)
            .pickerStyle(.wheel)
            .frame(maxWidth: 70)
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

private struct TimerRunningSheet: View {
    let center: AlarmCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form { TimerRunningView(center: center) }
            .formStyle(.grouped)
            .navigationTitle("Timer")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: center.store.timer == nil) { _, gone in if gone { dismiss() } }
    }
}

// MARK: - Going off

/// Clock's ringing screen, as a card: what went off, what is playing, Stop, Snooze, Keep Playing.
struct AlarmRingingCard: View {
    let center: AlarmCenter

    var body: some View {
        if let fire = center.ringing {
            VStack(spacing: 12) {
                Image(systemName: fire.kind == .timer ? "timer" : "alarm.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.bounce, options: .repeating)
                Text(fire.label).font(.title2.weight(.semibold))
                Text(AlarmCenter.timeString(fire.occurrence))
                    .font(.system(size: 40, weight: .light, design: .rounded))
                    .monospacedDigit()
                Label(fire.choice.summary, systemImage: fire.choice.symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    if fire.kind == .alarm, fire.snoozeEnabled {
                        Button("Snooze") { center.snoozeRinging() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("alarm-snooze")
                    }
                    Button("Stop") { center.stopRinging() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("alarm-stop")
                }
                .controlSize(.large)
                Button("Keep Playing") { center.keepPlaying() }
                    .font(.footnote)
                    .accessibilityIdentifier("alarm-keep-playing")
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(radius: 18)
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
