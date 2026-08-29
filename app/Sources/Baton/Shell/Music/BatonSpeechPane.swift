import SwiftUI

/// Settings → Speech: configure the `speak_summary` feature. Two self-hosted TTS hosts
/// (Kokoro presets, Chatterbox premium/cloning) and an editable **category → voice** map.
/// The agent picks a voice per call (by `category` or explicit `voice`); this screen is where
/// you point Baton at your servers and decide what each category sounds like — with a live
/// voice list pulled from each server and a per-row Preview button.
///
/// Mirrors the grouped-`Form` + `LabeledContent` idiom of the other panes (`BatonPlaybackPane`,
/// `BatonAboutPane`); persistence goes through the static `SpeechConfig` (UserDefaults).
struct BatonSpeechPane: View {
    @Environment(MusicModel.self) private var model

    @State private var kokoroHost = SpeechConfig.kokoroBaseURL
    @State private var chatterboxHost = SpeechConfig.chatterboxBaseURL
    @State private var fallbackEnabled = SpeechConfig.fallbackEnabled
    @State private var announceImmediately = SpeechConfig.announceImmediately
    @State private var alertNotification = SpeechConfig.alertWithNotification
    @State private var alertBanner = SpeechConfig.alertWithBanner
    @State private var allowAutoPlay = SpeechConfig.allowAutoPlay
    @State private var bluetoothWarmup = SpeechConfig.bluetoothWarmup
    @State private var voiceRows: [SessionVoiceRow] = []

    /// A row of the agent-voice list, with a stable id so SwiftUI can bind to it while the
    /// label is being typed.
    struct SessionVoiceRow: Identifiable, Equatable {
        var id = UUID()
        var label: String
        var voice: String
    }
    @State private var transcriptionEnabled = SpeechConfig.transcriptionEnabled
    @State private var whisperHost = SpeechConfig.whisperBaseURL
    @State private var whisperModel = SpeechConfig.whisperModel
    @State private var whisperStatus: ServiceStatus = .unknown

    /// The map rendered as ordered, editable rows (a `[String: String]` dict has no order).
    @State private var rows: [VoiceRow] = []

    /// Live voice ids fetched from each server, used to populate the per-row voice pickers.
    @State private var voices: [SpeechConfig.Engine: [String]] = [:]
    @State private var loadState: [SpeechConfig.Engine: ServiceStatus] = [:]
    @State private var previewing: VoiceRow.ID?
    @State private var statusMessage: String?
    @State private var showResetConfirm = false

    // Read aloud (specs/read-aloud.md)
    @State private var perSourceVoices = ReadAloudSettings.perSourceVoices
    @State private var allowClipboardFallback = ReadAloudSettings.allowClipboardFallback
    /// Re-read whenever the pane appears or the app comes forward, because the grant is changed
    /// in System Settings — outside this app entirely — and a pane that still claims "granted"
    /// after it was revoked is worse than one that never mentioned it.
    @State private var accessibilityTrusted = SelectionReader.isTrusted
    @State private var ocrEnabled = ReadAloudSettings.ocrEnabled
    /// How many unfinished readings are held, for the line that tells the user so.
    @State private var unfinishedCount = ReadAloudCoordinator.current?.unfinished.entries.count ?? 0
    @State private var screenRecordingPermitted = ScreenTextOCR.isPermitted

    struct VoiceRow: Identifiable, Equatable {
        let id = UUID()
        var category: String
        var engine: SpeechConfig.Engine
        var voice: String
    }

