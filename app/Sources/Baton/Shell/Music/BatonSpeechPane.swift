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

    struct VoiceRow: Identifiable, Equatable {
        let id = UUID()
        var category: String
        var engine: SpeechConfig.Engine
        var voice: String
    }

    var body: some View {
        Form {
            hostsSection
            transcriptionSection
            deliverySection
            mapSection
            resetSection
        }
        .formStyle(.grouped)
        .onAppear {
            loadRows()
            Task { await refreshVoices(.kokoro) }
            Task { await refreshVoices(.chatterbox) }
            // The ASR host is checked on appear for the same reason the two above are: a
            // saved address that was never contacted is a setting, not a working feature,
            // and this pane is where someone comes to find that out.
            Task { await testTranscriptionHost() }
        }
        .confirmationDialog("Reset Speech settings to defaults?", isPresented: $showResetConfirm) {
            Button("Reset to Defaults", role: .destructive) {
                SpeechConfig.resetToDefaults()
                fallbackEnabled = SpeechConfig.fallbackEnabled
                announceImmediately = SpeechConfig.announceImmediately
                alertNotification = SpeechConfig.alertWithNotification
                alertBanner = SpeechConfig.alertWithBanner
                allowAutoPlay = SpeechConfig.allowAutoPlay
                loadRows()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores the default category → voice map, the fallback toggle, and delivery preferences. Your server addresses are kept.")
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
    private func testTranscriptionHost() async {
        let host = SpeechConfig.whisperBaseURL.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            whisperStatus = .notConfigured("No host yet")
            return
        }
        whisperStatus = .checking
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
                ForEach(list, id: \.self) { Text($0).tag($0) }
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

    private func refreshVoices(_ engine: SpeechConfig.Engine, retry: Bool = true) async {
        loadState[engine] = .checking
        do {
            let list = try await SpeechService.listVoices(engine: engine)
            voices[engine] = list
            loadState[engine] = .ok(detail: "\(list.count) voices", badge: "\(list.count)")
        } catch {
            // The first LAN request after launch can fail with -1009 while macOS resolves the
            // Local Network privacy prompt; retry once before surfacing the error.
            if retry {
                try? await Task.sleep(nanoseconds: 800_000_000)
                await refreshVoices(engine, retry: false)
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
