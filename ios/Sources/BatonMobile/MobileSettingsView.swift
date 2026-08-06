import SwiftUI

/// Minimal first-cut settings: the connected server, playback preferences that the
/// shared engine already persists, and the disconnect escape hatch.
struct MobileSettingsView: View {
    let model: MobileModel
    @Environment(\.nowPlayingPalette) private var wash
    @State private var showsDisconnectConfirm = false
    @State private var showsConnect = false
    /// Captured when the dialog opens so the copy can name what's about to go.
    @State private var purgePreview = SessionPurge.Preview(downloadCount: 0, downloadBytes: 0, historyCount: 0)
    /// Server credentials are revealed only behind a biometric challenge.
    @State private var credentialsUnlocked = false
    @State private var showsImporter = false
    @State private var importData: Data?
    @State private var importNeedsPassphrase = false
    @State private var importPassphrase = ""
    @State private var importStatus: String?
    @AppStorage(CrashReporting.enabledKey) private var sendsCrashReports = false
    @State private var showsWhatsNew = false

    /// Spells out everything the purge removes. Deleting someone's offline music quietly
    /// would be worse than not deleting it at all.
    private var disconnectMessage: String {
        var parts = ["Baton will forget this server and remove its data from this iPhone: listening history, playlisted downloads, radio bans, scrobble accounts and the music friend's key."]
        if purgePreview.historyCount > 0 {
            parts.append("\(purgePreview.historyCount) plays will be cleared from this device \u{2014} your server's own play counts are untouched.")
        }
        if purgePreview.downloadSummary != nil {
            parts.append("Deleting downloads cannot be undone.")
        }
        return parts.joined(separator: "\n\n")
    }

    /// "32 Hz" / "1.0 kHz" — a band label that stays narrow at every frequency.
    private func frequencyLabel(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.0fk", hz / 1000) : String(format: "%.0f", hz)
    }

    /// Signed dB, so a boost and a cut are distinguishable at a glance.
    private func gainLabel(_ dB: Double) -> String {
        String(format: "%+.1f dB", dB)
    }

    /// Which external services are actually going to receive plays.
    private var scrobbleStatus: String {
        var on: [String] = []
        if model.listenBrainz.isEnabled { on.append("ListenBrainz") }
        if model.lastfm.isConnected { on.append("Last.fm") }
        return on.isEmpty ? "Server only" : on.joined(separator: ", ")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.isDemoMode {
                        LabeledContent("Library", value: "Demo")
                        Button("Connect to Navidrome…") { showsConnect = true }
                    } else {
                        LabeledContent("Address", value: NavidromeConfig.serverURLString)
                        LabeledContent("User", value: NavidromeConfig.username)
                        Button("Import settings from Mac…") { showsImporter = true }
                        Button("Disconnect…", role: .destructive) {
                            purgePreview = SessionPurge.preview(model)
                            showsDisconnectConfirm = true
                        }
                    }
                } header: {
                    Text("Server")
                } footer: {
                    if model.isDemoMode {
                        Text("You're listening to the sample tracks built into Baton. "
                             + "Connect your Navidrome server to play your own library.")
                    }
                }

                Section {
                    NavigationLink {
                        MusicFriendSettingsView(config: model.agentConfig, model: model)
                    } label: {
                        LabeledContent {
                            if model.agentConfig.isReady {
                                Text("Ready").foregroundStyle(.green)
                            } else if model.agentConfig.isConfigured {
                                Text("Not tested").foregroundStyle(.secondary)
                            } else {
                                Text("Off").foregroundStyle(.secondary)
                            }
                        } label: {
                            Label("Music Friend", systemImage: "sparkles")
                        }
                    }
                } footer: {
                    Text(model.agentConfig.isReady
                         ? "The Friend tab is available."
                         : "Connect a model provider or your home server, then test it — the Friend tab appears once the test passes.")
                }

