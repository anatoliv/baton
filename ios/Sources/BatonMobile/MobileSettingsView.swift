import SwiftUI

/// Minimal first-cut settings: the connected server, playback preferences that the
/// shared engine already persists, and the disconnect escape hatch.
struct MobileSettingsView: View {
    let model: MobileModel
    @Environment(\.nowPlayingPalette) private var wash
    @Environment(\.dismiss) private var dismiss
    @State private var showsDisconnectConfirm = false
    @State private var showsConnect = false
    /// Captured when the dialog opens so the copy can name what's about to go.
    @State private var purgePreview = SessionPurge.Preview(downloadCount: 0, downloadBytes: 0, historyCount: 0)
    /// Server credentials are revealed only behind a biometric challenge.
    @State private var credentialsUnlocked = false
    @AppStorage(CrashReporting.enabledKey) private var sendsCrashReports = false
    @AppStorage("baton.display.keepAwake") private var keepAwake = false
    @State private var showsWhatsNew = false
    /// A footer's "Learn more" opens Help at the topic it just requested.
    @State private var showsHelp = false
    /// Whether the server is answering. Checked on appear, and on tap.
    @State private var serverStatus = ServerStatus()

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
                        // First row in the section, because "is it working" is the question
                        // people open Settings with. The address and username below say
                        // what Baton was configured with; only this says whether any of it
                        // currently works.
                        ServerStatusRow(status: serverStatus) {
                            Task { await serverStatus.check() }
                        }
                        LabeledContent("Address", value: NavidromeConfig.serverURLString)
                        LabeledContent("User", value: NavidromeConfig.username)
                        Button("Disconnect…", role: .destructive) {
                            purgePreview = SessionPurge.preview(model)
                            showsDisconnectConfirm = true
                        }
                    }
                    // Reachable whether or not this phone is connected. It used to sit
                    // only in the connected branch, as a button that opened the Files
                    // picker — while the better route, scanning the Mac's code, was
                    // reachable only from first-run onboarding.
                    NavigationLink {
                        MacTransferView(model: model)
                    } label: {
                        Label("Set up from a Mac…", systemImage: "laptopcomputer.and.iphone")
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

                Section {
                    Toggle("Equalizer", isOn: Binding(
                        get: { model.equalizer.isEnabled },
                        set: { model.equalizer.isEnabled = $0 }
                    ))
                    if model.equalizer.isEnabled {
                        // Assigning `preset` only renamed the curve — the bands were left
                        // exactly as they were, so choosing "Rock" on the phone changed a
                        // label and nothing else. `apply` is what moves the sound, and it
                        // is what the Mac has always called.
                        Picker("Preset", selection: Binding(
                            get: { model.equalizer.preset },
                            set: { name in
                                // "Custom" is the label for a hand-tuned curve, not a
                                // preset you can apply. Selecting it means nothing.
                                guard name != "Custom" else { return }
                                model.equalizer.apply(preset: name)
                                model.preferenceSync.noteLocalChange("tonebox.music.eq.preset")
                                model.preferenceSync.noteLocalChange("tonebox.music.eq.gains")
                            }
                        )) {
                            // Without this the picker had no tag matching "Custom" and drew
                            // an empty row — which is how a hand-tuned EQ ended up looking
                            // like a broken screen.
                            if model.equalizer.preset == "Custom" {
                                Text("Custom").tag("Custom")
                            }
                            ForEach(MusicEqualizer.presets, id: \.name) { preset in
                                Text(preset.name).tag(preset.name)
                            }
                        }

                        // The Mac has had this since the EQ shipped; the phone could only
                        // get back to flat by dragging ten sliders and hoping.
                        Button("Flat / Reset", role: .destructive) {
                            model.equalizer.reset()
                            model.preferenceSync.noteLocalChange("tonebox.music.eq.preset")
                            model.preferenceSync.noteLocalChange("tonebox.music.eq.gains")
                        }
                    }

                    // The presets cover most listening; these are for the person who
                    // wants their own curve. Editing one renames the preset to whatever
                    // the resulting curve actually is — "Custom" for a shape no preset
                    // has, but "Flat" the moment every band is back at zero — because
                    // keeping the old name would misdescribe the sound.
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
                                                // Editing a band can rename the curve —
                                                // back to flat is "Flat", not "Custom".
                                                model.preferenceSync.noteLocalChange("tonebox.music.eq.preset")
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
                        }
                    }
                } header: {
                    Text("Equalizer")
                } footer: {
                    SettingsFooter(
                        text: """
                        Turns some frequencies up and others down — more bass, less \
                        harshness, whatever your headphones need. Start from a preset, or \
                        open Bands and move the sliders yourself. The preset name always \
                        describes the curve you actually have.
                        """,
                        topic: SettingsHelpTopic.equalizer,
                        onOpenHelp: { showsHelp = true }
                    )
                }

                Section {
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
                } header: {
                    Text("Sound")
                } footer: {
                    SettingsFooter(
                        text: """
                        Gapless plays an album with no silence between tracks, the way a \
                        live record was meant to run. Crossfade instead overlaps the end \
                        of one song with the start of the next — the two want opposite \
                        things, so crossfade is hidden while gapless is on. Loudness \
                        evens out volume between quiet and loud tracks so you stop \
                        reaching for the volume.
                        """,
                        topic: SettingsHelpTopic.soundQuality,
                        onOpenHelp: { showsHelp = true }
                    )
                }

                Section {
                    Toggle("Autoplay similar songs", isOn: Binding(
                        get: { model.music.autoplayEnabled },
                        set: { model.music.autoplayEnabled = $0 }
                    ))
                } header: {
                    Text("Queue")
                } footer: {
                    SettingsFooter(
                        text: """
                        When the queue runs out, Baton keeps playing with songs like the \
                        ones you just heard instead of falling silent. Turn it off if you \
                        want the music to stop where you told it to.
                        """,
                        topic: SettingsHelpTopic.queue,
                        onOpenHelp: { showsHelp = true }
                    )
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
                    Button { showsHelp = true } label: {
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
                    Toggle("Keep the screen awake", isOn: Binding(
                        get: { keepAwake },
                        set: { keepAwake = $0; UIApplication.shared.isIdleTimerDisabled = $0 }
                    ))
                } header: {
                    Text("Display")
                } footer: {
                    Text("""
                    Stops the screen locking while Baton is open — for a phone propped on \
                    a dock or a kitchen counter. Uses more battery, which is why it's off \
                    by default.
                    """)
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                } footer: {
                    Text("Baton is open source and MIT-licensed — the source is free forever; the App Store build funds development.")
                }
            }
            .nowPlayingWash(wash)
            // Settings is presented as a sheet from Home now, and it uses the pinned
            // header rather than a navigation bar — so without this there is nothing to
            // dismiss it with. Exactly the trap the keyboard fix just closed on two other
            // screens; adding a screen with no way out while fixing screens with no way
            // out would be its own kind of joke.
            .rootScreenHeader("Settings", subtitle: connectionLine) {
                Button("Done") { dismiss() }
                    .font(.body.weight(.semibold))
            }
            // Keyed, not bare. A plain `.task` runs once when the view first appears, so
            // connecting to a server from this very screen left the badge reading "Not
            // checked" — Settings was already on screen, so nothing re-ran. Keying on the
            // identity of the connection re-checks whenever it changes: a new server, a
            // different user, or leaving demo mode.
            .task(id: "\(model.isDemoMode)|\(NavidromeConfig.serverURLString)|\(NavidromeConfig.username)") {
                // Only when there is something to check — in demo mode there is no server,
                // and a red "can't reach" badge over the bundled library would be a lie.
                if !model.isDemoMode { await serverStatus.check() }
            }
            .sheet(isPresented: $showsWhatsNew) { WhatsNewView() }
            .sheet(isPresented: $showsHelp) { HelpView() }
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
                OnboardingView(onConnected: {
                    showsConnect = false
                    model.endDemo()
                    Task { await model.warmLibrary() }
                }, onCancel: {
                    showsConnect = false
                })
            }
        }
    }

    /// Which library you are actually looking at. The single most common question this
    /// screen answers, and it was three rows down inside a section.
    ///
    /// Host only, never the full URL: this line is on screen whenever Settings is, and a
    /// header is a poor place to park credentials or a private address.
    private var connectionLine: String? {
        if model.isDemoMode { return "Demo library" }
        let host = URL(string: NavidromeConfig.serverURLString)?.host
            ?? NavidromeConfig.serverURLString
        guard !host.isEmpty else { return nil }
        let user = NavidromeConfig.username
        return user.isEmpty ? host : "\(user) · \(host)"
    }
}
