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

    /// The map rendered as ordered, editable rows (a `[String: String]` dict has no order).
    @State private var rows: [VoiceRow] = []

    /// Live voice ids fetched from each server, used to populate the per-row voice pickers.
    @State private var voices: [SpeechConfig.Engine: [String]] = [:]
    @State private var loadState: [SpeechConfig.Engine: LoadState] = [:]
    @State private var previewing: VoiceRow.ID?
    @State private var statusMessage: String?
    @State private var showResetConfirm = false

    private enum LoadState: Equatable { case idle, loading, ok(Int), failed(String) }

    struct VoiceRow: Identifiable, Equatable {
        let id = UUID()
        var category: String
        var engine: SpeechConfig.Engine
        var voice: String
    }

    var body: some View {
        Form {
            hostsSection
            mapSection
            resetSection
        }
        .formStyle(.grouped)
        .onAppear {
            loadRows()
            Task { await refreshVoices(.kokoro) }
            Task { await refreshVoices(.chatterbox) }
        }
        .confirmationDialog("Reset Speech settings to defaults?", isPresented: $showResetConfirm) {
            Button("Reset to Defaults", role: .destructive) {
                SpeechConfig.resetToDefaults()
                fallbackEnabled = SpeechConfig.fallbackEnabled
                loadRows()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores the default category → voice map and the fallback toggle. Your server addresses are kept.")
        }
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

    private func hostRow(name: String, detail: String, text: Binding<String>, engine: SpeechConfig.Engine, commit: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField(text: text, prompt: Text("http://host:port")) { EmptyView() }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200)
                    .onChange(of: text.wrappedValue) { _, _ in commit() }
                    .onSubmit { commit(); Task { await refreshVoices(engine) } }
                statusBadge(for: engine)
                Button {
                    commit()
                    Task { await refreshVoices(engine) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Test this connection")
                .disabled(loadState[engine] == .loading)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for engine: SpeechConfig.Engine) -> some View {
        switch loadState[engine] ?? .idle {
        case .idle:
            Color.clear.frame(width: 16, height: 16)
        case .loading:
            ProgressView().controlSize(.small).frame(width: 16)
        case let .ok(n):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(n)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .help("Reachable — \(n) voices")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    /// Shows the actual failure reason inline (not just a tooltip) when a host is unreachable.
    @ViewBuilder
    private func errorRow(for engine: SpeechConfig.Engine) -> some View {
        if case let .failed(msg) = loadState[engine] ?? .idle {
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
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
            TextField(text: row.category, prompt: Text("name")) { EmptyView() }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: categoryWidth)
                .onChange(of: row.wrappedValue.category) { _, _ in persistMap() }

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
        loadState[engine] = .loading
        do {
            let list = try await SpeechService.listVoices(engine: engine)
            voices[engine] = list
            loadState[engine] = .ok(list.count)
        } catch {
            // The first LAN request after launch can fail with -1009 while macOS resolves the
            // Local Network privacy prompt; retry once before surfacing the error.
            if retry {
                try? await Task.sleep(nanoseconds: 800_000_000)
                await refreshVoices(engine, retry: false)
                return
            }
            loadState[engine] = .failed((error as? SpeechService.SynthError)?.message ?? error.localizedDescription)
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