                Section("Equalizer") {
                    Toggle("Equalizer", isOn: Binding(
                        get: { model.equalizer.isEnabled },
                        set: { model.equalizer.isEnabled = $0 }
                    ))
                    if model.equalizer.isEnabled {
                        Picker("Preset", selection: Binding(
                            get: { model.equalizer.preset },
                            set: {
                                model.equalizer.preset = $0
                                model.preferenceSync.noteLocalChange("tonebox.music.eq.preset")
                            }
                        )) {
                            ForEach(MusicEqualizer.presets, id: \.name) { preset in
                                Text(preset.name).tag(preset.name)
                            }
                        }
                    }

                    // The presets cover most listening; these are for the person who
                    // wants their own curve. Editing one moves the preset to "Custom",
                    // because silently keeping the old name would misdescribe the sound.
                    if model.equalizer.isEnabled {
                        DisclosureGroup("Bands") {
                            ForEach(Array(MusicEqualizer.frequencies.enumerated()), id: \.offset) { index, hz in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(frequencyLabel(hz))
                                            .font(.caption.monospacedDigit())
                                            .frame(width: 52, alignment: .leading)
                                        Slider(
                                            value: Binding(
                                                get: { model.equalizer.gains.indices.contains(index) ? model.equalizer.gains[index] : 0 },
                                                set: {
                                                model.equalizer.setGain($0, band: index)
                                                model.preferenceSync.noteLocalChange("tonebox.music.eq.gains")
                                            }
                                            ),
                                            in: -12 ... 12,
                                            step: 0.5
                                        )
                                        Text(gainLabel(model.equalizer.gains.indices.contains(index) ? model.equalizer.gains[index] : 0))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 48, alignment: .trailing)
                                    }
                                }
                            }
                            Button("Reset to flat") {
                                for index in MusicEqualizer.frequencies.indices {
                                    model.equalizer.setGain(0, band: index)
                                }
                            }
                        }
                    }
                }

                Section("Playback") {
                    Toggle("Gapless playback", isOn: Binding(
                        get: { model.music.gaplessEnabled },
                        set: { model.music.gaplessEnabled = $0 }
                    ))
                    if !model.music.gaplessEnabled {
                        Picker("Crossfade", selection: Binding(
                            get: { model.music.crossfadeSeconds },
                            set: { model.music.crossfadeSeconds = $0 }
                        )) {
                            Text("Off").tag(0.0)
                            ForEach([2.0, 4.0, 6.0, 8.0], id: \.self) { seconds in
                                Text("\(Int(seconds))s").tag(seconds)
                            }
                        }
                    }
                    Picker("Loudness", selection: Binding(
                        get: { model.music.loudnessMode },
                        set: { model.music.loudnessMode = $0 }
                    )) {
                        ForEach(StreamingPlaybackController.LoudnessMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Toggle("Autoplay similar songs", isOn: Binding(
                        get: { model.music.autoplayEnabled },
                        set: { model.music.autoplayEnabled = $0 }
                    ))
                }

                Section {
                    NavigationLink {
                        ScrobbleSettingsView(model: model)
                    } label: {
                        LabeledContent {
                            Text(scrobbleStatus).foregroundStyle(.secondary)
                        } label: {
                            Label("Scrobbling", systemImage: "waveform.badge.plus")
                        }
                    }
                } footer: {
                    Text("Send your plays to ListenBrainz and Last.fm. Your server's own play counts need no setup.")
                }

                Section {
                    NavigationLink { HelpView() } label: {
                        Label("Help & FAQ", systemImage: "questionmark.circle")
                    }
                    Button {
                        showsWhatsNew = true
                    } label: {
                        Label("What's New", systemImage: "sparkles")
                    }
                }

                Section {
                    Toggle("Send crash reports", isOn: Binding(
                        get: { sendsCrashReports },
                        set: { sendsCrashReports = $0; CrashReporting.apply(enabled: $0) }
                    ))
                    .disabled(!CrashReporting.isConfigured)
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text(CrashReporting.isConfigured
                         ? "Off by default. Crash reports carry no server address, credentials or track names — the Subsonic auth parameters are stripped before anything is sent."
                         : "This build has no reporting endpoint compiled in, so nothing can be sent.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                } footer: {
                    Text("Baton is open source and MIT-licensed — the source is free forever; the App Store build funds development.")
                }
            }
            .nowPlayingWash(wash)
            .navigationTitle("Settings")
            .sheet(isPresented: $showsWhatsNew) { WhatsNewView() }
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json, .data]) { result in
                guard case .success(let url) = result else { return }
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    importStatus = "Couldn't read that file."
                    return
                }
                importData = data
                if let inspection = try? SettingsTransfer.inspect(data), inspection.encrypted {
                    importNeedsPassphrase = true
                } else {
                    applyImport(passphrase: nil)
                }
            }
            .alert("Passphrase", isPresented: $importNeedsPassphrase) {
                SecureField("Export passphrase", text: $importPassphrase)
                Button("Import") { applyImport(passphrase: importPassphrase) }
                Button("Cancel", role: .cancel) { importData = nil; importPassphrase = "" }
            } message: {
                Text("This export is encrypted — enter the passphrase you set on the Mac.")
            }
            .alert("Settings import", isPresented: Binding(
                get: { importStatus != nil },
                set: { if !$0 { importStatus = nil } }
            )) {
                Button("OK") { importStatus = nil }
            } message: {
                if let importStatus { Text(importStatus) }
            }
            .confirmationDialog(
                "Disconnect from this server?",
                isPresented: $showsDisconnectConfirm,
                titleVisibility: .visible
            ) {
                // Two buttons, because these are different intentions and only one of them
                // can't be undone. Naming the downloads in the button — not just the
                // message — means the irreversible choice can't be made by muscle memory.
                if let summary = purgePreview.downloadSummary {
                    Button("Disconnect and Delete \(summary)", role: .destructive) {
                        model.disconnect(keepDownloads: false)
                    }
                    Button("Disconnect, Keep Downloads") {
                        model.disconnect(keepDownloads: true)
                    }
                } else {
                    Button("Disconnect", role: .destructive) { model.disconnect(keepDownloads: false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(disconnectMessage)
            }
            .sheet(isPresented: $showsConnect) {
                OnboardingView {
                    showsConnect = false
                    model.endDemo()
                    Task { await model.warmLibrary() }
                }
            }
        }
    }
}

extension MobileSettingsView {
    /// Applies a Mac settings export: server config + secrets land in the same
    /// UserDefaults/Keychain slots the shared core reads, then the library reloads.
    private func applyImport(passphrase: String?) {
        guard let data = importData else { return }
        do {
            let result = try SettingsTransfer.applyImport(data, passphrase: passphrase)
            importStatus = "Imported \(result.preferenceCount) settings and \(result.secretCount) secrets."
            importData = nil
            importPassphrase = ""
            model.musicLibrary.refreshConnection()
            Task { await model.warmLibrary() }
        } catch {
            importStatus = "Import failed: \(error.localizedDescription)"
        }
    }
}
