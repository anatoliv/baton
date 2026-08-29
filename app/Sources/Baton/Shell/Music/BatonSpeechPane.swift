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
    @State private var favourites = SpeechConfig.favouriteVoices()
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
            hostsSection
            transcriptionSection
            deliverySection
            favouritesSection
            mapSection
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
            loadRows()
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
                favourites = SpeechConfig.favouriteVoices()
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

    /// The voice ids among the favourites that belong to `engine`, in pool order.
    private func favouriteIDs(for engine: SpeechConfig.Engine) -> [String] {
        favourites.compactMap { spec in
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return SpeechConfig.Engine(rawValue: parts[0].lowercased()) == engine ? parts[1] : nil
            }
            return engine == .kokoro ? spec : nil
        }
    }

    /// Session names Baton has actually heard from, newest first, so the pool can show who
    /// lands where. Taken from spoken-summary history rather than a list to maintain: the
    /// agents that have spoken are exactly the ones worth showing.
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

    /// Which heard-from sessions land on each slot. More than one on a slot is a collision,
    /// which the design allows and this makes visible: five names into five slots avoid each
    /// other only about 4% of the time, so the answer is to see it and pin, not to hope.
    private func sessions(inSlot slot: Int) -> [String] {
        knownSessions.filter {
            SpeechConfig.sessionVoices()[$0] == nil && SpeechConfig.favouriteSlot(for: $0) == slot
        }
    }

    private var favouritesSection: some View {
        Section("Favourite voices") {
            ForEach(Array(favourites.enumerated()), id: \.offset) { index, spec in
                favouriteRow(index: index, spec: spec)
            }

            // One row per agent Baton has actually heard from, each able to override its
            // voice. Without this the pool is take-it-or-leave-it: names land where the hash
            // puts them, and the only remedy the design has for two projects sharing a voice
            // would be unreachable. The docs promise pinning, so it has to exist here.
            if !knownSessions.isEmpty {
                Divider()
                Text("Agents Baton has heard from")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(knownSessions, id: \.self) { name in
                    sessionRow(name)
                }
            }

            Text("Each agent that sends a `session` name speaks in one of these, chosen from the name itself, so a project sounds the same every time and on any Mac. An explicit `voice` in the tool call still wins. Two projects can land on the same voice, which is normal with five of them; pin one to a different voice to separate them.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// One agent, and the voice it speaks in. "Automatic" is the hashed slot; anything else
    /// pins it. Pinning is the answer to a collision, so it lives right under the pool that
    /// caused one rather than in a separate screen.
    private func sessionRow(_ name: String) -> some View {
        let pinnedSpec = SpeechConfig.sessionVoices()[name]
        let auto = SpeechConfig.favouriteVoices()[SpeechConfig.favouriteSlot(for: name)]
        let shared = sessions(inSlot: SpeechConfig.favouriteSlot(for: name)).count > 1

        return HStack(spacing: 12) {
            Text(name)
                .font(.callout)
                .lineLimit(1)
                .frame(width: categoryWidth, alignment: .leading)

            Picker(selection: Binding(
                get: { pinnedSpec ?? "" },
                set: { choice in
                    var map = SpeechConfig.sessionVoices()
                    if choice.isEmpty { map.removeValue(forKey: name) } else { map[name] = choice }
                    SpeechConfig.setSessionVoices(map)
                    favourites = SpeechConfig.favouriteVoices()   // redraw the "who is here" labels
                }
            )) {
                Text("Automatic (\(voiceID(of: auto)))").tag("")
                Divider()
                ForEach(favourites, id: \.self) { Text(voiceID(of: $0)).tag($0) }
            } label: { EmptyView() }
                .labelsHidden()
                .fixedSize()
                .frame(width: voiceWidth, alignment: .leading)

            if pinnedSpec == nil, shared {
                Text("shares a voice")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Pick a different voice here to tell them apart.")
            }

            Spacer(minLength: 8)
        }
    }

    private func favouriteRow(index: Int, spec: String) -> some View {
        let here = sessions(inSlot: index)
        return HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 14, alignment: .trailing)

            // Same offline rule as the category rows below: with no server reachable there is
            // no list to choose from, and a picker of one item is a dead control. Typing an id
            // still works, so the pane stays usable with the TTS hosts down.
            if allVoiceSpecs.isEmpty {
                TextField(text: Binding(
                    get: { favourites.indices.contains(index) ? favourites[index] : "" },
                    set: { newValue in
                        guard favourites.indices.contains(index) else { return }
                        favourites[index] = newValue
                        SpeechConfig.setFavouriteVoices(favourites)
                    }
                ), prompt: Text("engine:voice")) { EmptyView() }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: voiceWidth)
            } else {
                Picker(selection: Binding(
                    get: { favourites.indices.contains(index) ? favourites[index] : "" },
                    set: { newValue in
                        guard favourites.indices.contains(index) else { return }
                        favourites[index] = newValue
                        SpeechConfig.setFavouriteVoices(favourites)
                    }
                )) {
                    ForEach(allVoiceSpecs, id: \.self) { Text(voiceID(of: $0)).tag($0) }
                    if !allVoiceSpecs.contains(spec) { Text(voiceID(of: spec)).tag(spec) }
                } label: { EmptyView() }
                    .labelsHidden()
                    .fixedSize()
                    .frame(width: voiceWidth, alignment: .leading)
            }

            if here.isEmpty {
                Text("unused").font(.caption).foregroundStyle(.tertiary)
            } else {
                Text(here.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(here.count > 1 ? .orange : .secondary)
                    .help(here.count > 1
                          ? "These share a voice. Pin one to tell them apart."
                          : "Speaks in this voice")
            }

            Spacer(minLength: 8)

            Button {
                preview(VoiceRow(category: "", engine: engineOf(spec), voice: voiceID(of: spec)))
            } label: {
                Image(systemName: "play.circle").imageScale(.large)
            }
            .buttonStyle(.borderless)
            .help("Preview this voice")
            .disabled(previewing != nil)
        }
    }

    /// Every voice both servers offered, as `engine:voice` specs.
    private var allVoiceSpecs: [String] {
        (voices[.kokoro] ?? []).map { "kokoro:\($0)" } + (voices[.chatterbox] ?? []).map { "chatterbox:\($0)" }
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
                let favourites = favouriteIDs(for: row.wrappedValue.engine).filter(list.contains)
                if !favourites.isEmpty {
                    Section("Favourites") {
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