    var body: some View {
        Form {
            // Order follows the speak_summary story: where the voices come from, how a
            // summary reaches you, which voice each agent gets, then the category map.
            // Read aloud is a different feature and sits below them rather than between —
            // it is 300 lines of permissions and toggles, and having it in the middle put
            // the voice settings somewhere nobody scrolled to.
            // Agent voices sits second, directly under the servers that supply them.
            // It was below Delivery and Transcription and could not be found: three separate
            // times the answer to "where is it?" was "keep scrolling". A setting people open
            // the pane to change belongs where the pane opens.
            hostsSection
            voicesSection
            deliverySection
            mapSection
            transcriptionSection
            readAloudSection
            resetSection
        }
        .formStyle(.grouped)
        .onAppear {
            // Make `browser` and `terminal` visible in the map below, so enabling per-source
            // voices needs no typing.
            ReadAloudSettings.seedVoiceCategoriesIfNeeded()
            accessibilityTrusted = SelectionReader.isTrusted
            screenRecordingPermitted = ScreenTextOCR.isPermitted
            // Re-read on appear, not only at init: the count changes while the pane is closed,
            // and a stale "3 saved" next to a button that clears nothing reads as a lie.
            unfinishedCount = ReadAloudCoordinator.current?.unfinished.entries.count ?? 0
            loadRows()
            SpeechConfig.migrateLegacySessionVoicesIfNeeded()
            loadVoiceRows()
        }
        // Keep the service badges true for as long as the window is open.
        //
        // They used to be probed once, in `onAppear`. That is right for the first paint and
        // wrong for every moment after it: a host that came up while Settings was open went
        // on reading "unreachable" until you pressed Refresh, so the pane reported the state
        // of the LAN at the instant you opened it and looked like the state now. Worse, that
        // is exactly backwards from what you are usually doing here — you open this pane
        // *because* you are bringing a server up.
        //
        // `.task` starts on appear and is cancelled on disappear, so nothing polls a window
        // that is closed. The re-checks are silent (see `refreshVoices`), so a badge changes
        // only when the answer does.
        .task {
            await probeServices(silent: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.servicePollInterval)
                guard !Task.isCancelled else { return }
                await probeServices(silent: true)
            }
        }
        // Coming back to Baton is the other moment the answer is likely to have changed —
        // you went away, started the server, and came back to look.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await probeServices(silent: true) }
        }
        .confirmationDialog("Reset Speech settings to defaults?", isPresented: $showResetConfirm) {
            Button("Reset to Defaults", role: .destructive) {
                SpeechConfig.resetToDefaults()
                fallbackEnabled = SpeechConfig.fallbackEnabled
                announceImmediately = SpeechConfig.announceImmediately
                alertNotification = SpeechConfig.alertWithNotification
                alertBanner = SpeechConfig.alertWithBanner
                allowAutoPlay = SpeechConfig.allowAutoPlay
                bluetoothWarmup = SpeechConfig.bluetoothWarmup
                loadVoiceRows()
                loadRows()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores the default category → voice map, the fallback toggle, and delivery preferences. Your server addresses are kept.")
        }
    }

    // MARK: - Read aloud

    /// Speaking text from other apps — Chrome, a terminal, anything that vends a selection.
    /// See `specs/read-aloud.md`; the shipped state is "works with no permission, no shortcut".
    private var readAloudSection: some View {
        Section("Read aloud") {
            LabeledContent("Keyboard shortcut") {
                ReadAloudHotKeyRecorder()
            }
            Text("Speaks whatever is selected in the app you are using. You do not need a shortcut: select text anywhere and choose Services → Speak with Baton, which needs no permission at all.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // The permission state, stated plainly rather than left to fail at use time.
            LabeledContent("Accessibility") {
                HStack(spacing: 8) {
                    Text(accessibilityTrusted ? "Granted" : "Not granted")
                        .foregroundStyle(accessibilityTrusted ? .secondary : .primary)
                    if !accessibilityTrusted {
                        Button("Open System Settings") {
                            SelectionReader.requestTrust()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            Text(accessibilityTrusted
                 ? "The shortcut can read your selection from the app you are using. Services works with or without this."
                 : "Without it the shortcut cannot read your selection. The Services menu item still works.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Use the clipboard when an app will not share its selection", isOn: $allowClipboardFallback)
                .onChange(of: allowClipboardFallback) { _, v in ReadAloudSettings.allowClipboardFallback = v }
            Text("Some apps, Chrome among them, do not hand over the selected text directly. Baton can copy it instead and put your clipboard back afterwards. Turn this off if you would rather it never touched the clipboard — the shortcut will then do nothing in those apps.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // What "readings are not saved" now means, exactly, and a way to act on it. The
            // promise narrowed when resume shipped; saying so here, next to the other
            // read-aloud settings, is part of the deal rather than an afterthought.
            HStack(alignment: .firstTextBaseline) {
                Text("Unfinished readings")
                Spacer()
                Button("Forget Them Now") {
                    ReadAloudCoordinator.current?.unfinished.clear()
                    unfinishedCount = 0
                }
                .disabled(unfinishedCount == 0)
            }
            Text(unfinishedCount == 0
                 ? "Stop part-way through an article and Baton keeps your place so you can carry on from File → Resume Reading. Nothing is kept right now. Up to \(UnfinishedReadings.maximumEntries) readings are held, for \(Int(UnfinishedReadings.retention / 86_400)) days, and only the cleaned text you actually heard."
                 : "\(unfinishedCount) saved, resumable from File → Resume Reading. Up to \(UnfinishedReadings.maximumEntries) are held, for \(Int(UnfinishedReadings.retention / 86_400)) days, and only the cleaned text you actually heard — anything that looked like a password or a key was removed before it was spoken, so it was never written here either.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Use a different voice per app", isOn: $perSourceVoices)
                .onChange(of: perSourceVoices) { _, v in ReadAloudSettings.perSourceVoices = v }
            Text("Reads a browser and a terminal in different voices, so you can hear where the text came from. The voices are the \"browser\" and \"terminal\" rows below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Read a window Baton cannot get text from", isOn: $ocrEnabled)
                .onChange(of: ocrEnabled) { _, v in
                    ReadAloudSettings.ocrEnabled = v
                    ReadAloudHotKey.shared.apply()   // register or drop the Option chord now
                    if v, !ScreenTextOCR.isPermitted { ScreenTextOCR.requestPermission() }
                    screenRecordingPermitted = ScreenTextOCR.isPermitted
                }
            Text(ocrEnabled
                 ? (screenRecordingPermitted
                    ? "Hold Option with your shortcut to capture the window in front and read the words out of the picture: a PDF, an image, a page that shares nothing. Baton captures only when you press it, only that window, and never saves the picture."
                    : "Needs Screen Recording, which has not been granted. Until it is, holding Option does nothing.")
                 : "Off. Some things have no text to hand over at all, such as a PDF, an image, or a screen shared from another machine. Turning this on lets Option plus your shortcut photograph the front window and read what it can see. It needs Screen Recording, the largest thing Baton asks for.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if ocrEnabled, !screenRecordingPermitted {
                Button("Open System Settings") {
                    ScreenTextOCR.requestPermission()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Text("Readings are not saved. They play once and do not appear in Spoken Summaries, and nothing watches your screen — Baton only ever reads what you ask it to, when you ask.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Delivery

    private var deliverySection: some View {
        Section("Delivery") {
            // Primary: one timing choice. `false` == let the agent decide, `true` == announce now.
            Picker("When a summary arrives", selection: $announceImmediately) {
                Text("Let the agent decide").tag(false)
                Text("Announce immediately").tag(true)
            }
            .pickerStyle(.radioGroup)
            .onChange(of: announceImmediately) { _, on in SpeechConfig.announceImmediately = on; enforceReachable() }
            Text(announceImmediately
                 ? "Every summary is spoken as soon as the audio is ready. Your own opt-in, so it isn't gated."
                 : "The agent decides whether a summary is urgent enough to speak right away (if you allow it just below) or simply wait — and it reaches you through the alerts below.")
                .font(.callout).foregroundStyle(.secondary)

            // The auto-play gate — a refinement of "Let the agent decide", not a peer. Irrelevant
            // (and disabled) once you've chosen to announce everything yourself.
            Toggle("Allow the agent to play it immediately", isOn: $allowAutoPlay)
                .onChange(of: allowAutoPlay) { _, on in SpeechConfig.allowAutoPlay = on }
                .disabled(announceImmediately)
                .padding(.leading, 18)
            Text("Lets an agent's `mode: \"auto\"` speak without confirmation. Off by default — a safety gate so a leaked token can't blast audio; when off, an agent's summaries just wait as the alerts below.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.leading, 18)

            // Alert surfaces — independent, and available under BOTH primary choices.
            Toggle("Alert with a notification", isOn: $alertNotification)
                .onChange(of: alertNotification) { _, on in SpeechConfig.alertWithNotification = on; enforceReachable() }
            Toggle("Alert with an in-app banner", isOn: $alertBanner)
                .onChange(of: alertBanner) { _, on in SpeechConfig.alertWithBanner = on; enforceReachable() }
            Text("Where summaries show up — pick either, both, or neither. A notification and a banner each carry a **Play** button; with **Announce immediately** they're a replayable record. If a waiting summary would have nowhere to go, a banner is kept on so it's never lost.")
                .font(.callout).foregroundStyle(.secondary)

            Divider()

            // Bluetooth wake-up. Only meaningful over Bluetooth, so it says so rather than
            // sitting there implying every summary is being delayed.
            LabeledContent("Bluetooth head start") {
                HStack {
                    Slider(value: $bluetoothWarmup, in: 0 ... 3, step: 0.1)
                        .frame(width: 200)
                    Text(bluetoothWarmup == 0 ? "off" : String(format: "%.1fs", bluetoothWarmup))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .leading)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: bluetoothWarmup) { _, seconds in SpeechConfig.bluetoothWarmup = seconds }
            Text("A Bluetooth speaker sleeps when nothing is playing and takes a moment to wake, which otherwise eats the first word. Baton holds silence for this long before speaking, but **only** over Bluetooth — wired and built-in output are never delayed. Raise it if you still lose the start; the Console log reports how long your speaker actually took.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Keep the reachability invariant the resolver enforces visible in the UI: under "Let the
    /// agent decide", a summary that isn't spoken needs a surface — so if both alerts are off,
    /// snap the banner back on. Mirrors `SpeechConfig.deliveryPlan`.
    private func enforceReachable() {
        guard !announceImmediately, !alertNotification, !alertBanner else { return }
        alertBanner = true
        SpeechConfig.alertWithBanner = true
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
            }
        }
    }

    // MARK: - Services (hosts)

    private var hostsSection: some View {
        Section("Services") {
            hostRow(name: "Kokoro", detail: "Preset voices · fast", text: $kokoroHost, engine: .kokoro) {
                SpeechConfig.kokoroBaseURL = kokoroHost.trimmingCharacters(in: .whitespaces)
            }
            errorRow(for: .kokoro)
            hostRow(name: "Chatterbox", detail: "Premium · voice cloning", text: $chatterboxHost, engine: .chatterbox) {
                SpeechConfig.chatterboxBaseURL = chatterboxHost.trimmingCharacters(in: .whitespaces)
            }
            errorRow(for: .chatterbox)
            Text("Self-hosted TTS endpoints (OpenAI-compatible). The agent calls **speak_summary**; Baton synthesizes here and plays the result.")
                .font(.callout).foregroundStyle(.secondary)

            Toggle("Fall back to the system voice", isOn: $fallbackEnabled)
                .onChange(of: fallbackEnabled) { _, on in SpeechConfig.fallbackEnabled = on }
            Text("If a server is unreachable, speak the summary with the built-in macOS voice (`AVSpeechSynthesizer`) so it's never silently dropped.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// The ASR host, kept apart from the TTS hosts above rather than squeezed into their row:
    /// those carry voice loading and an engine enum that means nothing here, and transcription
    /// has its own switch because it ships audio off the device rather than fetching some back.
    private var transcriptionSection: some View {
        Section("Transcription") {
            Toggle("Transcribe spoken tracks", isOn: $transcriptionEnabled)
                .onChange(of: transcriptionEnabled) { _, on in SpeechConfig.transcriptionEnabled = on }
            Text("Send a podcast episode to a self-hosted Whisper and read what was said, with every line seekable. Off by default: this uploads the audio to the server below.")
                .font(.callout).foregroundStyle(.secondary)

            LabeledContent("Whisper host") {
                HStack(spacing: 8) {
                    TextField(text: $whisperHost, prompt: Text("http://host:port")) { EmptyView() }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 200)
                        .onChange(of: whisperHost) { _, value in
                            SpeechConfig.whisperBaseURL = value.trimmingCharacters(in: .whitespaces)
                            // The tick belongs to the address that was checked, not to the
                            // field. Editing it makes the old answer a claim about somewhere
                            // else, so it goes back to unchecked until someone checks.
                            whisperStatus = .unknown
                        }
                        .onSubmit { Task { await testTranscriptionHost() } }
                    ServiceStatusBadge(status: whisperStatus)
                    Button { Task { await testTranscriptionHost() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Test this connection")
                    .disabled(whisperStatus.isChecking)
                }
            }
            LabeledContent("Model") {
                TextField(text: $whisperModel, prompt: Text("whisper-1")) { EmptyView() }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200)
                    .onChange(of: whisperModel) { _, value in
                        SpeechConfig.whisperModel = value.trimmingCharacters(in: .whitespaces)
                    }
            }
            if let detail = whisperStatus.detail, case .ok = whisperStatus {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            failureRow(whisperStatus)
        }
    }

    /// Prove the address before anyone waits on an hour of audio to discover it was wrong.
    /// How often the open pane re-checks the hosts. Three small LAN requests; frequent
    /// enough that bringing a server up feels immediate, slow enough to be invisible.
    private static let servicePollInterval: Duration = .seconds(10)

    /// Re-probe both TTS hosts and the ASR host together, concurrently — they are independent,
    /// and a slow or timing-out one must not delay the others' badges.
    private func probeServices(silent: Bool) async {
        // Debug level, so it costs nothing in a normal run and is there when someone asks
        // "is it actually re-checking?" — the question that is otherwise unanswerable about
        // a poll whose whole job is to change nothing most of the time.
        speechLog.debug("speech settings: probing services (silent: \(silent, privacy: .public))")
        async let kokoro: Void = refreshVoices(.kokoro, silent: silent)
        async let chatterbox: Void = refreshVoices(.chatterbox, silent: silent)
        async let whisper: Void = testTranscriptionHost(silent: silent)
        _ = await (kokoro, chatterbox, whisper)
    }

    private func testTranscriptionHost(silent: Bool = false) async {
        let host = SpeechConfig.whisperBaseURL.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            whisperStatus = .notConfigured("No host yet")
            return
        }
        if !silent { whisperStatus = .checking }
        do {
            let models = try await TranscriptionService.availableModels()
            whisperStatus = .ok(
                detail: models.isEmpty
                    ? "Connected, but the host listed no models."
                    : "Connected. Models: " + models.prefix(6).joined(separator: ", "),
                badge: models.isEmpty ? nil : "\(models.count)"
            )
        } catch let error as TranscriptionService.TranscribeError {
            // `isUnreachable` is the transport failure; anything else is a host that answered
            // with something Baton couldn't use, which is still not a working transcription
            // service and must not read as one.
            whisperStatus = .unreachable(error.message)
        } catch {
            whisperStatus = .unreachable(ServiceStatus.describe(error))
        }
    }

    private func hostRow(name: String, detail: String, text: Binding<String>, engine: SpeechConfig.Engine, commit: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField(text: text, prompt: Text("http://host:port")) { EmptyView() }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200)
                    .onChange(of: text.wrappedValue) { _, _ in
                        commit()
                        loadState[engine] = .unknown   // same rule as the ASR host below
                    }
                    .onSubmit { commit(); Task { await refreshVoices(engine) } }
                ServiceStatusBadge(status: loadState[engine] ?? .unknown)
                Button {
                    commit()
                    Task { await refreshVoices(engine) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Test this connection")
                .disabled(loadState[engine]?.isChecking == true)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Shows the actual failure reason inline (not just a tooltip) when a host is unreachable.
    @ViewBuilder
    private func errorRow(for engine: SpeechConfig.Engine) -> some View {
        failureRow(loadState[engine] ?? .unknown)
    }

    /// The one place a failed check turns into readable text, so all three hosts explain
    /// themselves the same way instead of one of them only having a tooltip.
    @ViewBuilder
    private func failureRow(_ status: ServiceStatus) -> some View {
        if case let .unreachable(why) = status {
            Label(why, systemImage: status.symbol)
                .font(.callout)
                .foregroundStyle(status.tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if case let .refused(why) = status {
            Label(why, systemImage: status.symbol)
                .font(.callout)
                .foregroundStyle(status.tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Category → voice map

    /// Voices the list already uses, for `engine`, so a picker can offer them first.
    private func listedVoiceIDs(for engine: SpeechConfig.Engine) -> [String] {
        voiceRows.compactMap { row in
            let parts = row.voice.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return SpeechConfig.Engine(rawValue: parts[0].lowercased()) == engine ? parts[1] : nil
            }
            return engine == .kokoro ? row.voice : nil
        }
    }

    /// Session names Baton has actually heard from, newest first. Used only to offer one-tap
    /// additions: the agents that have spoken are exactly the ones worth a row.
    private var knownSessions: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in model.speechHistory.entries {
            guard let label = entry.sessionLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty, seen.insert(label.lowercased()).inserted
            else { continue }
            out.append(label)
        }
        return out
    }

    /// Heard-from sessions with no row yet.
    private var unlistedSessions: [String] {
        let listed = Set(voiceRows.map { SpeechConfig.voiceKey($0.label) })
        return knownSessions.filter { !listed.contains(SpeechConfig.voiceKey($0)) }
    }

    private var voicesSection: some View {
        Section("Agent voices") {
            if !voiceRows.isEmpty {
                HStack(spacing: 12) {
                    Text("Agent").frame(width: categoryWidth, alignment: .leading)
                    Text("Voice").frame(width: voiceWidth, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .font(.caption).foregroundStyle(.secondary)

                ForEach($voiceRows) { $row in voiceRow($row) }
                    .onDelete { voiceRows.remove(atOffsets: $0); persistVoiceRows() }
                    .onMove { from, to in voiceRows.move(fromOffsets: from, toOffset: to); persistVoiceRows() }
            }

            HStack(spacing: 12) {
                Button {
                    voiceRows.append(.init(label: "", voice: defaultVoiceSpec))
                    persistVoiceRows()
                } label: {
                    Label("Add Agent", systemImage: "plus")
                }

                // One tap for an agent Baton has already heard from, so the common case needs
                // no typing and no guessing at the exact spelling the agent sends.
                if !unlistedSessions.isEmpty {
                    Menu("Add one Baton has heard") {
                        ForEach(unlistedSessions, id: \.self) { name in
                            Button(name) {
                                voiceRows.append(.init(label: name, voice: defaultVoiceSpec))
                                persistVoiceRows()
                            }
                        }
                    }
                    .fixedSize()
                }
            }

            Text("An agent that sends a `session` name speaks in the voice you give it here. The label is matched loosely — case and surrounding spaces do not matter — and it can be anything you like, not only a repo name. Anything **not** in this list speaks in a voice from outside it, the same one every time, so a named project never shares its sound with an unnamed one. An explicit `voice` in the tool call still wins over all of it.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func voiceRow(_ row: Binding<SessionVoiceRow>) -> some View {
        HStack(spacing: 12) {
            TextField(text: row.label, prompt: Text("project or label")) { EmptyView() }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: categoryWidth)
                .onSubmit { persistVoiceRows() }

            // Same offline rule as the category rows: with no server reachable there is no
            // list to choose from, and a picker of one item is a dead control.
            if allVoiceSpecs.isEmpty {
                TextField(text: row.voice, prompt: Text("engine:voice")) { EmptyView() }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: voiceWidth)
                    .onSubmit { persistVoiceRows() }
            } else {
                Picker(selection: row.voice) {
                    if !allVoiceSpecs.contains(row.wrappedValue.voice) {
                        Text(voiceID(of: row.wrappedValue.voice)).tag(row.wrappedValue.voice)
                    }
                    ForEach(allVoiceSpecs, id: \.self) { Text(voiceID(of: $0)).tag($0) }
                } label: { EmptyView() }
                    .labelsHidden()
                    .fixedSize()
                    .frame(width: voiceWidth, alignment: .leading)
                    .onChange(of: row.wrappedValue.voice) { _, _ in persistVoiceRows() }
            }

            // A duplicate label is silently ignored by the matcher (first row wins), so say so
            // rather than letting a row sit there looking effective.
            if isDuplicate(row.wrappedValue) {
                Text("duplicate").font(.caption).foregroundStyle(.orange)
                    .help("Another row already claims this label. The first one wins.")
            }

            Spacer(minLength: 8)

            Button {
                preview(VoiceRow(category: row.wrappedValue.label,
                                 engine: engineOf(row.wrappedValue.voice),
                                 voice: voiceID(of: row.wrappedValue.voice)))
            } label: {
                if previewing != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.circle").imageScale(.large)
                }
            }
            .buttonStyle(.borderless)
            .help("Preview this voice")
            .disabled(previewing != nil)
        }
    }

    private func isDuplicate(_ row: SessionVoiceRow) -> Bool {
        let key = SpeechConfig.voiceKey(row.label)
        guard !key.isEmpty else { return false }
        guard let first = voiceRows.first(where: { SpeechConfig.voiceKey($0.label) == key }) else { return false }
        return first.id != row.id
    }

    private func loadVoiceRows() {
        voiceRows = SpeechConfig.sessionVoiceList().map {
            SessionVoiceRow(id: $0.id, label: $0.label, voice: $0.voice)
        }
    }

    private func persistVoiceRows() {
        SpeechConfig.setSessionVoiceList(voiceRows.map {
            SpeechConfig.SessionVoice(id: $0.id, label: $0.label, voice: $0.voice)
        })
    }

    /// Every voice both servers offered, as `engine:voice` specs.
    private var allVoiceSpecs: [String] {
        (voices[.kokoro] ?? []).map { "kokoro:\($0)" } + (voices[.chatterbox] ?? []).map { "chatterbox:\($0)" }
    }

    private var defaultVoiceSpec: String {
        allVoiceSpecs.first ?? "kokoro:af_heart"
    }

    private func voiceID(of spec: String) -> String {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        return parts.count == 2 ? parts[1] : spec
    }

    private func engineOf(_ spec: String) -> SpeechConfig.Engine {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, let e = SpeechConfig.Engine(rawValue: parts[0].lowercased()) { return e }
        return .kokoro
    }

    private var mapSection: some View {
        Section("Voices") {
            if !rows.isEmpty {
                columnHeader
                ForEach($rows) { $row in mapRow($row) }
                    .onDelete { rows.remove(atOffsets: $0); persistMap() }
            }
            Button {
                rows.append(VoiceRow(category: "", engine: .kokoro, voice: voices[.kokoro]?.first ?? "af_heart"))
            } label: {
                Label("Add Category", systemImage: "plus")
            }
            if let statusMessage {
                Label(statusMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
            }
            Text("The agent passes a **category** (e.g. `deploy`); Baton speaks the summary in the mapped voice. **default** is used when no category matches. An explicit `voice` in the tool call overrides this map.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // Fixed column widths so the pop-up chevrons line up on the right of each column
    // (macOS `.menu` pickers hug their content, so without this they drift with text length).
    private let categoryWidth: CGFloat = 150
    private let engineWidth: CGFloat = 150
    private let voiceWidth: CGFloat = 160

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Text("Category").frame(width: categoryWidth, alignment: .leading)
            Text("Engine").frame(width: engineWidth, alignment: .trailing)
            Text("Voice").frame(width: voiceWidth, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func mapRow(_ row: Binding<VoiceRow>) -> some View {
        HStack(spacing: 12) {
            categoryField(row)
                .frame(width: categoryWidth)

            Picker(selection: row.engine) {
                Text("Kokoro").tag(SpeechConfig.Engine.kokoro)
                Text("Chatterbox").tag(SpeechConfig.Engine.chatterbox)
            } label: { EmptyView() }
                .labelsHidden()
                .fixedSize()
                .frame(width: engineWidth, alignment: .trailing)
                .onChange(of: row.wrappedValue.engine) { _, newEngine in
                    let list = voices[newEngine] ?? []
                    if !list.contains(row.wrappedValue.voice) { row.wrappedValue.voice = list.first ?? "" }
                    persistMap()
                }

            voicePicker(row)
                .frame(width: voiceWidth, alignment: .trailing)

            Spacer(minLength: 8)

            Button {
                preview(row.wrappedValue)
            } label: {
                if previewing == row.wrappedValue.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.circle").imageScale(.large)
                }
            }
            .buttonStyle(.borderless)
            .frame(width: 24)
            .help("Preview this voice")
            .disabled(previewing != nil)
        }
        .padding(.vertical, 2)
    }

    /// Common category names an agent might send, offered as a convenience. NOT exhaustive and
    /// NOT a constraint: `speak_summary`'s `category` is a free string, so the field stays
    /// editable — a dropdown that dropped unlisted categories would break the ones your agents
    /// actually use. `default` is the fallback and always available.
    private static let categorySuggestions = [
        "default", "ops", "deploy", "build", "test", "research", "alert", "error", "done",
    ]

    /// An editable category name with a dropdown of common suggestions — a combo box, not a
    /// locked picker, because the category must match whatever string the agent passes.
    @ViewBuilder
    private func categoryField(_ row: Binding<VoiceRow>) -> some View {
        HStack(spacing: 4) {
            TextField(text: row.category, prompt: Text("name")) { EmptyView() }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onChange(of: row.wrappedValue.category) { _, _ in persistMap() }
            Menu {
                ForEach(Self.categorySuggestions, id: \.self) { name in
                    Button(name) { row.wrappedValue.category = name; persistMap() }
                }
            } label: {
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Common categories — you can also type your own")
        }
    }

    @ViewBuilder
    private func voicePicker(_ row: Binding<VoiceRow>) -> some View {
        let list = voices[row.wrappedValue.engine] ?? []
        if list.isEmpty {
            // Server voices not loaded yet — let the user still keep/type a voice id.
            TextField(text: row.voice, prompt: Text("voice id")) { EmptyView() }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { persistMap() }
        } else {
            Picker(selection: row.voice) {
                // Keep a current-but-unknown value selectable rather than silently dropping it.
                if !list.contains(row.wrappedValue.voice) {
                    Text(row.wrappedValue.voice).tag(row.wrappedValue.voice)
                }
                // Favourites first. Kokoro alone ships 54 voices, and the handful you actually
                // use are otherwise scattered through an alphabetical wall of them.
                let favourites = listedVoiceIDs(for: row.wrappedValue.engine).filter(list.contains)
                if !favourites.isEmpty {
                    Section("In use") {
                        ForEach(favourites, id: \.self) { Text($0).tag($0) }
                    }
                    Section("All voices") {
                        ForEach(list.filter { !favourites.contains($0) }, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    ForEach(list, id: \.self) { Text($0).tag($0) }
                }
            } label: { EmptyView() }
                .labelsHidden()
                .fixedSize()
                .onChange(of: row.wrappedValue.voice) { _, _ in persistMap() }
        }
    }

    // MARK: - State ⇄ config

    private func loadRows() {
        let map = SpeechConfig.voiceMap()
        // "default" first, then alphabetical, so the fallback is always on top.
        let keys = map.keys.sorted { a, b in
            if a == "default" { return true }
            if b == "default" { return false }
            return a < b
        }
        rows = keys.map { key in
            let spec = map[key] ?? "kokoro:af_heart"
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let engine = SpeechConfig.Engine(rawValue: parts[0].lowercased()) {
                return VoiceRow(category: key, engine: engine, voice: parts[1])
            }
            return VoiceRow(category: key, engine: .kokoro, voice: spec)
        }
    }

    private func persistMap() {
        var map: [String: String] = [:]
        for row in rows {
            let key = row.category.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            map[key] = "\(row.engine.rawValue):\(row.voice)"
        }
        SpeechConfig.setVoiceMap(map)
    }

    /// `silent` suppresses the "checking" state. A poll that flashed the badge every few
    /// seconds would be worse than the stale badge it replaced: the pane would look busy
    /// permanently, and the one state you actually care about — did it change? — would be
    /// hidden inside a strobe. Pressing Refresh by hand still shows the spinner, because
    /// there you asked and want to see it working.
    private func refreshVoices(_ engine: SpeechConfig.Engine, retry: Bool = true, silent: Bool = false) async {
        if !silent { loadState[engine] = .checking }
        do {
            let list = try await SpeechService.listVoices(engine: engine)
            voices[engine] = list
            loadState[engine] = .ok(detail: "\(list.count) voices", badge: "\(list.count)")
        } catch {
            // The first LAN request after launch can fail with -1009 while macOS resolves the
            // Local Network privacy prompt; retry once before surfacing the error.
            if retry {
                try? await Task.sleep(nanoseconds: 800_000_000)
                await refreshVoices(engine, retry: false, silent: silent)
                return
            }
            loadState[engine] = .unreachable((error as? SpeechService.SynthError)?.message ?? error.localizedDescription)
        }
    }

    private func preview(_ row: VoiceRow) {
        previewing = row.id
        statusMessage = nil
        let label = row.category.isEmpty ? "sample" : row.category
        let voice = SpeechConfig.Voice(engine: row.engine, voice: row.voice)
        Task {
            defer { previewing = nil }
            do {
                let audio = try await SpeechService.synthesize(text: "This is the \(label) voice.", voice: voice)
                model.speech.play(data: audio)
            } catch {
                statusMessage = (error as? SpeechService.SynthError)?.message ?? error.localizedDescription
            }
        }
    }
}
